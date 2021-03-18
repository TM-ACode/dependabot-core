# frozen_string_literal: true

require_relative "path_level"
require_relative "pr_info"
require_relative "auto_merge"
require "dependabot/docker"
require "dependabot/python"

# rubocop:disable Metrics/ParameterLists
def create_pr(package_manager, source, commit, updated_deps, updated_files, credentials_github)
  pr_message_footer = pr_info(updated_deps.first) unless package_manager == "pip"

  # Create a pull request for the update
  pr = Dependabot::PullRequestCreator.new(
    source: source,
    base_commit: commit,
    dependencies: updated_deps,
    files: updated_files,
    credentials: credentials_github,
    label_language: true,
    branch_name_prefix: nil,
    branch_name_separator: "-",
    pr_message_footer: pr_message_footer || nil
  )
  pr.create
end
# rubocop:enable Metrics/ParameterLists

def requirements(checker)
  requirements =
    if !checker.requirements_unlocked_or_can_be?
      if checker.can_update?(requirements_to_unlock: :none) then :none
      else :update_not_possible
      end
    elsif checker.can_update?(requirements_to_unlock: :own) then :own
    elsif checker.can_update?(requirements_to_unlock: :all) then :all
    else :update_not_possible
    end
  requirements
end

def fetch_files_and_commit(package_manager, source, credentials_github)
  # Fetch the dependency files
  fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).
            new(source: source, credentials: credentials_github)

  files = fetcher.files
  commit = fetcher.commit

  [files, commit]
end

def fetch_dependencies(package_manager, files, source)
  # Parse the dependency files
  parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
    dependency_files: files, source: source
  )
  parser.parse
end

def update_files(package_manager, dep, updated_deps, files, github_credentials)
  # Generate updated dependency files
  print "  - Updating #{dep.name} (from #{dep.version}) \n"
  updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
    dependencies: updated_deps, dependency_files: files, credentials: github_credentials
  )
  updater.updated_dependency_files
end

def checker_init(package_manager, dep, files, extra_credentials)
  # Get update details for the dependency
  Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
    dependency: dep, dependency_files: files, credentials: extra_credentials
  )
end

def source_init(file_path, project_data)
  Dependabot::Source.new(
    provider: "github", repo: project_data["repo"],
    directory: file_path, branch: project_data["branch"]
  )
end

def checker_up_to_date(checker)
  checker.up_to_date?
end

def checker_updated_dependencies(checker, requirements_to_unlock)
  checker.updated_dependencies(
    requirements_to_unlock: requirements_to_unlock
  )
end

# rubocop:disable Metrics/AbcSize
def pix4_dependabot(package_manager, project_data, github_credentials, extra_credentials)
  input_files_path = recursive_path(project_data, github_credentials["password"])

  print "Working in #{project_data['repo']}\n"
  input_files_path.each do |file_path|
    print "  - Checking the files in #{file_path}\n"
    source = source_init(file_path, project_data)
    files, commit = fetch_files_and_commit(package_manager, source, [github_credentials])
    dependencies = fetch_dependencies(package_manager, files, source)

    dependencies.select(&:top_level?).each do |dep|
      checker = checker_init(package_manager, dep, files, extra_credentials)
      next if checker_up_to_date(checker)

      requirements_to_unlock = requirements(checker)
      next if requirements_to_unlock == :update_not_possible

      updated_deps = checker_updated_dependencies(checker, requirements_to_unlock)
      next if updated_deps.first.version == updated_deps.first.previous_version

      updated_files = update_files(package_manager, dep, updated_deps, files, [github_credentials])

      pull_request = create_pr(package_manager, source, commit, updated_deps, updated_files,
                               [github_credentials])
      next unless pull_request

      print "#{pull_request[:html_url]}\n\n"

      next unless project_data["module"] == "docker" && project_data["repo"] == "Pix4D/linux-image-build"

      auto_merge(pull_request[:number], pull_request[:head][:ref], project_data["repo"], github_credentials["password"])
    end
  end
  "Success"
end
# rubocop:enable Metrics/AbcSize
