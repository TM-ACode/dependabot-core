# typed: strict
# frozen_string_literal: true

require "dependabot/shared_helpers"
require "dependabot/ecosystem"
require "dependabot/npm_and_yarn/version_selector"

module Dependabot
  module NpmAndYarn
    ECOSYSTEM = "npm_and_yarn"
    MANIFEST_FILENAME = "package.json"
    LERNA_JSON_FILENAME = "lerna.json"
    PACKAGE_MANAGER_VERSION_REGEX = /^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre_release>[a-zA-Z0-9.]+))?(?:\+(?<build>[a-zA-Z0-9.]+))?$/ # rubocop:disable Layout/LineLength

    MANIFEST_PACKAGE_MANAGER_KEY = "packageManager"
    MANIFEST_ENGINES_KEY = "engines"

    class NpmPackageManager < Ecosystem::VersionManager
      extend T::Sig
      NAME = "npm"
      RC_FILENAME = ".npmrc"
      LOCKFILE_NAME = "package-lock.json"
      SHRINKWRAP_LOCKFILE_NAME = "npm-shrinkwrap.json"

      NPM_V6 = "6"
      NPM_V7 = "7"
      NPM_V8 = "8"
      NPM_V9 = "9"
      NPM_V10 = "10"

      # Keep versions in ascending order
      SUPPORTED_VERSIONS = T.let([
        Version.new(NPM_V6),
        Version.new(NPM_V7),
        Version.new(NPM_V8),
        Version.new(NPM_V9),
        Version.new(NPM_V10)
      ].freeze, T::Array[Dependabot::Version])

      DEPRECATED_VERSIONS = T.let([].freeze, T::Array[Dependabot::Version])

      sig { params(raw_version: String).void }
      def initialize(raw_version)
        super(
          NAME,
          Version.new(raw_version),
          DEPRECATED_VERSIONS,
          SUPPORTED_VERSIONS
        )
      end

      sig { override.returns(T::Boolean) }
      def deprecated?
        false
      end

      sig { override.returns(T::Boolean) }
      def unsupported?
        false
      end
    end

    class YarnPackageManager < Ecosystem::VersionManager
      extend T::Sig
      NAME = "yarn"
      RC_FILENAME = ".yarnrc"
      RC_YML_FILENAME = ".yarnrc.yml"
      LOCKFILE_NAME = "yarn.lock"

      YARN_V1 = "1"
      YARN_V2 = "2"
      YARN_V3 = "3"

      SUPPORTED_VERSIONS = T.let([
        Version.new(YARN_V1),
        Version.new(YARN_V2),
        Version.new(YARN_V3)
      ].freeze, T::Array[Dependabot::Version])

      DEPRECATED_VERSIONS = T.let([].freeze, T::Array[Dependabot::Version])

      sig { params(raw_version: String).void }
      def initialize(raw_version)
        super(
          NAME,
          Version.new(raw_version),
          DEPRECATED_VERSIONS,
          SUPPORTED_VERSIONS
        )
      end

      sig { override.returns(T::Boolean) }
      def deprecated?
        false
      end

      sig { override.returns(T::Boolean) }
      def unsupported?
        false
      end
    end

    class PNPMPackageManager < Ecosystem::VersionManager
      extend T::Sig
      NAME = "pnpm"
      LOCKFILE_NAME = "pnpm-lock.yaml"
      PNPM_WS_YML_FILENAME = "pnpm-workspace.yaml"

      PNPM_V7 = "7"
      PNPM_V8 = "8"
      PNPM_V9 = "9"

      SUPPORTED_VERSIONS = T.let([
        Version.new(PNPM_V7),
        Version.new(PNPM_V8),
        Version.new(PNPM_V9)
      ].freeze, T::Array[Dependabot::Version])

      DEPRECATED_VERSIONS = T.let([].freeze, T::Array[Dependabot::Version])

      sig { params(raw_version: String).void }
      def initialize(raw_version)
        super(
          NAME,
          Version.new(raw_version),
          DEPRECATED_VERSIONS,
          SUPPORTED_VERSIONS
        )
      end

      sig { override.returns(T::Boolean) }
      def deprecated?
        false
      end

      sig { override.returns(T::Boolean) }
      def unsupported?
        false
      end
    end

    DEFAULT_PACKAGE_MANAGER = NpmPackageManager::NAME

    # Define a type alias for the expected class interface
    NpmAndYarnPackageManagerClassType = T.type_alias do
      T.any(
        T.class_of(Dependabot::NpmAndYarn::NpmPackageManager),
        T.class_of(Dependabot::NpmAndYarn::YarnPackageManager),
        T.class_of(Dependabot::NpmAndYarn::PNPMPackageManager)
      )
    end

    PACKAGE_MANAGER_CLASSES = T.let({
      NpmPackageManager::NAME => NpmPackageManager,
      YarnPackageManager::NAME => YarnPackageManager,
      PNPMPackageManager::NAME => PNPMPackageManager
    }.freeze, T::Hash[String, NpmAndYarnPackageManagerClassType])

    class PackageManagerDetector
      extend T::Sig
      extend T::Helpers

      sig do
        params(
          lockfiles: T::Hash[Symbol, T.nilable(Dependabot::DependencyFile)],
          package_json: T.nilable(T::Hash[String, T.untyped])
        ).void
      end
      def initialize(lockfiles, package_json)
        @lockfiles = lockfiles
        @package_json = package_json
        @manifest_package_manager = T.let(package_json&.fetch(MANIFEST_PACKAGE_MANAGER_KEY, nil), T.nilable(String))
        @engines = T.let(package_json&.fetch(MANIFEST_ENGINES_KEY, {}), T::Hash[String, T.untyped])
      end

      # Returns npm, yarn, or pnpm based on the lockfiles, package.json, and engines
      # Defaults to npm if no package manager is detected
      sig { returns(String) }
      def detect_package_manager
        name_from_lockfiles || name_from_package_manager_attr || name_from_engines || DEFAULT_PACKAGE_MANAGER
      end

      private

      sig { returns(T.nilable(String)) }
      def name_from_lockfiles
        PACKAGE_MANAGER_CLASSES.keys.map(&:to_s).find { |manager_name| @lockfiles[manager_name.to_sym] }
      end

      sig { returns(T.nilable(String)) }
      def name_from_package_manager_attr
        return unless @manifest_package_manager

        PACKAGE_MANAGER_CLASSES.keys.map(&:to_s).find do |manager_name|
          @manifest_package_manager.start_with?("#{manager_name}@")
        end
      end

      sig { returns(T.nilable(String)) }
      def name_from_engines
        return unless @engines.is_a?(Hash)

        PACKAGE_MANAGER_CLASSES.each_key do |manager_name|
          return manager_name if @engines[manager_name]
        end
        nil
      end
    end

    class PackageManagerHelper
      extend T::Sig
      extend T::Helpers

      sig do
        params(
          package_json: T.nilable(T::Hash[String, T.untyped]),
          lockfiles: T::Hash[Symbol, T.nilable(Dependabot::DependencyFile)]
        ).void
      end
      def initialize(package_json, lockfiles:)
        @package_json = package_json
        @lockfiles = lockfiles
        @package_manager_detector = T.let(PackageManagerDetector.new(lockfiles, package_json), PackageManagerDetector)
        @manifest_package_manager = T.let(package_json&.fetch(MANIFEST_PACKAGE_MANAGER_KEY, nil), T.nilable(String))
        @engines = T.let(package_json&.fetch(MANIFEST_ENGINES_KEY, nil), T.nilable(T::Hash[String, T.untyped]))

        @installed_versions = T.let({}, T::Hash[String, String])
      end

      sig { returns(Ecosystem::VersionManager) }
      def package_manager
        package_manager_by_name(
          @package_manager_detector.detect_package_manager
        )
      end

      # rubocop:disable Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/PerceivedComplexity
      # rubocop:disable Metrics/AbcSize
      sig { params(name: String).returns(T.nilable(T.any(Integer, String))) }
      def setup(name)
        # we prioritize version mentioned in "packageManager" instead of "engines"
        # i.e. if { engines : "pnpm" : "6" } and { packageManager: "pnpm@6.0.2" },
        # we go for the specificity mentioned in packageManager (6.0.2)

        unless @manifest_package_manager&.start_with?("#{name}@") ||
               (@manifest_package_manager&.==name.to_s) ||
               @manifest_package_manager.nil?
          return
        end

        if @engines && @manifest_package_manager.nil?
          # if "packageManager" doesn't exists in manifest file,
          # we check if we can extract "engines" information
          version = check_engine_version(name)

        elsif @manifest_package_manager&.==name.to_s
          # if "packageManager" is found but no version is specified (i.e. pnpm@1.2.3),
          # we check if we can get "engines" info to override default version
          version = check_engine_version(name) if @engines

        elsif @manifest_package_manager&.start_with?("#{name}@")
          # if "packageManager" info has version specification i.e. yarn@3.3.1
          # we go with the version in "packageManager"
          Dependabot.logger.info(
            "Found \"#{MANIFEST_PACKAGE_MANAGER_KEY}\" : \"#{@manifest_package_manager}\". " \
            "Skipped checking \"#{MANIFEST_ENGINES_KEY}\"."
          )
        end

        if Dependabot::Experiments.enabled?(:enable_corepack_for_npm_and_yarn)
          version ||= requested_version(name) || guessed_version(name)

          if version
            raise_if_unsupported!(name, version.to_s)
            install(name, version.to_s)
          end
        else
          version ||= requested_version(name)

          if version
            raise_if_unsupported!(name, version.to_s)

            install(name, version)
          else
            version = guessed_version(name)

            if version
              raise_if_unsupported!(name, version.to_s)

              install(name, version.to_s) if name == PNPMPackageManager::NAME
            end
          end
        end
        version
      end

      sig { params(name: T.nilable(String)).returns(Ecosystem::VersionManager) }
      def package_manager_by_name(name)
        name = ensure_valid_package_manager(name)

        package_manager_class = T.must(PACKAGE_MANAGER_CLASSES[name])

        installed_version = installed_version(name)

        package_manager_class.new(installed_version)
      end

      # rubocop:enable Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/PerceivedComplexity
      # rubocop:enable Metrics/AbcSize
      # Retrieve the installed version of the package manager by executing
      # the "corepack <name> -v" command and using the output.
      # If the output does not match the expected version format (PACKAGE_MANAGER_VERSION_REGEX),
      # fall back to the version inferred from the dependency files.
      sig { params(name: String).returns(String) }
      def installed_version(name)
        # Return the memoized version if it has already been computed
        return T.must(@installed_versions[name]) if @installed_versions.key?(name)

        # Attempt to get the installed version through the package manager version command
        @installed_versions[name] = Helpers.package_manager_version(name)

        # If we can't get the installed version, we need to install the package manager and get the version
        unless @installed_versions[name]&.match?(PACKAGE_MANAGER_VERSION_REGEX)
          setup(name)
          @installed_versions[name] = Helpers.package_manager_version(name)
        end

        # If we can't get the installed version or the version is invalid, we need to get inferred version
        unless @installed_versions[name]&.match?(PACKAGE_MANAGER_VERSION_REGEX)
          @installed_versions[name] = Helpers.public_send(:"#{name}_version_numeric", @lockfiles[name.to_sym]).to_s
        end

        T.must(@installed_versions[name])
      end

      private

      sig { params(name: String, version: String).void }
      def raise_if_unsupported!(name, version)
        return unless name == PNPMPackageManager::NAME
        return unless Version.new(version) < Version.new("7")

        raise ToolVersionNotSupported.new(PNPMPackageManager::NAME.upcase, version, "7.*, 8.*")
      end

      sig { params(name: String, version: T.nilable(String)).void }
      def install(name, version)
        if Dependabot::Experiments.enabled?(:enable_corepack_for_npm_and_yarn)
          return Helpers.install(name, version.to_s)
        end

        Dependabot.logger.info("Installing \"#{name}@#{version}\"")

        SharedHelpers.run_shell_command(
          "corepack install #{name}@#{version} --global --cache-only",
          fingerprint: "corepack install <name>@<version> --global --cache-only"
        )
      end

      sig { params(name: T.nilable(String)).returns(String) }
      def ensure_valid_package_manager(name)
        name = DEFAULT_PACKAGE_MANAGER if name.nil? || PACKAGE_MANAGER_CLASSES[name].nil?
        name
      end

      sig { params(name: String).returns(T.nilable(String)) }
      def requested_version(name)
        return unless @manifest_package_manager

        match = @manifest_package_manager.match(/^#{name}@(?<version>\d+.\d+.\d+)/)
        return unless match

        Dependabot.logger.info("Requested version #{match['version']}")
        match["version"]
      end

      sig { params(name: String).returns(T.nilable(T.any(Integer, String))) }
      def guessed_version(name)
        lockfile = @lockfiles[name.to_sym]
        return unless lockfile

        version = Helpers.send(:"#{name}_version_numeric", lockfile)

        Dependabot.logger.info("Guessed version info \"#{name}\" : \"#{version}\"")

        version
      end

      sig { params(name: T.untyped).returns(T.nilable(String)) }
      def check_engine_version(name)
        return if @package_json.nil?

        version_selector = VersionSelector.new
        engine_versions = version_selector.setup(@package_json, name)

        return if engine_versions.empty?

        version = engine_versions[name]
        Dependabot.logger.info("Returned (#{MANIFEST_ENGINES_KEY}) info \"#{name}\" : \"#{version}\"")
        version
      end
    end
  end
end
