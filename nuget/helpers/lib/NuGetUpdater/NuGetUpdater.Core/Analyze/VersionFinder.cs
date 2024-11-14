using System.Collections.Immutable;

using NuGet.Common;
using NuGet.Configuration;
using NuGet.Packaging.Core;
using NuGet.Protocol;
using NuGet.Protocol.Core.Types;
using NuGet.Versioning;

namespace NuGetUpdater.Core.Analyze;

internal static class VersionFinder
{
    public static Task<VersionResult> GetVersionsAsync(
        string packageId,
        NuGetVersion currentVersion,
        NuGetContext nugetContext,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        var versionFilter = CreateVersionFilter(currentVersion);

        return GetVersionsAsync(packageId, currentVersion, versionFilter, nugetContext, logger, cancellationToken);
    }

    public static async Task<VersionResult> GetVersionsAsync(
        DependencyInfo dependencyInfo,
        NuGetContext nugetContext,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        var packageId = dependencyInfo.Name;
        var versionRange = VersionRange.Parse(dependencyInfo.Version);
        var currentVersion = versionRange.MinVersion!;
        var mergedResult = new VersionResult(currentVersion);

        // If packageId contains a semi-colon, split it and run the logic on both parts.
        var packageIds = packageId.Contains(';') ? packageId.Split(';') : new[] { packageId };

        foreach (var id in packageIds)
        {
            var versionFilter = CreateVersionFilter(dependencyInfo, versionRange);

            // Retrieve versions for each package ID.
            var result = await GetVersionsAsync(id, currentVersion, versionFilter, nugetContext, logger, cancellationToken);

            // Add current version sources.
            foreach (var source in result.GetPackageSources(currentVersion))
            {
                mergedResult.AddCurrentVersionSource(source);
            }

            // Add all other versions and their sources.
            foreach (var version in result.GetVersions())
            {
                foreach (var source in result.GetPackageSources(version))
                {
                    mergedResult.AddRange(source, new[] { version });
                }
            }
        }

        return mergedResult;
    }


    public static async Task<VersionResult> GetVersionsAsync(
        string packageId,
        NuGetVersion currentVersion,
        Func<NuGetVersion, bool> versionFilter,
        NuGetContext nugetContext,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        var includePrerelease = currentVersion.IsPrerelease;
        VersionResult result = new(currentVersion);

        var sourceMapping = PackageSourceMapping.GetPackageSourceMapping(nugetContext.Settings);
        var packageSources = sourceMapping.GetConfiguredPackageSources(packageId).ToHashSet();
        var sources = packageSources.Count == 0
            ? nugetContext.PackageSources
            : nugetContext.PackageSources
                .Where(p => packageSources.Contains(p.Name))
                .ToImmutableArray();

        foreach (var source in sources)
        {
            var sourceRepository = Repository.Factory.GetCoreV3(source);
            var feed = await sourceRepository.GetResourceAsync<MetadataResource>();
            if (feed is null)
            {
                logger.Log($"Failed to get MetadataResource for [{source.Source}]");
                continue;
            }

            try
            {
                // a non-compliant v2 API returning 404 can cause this to throw
                var existsInFeed = await feed.Exists(
                    packageId,
                    includePrerelease,
                    includeUnlisted: false,
                    nugetContext.SourceCacheContext,
                    NullLogger.Instance,
                    cancellationToken);
                if (!existsInFeed)
                {
                    continue;
                }
            }
            catch (FatalProtocolException)
            {
                // if anything goes wrong here, the package source obviously doesn't contain the requested package
                continue;
            }

            var feedVersions = (await feed.GetVersions(
                packageId,
                includePrerelease,
                includeUnlisted: false,
                nugetContext.SourceCacheContext,
                NullLogger.Instance,
                CancellationToken.None)).ToHashSet();

            if (feedVersions.Contains(currentVersion))
            {
                result.AddCurrentVersionSource(source);
            }

            result.AddRange(source, feedVersions.Where(versionFilter));
        }

        return result;
    }

    internal static Func<NuGetVersion, bool> CreateVersionFilter(DependencyInfo dependencyInfo, VersionRange versionRange)
    {
        // If we are floating to the absolute latest version, we should not filter pre-release versions at all.
        var currentVersion = versionRange.Float?.FloatBehavior != NuGetVersionFloatBehavior.AbsoluteLatest
            ? versionRange.MinVersion
            : null;

        return version => (currentVersion is null || version > currentVersion)
            && versionRange.Satisfies(version)
            && (currentVersion is null || !currentVersion.IsPrerelease || !version.IsPrerelease || version.Version == currentVersion.Version)
            && !dependencyInfo.IgnoredVersions.Any(r => r.IsSatisfiedBy(version))
            && !dependencyInfo.Vulnerabilities.Any(v => v.IsVulnerable(version));
    }

    internal static Func<NuGetVersion, bool> CreateVersionFilter(NuGetVersion currentVersion)
    {
        return version => version > currentVersion
            && (currentVersion is null || !currentVersion.IsPrerelease || !version.IsPrerelease || version.Version == currentVersion.Version);
    }

    public static async Task<bool> DoVersionsExistAsync(
        IEnumerable<string> packageIds,
        NuGetVersion version,
        NuGetContext nugetContext,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        foreach (var id in packageIds)
        {
            // Split package IDs by semicolon and check each individually.
            var individualIds = id.Contains(';') ? id.Split(';') : new[] { id };

            foreach (var individualId in individualIds)
            {
                if (!await DoesVersionExistAsync(individualId, version, nugetContext, logger, cancellationToken))
                {
                    return false;
                }
            }
        }

        return true;
    }

    public static async Task<bool> DoesVersionExistAsync(
        string packageId,
        NuGetVersion version,
        NuGetContext nugetContext,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        var includePrerelease = version.IsPrerelease;

        var sourceMapping = PackageSourceMapping.GetPackageSourceMapping(nugetContext.Settings);
        var packageSources = sourceMapping.GetConfiguredPackageSources(packageId).ToHashSet();
        var sources = packageSources.Count == 0
            ? nugetContext.PackageSources
            : nugetContext.PackageSources
                .Where(p => packageSources.Contains(p.Name))
                .ToImmutableArray();

        foreach (var source in sources)
        {
            var sourceRepository = Repository.Factory.GetCoreV3(source);
            var feed = await sourceRepository.GetResourceAsync<MetadataResource>();
            if (feed is null)
            {
                logger.Log($"Failed to get MetadataResource for [{source.Source}]");
                continue;
            }

            try
            {
                // a non-compliant v2 API returning 404 can cause this to throw
                var existsInFeed = await feed.Exists(
                    new PackageIdentity(packageId, version),
                    includeUnlisted: false,
                    nugetContext.SourceCacheContext,
                    NullLogger.Instance,
                    cancellationToken);
                if (existsInFeed)
                {
                    return true;
                }
            }
            catch (FatalProtocolException)
            {
                // if anything goes wrong here, the package source obviously doesn't contain the requested package
            }
        }

        return false;
    }
}
