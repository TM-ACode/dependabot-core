# typed: strict
# frozen_string_literal: true

require "dependabot/updater/group_update_creation"
require "dependabot/updater/operations/operation_base"
require "sorbet-runtime"

# This class implements our strategy for refreshing a single Pull Request which
# updates all outdated Dependencies within a specific project folder that match
# a specified Dependency Group.
#
# Refreshing a Dependency Group pull request essentially has two outcomes, we
# either update or supersede the existing PR.
#
# To decide which strategy to use, we recompute the DependencyChange on the
# current head of the target branch and:
# - determine that all the same dependencies change to the same versions
#   - in this case we update the existing PR
# - determine that one or more dependencies are now involved or removed
#   - in this case we close the existing PR and create a new one
# - determine that all the dependencies are the same, but versions have changed
#   -in this case we close the existing PR and create a new one
module Dependabot
  class Updater
    module Operations
      class RefreshGroupUpdatePullRequest < GroupUpdateCreation
        extend T::Sig

        # rubocop:disable Metrics/PerceivedComplexity
        sig { override.params(job: Dependabot::Job).returns(T::Boolean) }
        def self.applies_to?(job:)
          # If we haven't been given metadata about the dependencies present
          # in the pull request and the Dependency Group that originally created
          # it, this strategy cannot act.
          return false unless job.dependencies&.any?
          return false unless job.dependency_group_to_refresh
          if Dependabot::Experiments.enabled?(:grouped_security_updates_disabled) && job.security_updates_only?
            return false
          end

          return true if job.source.directories && T.must(job.source.directories).count > 1

          if job.security_updates_only?
            return true if T.must(job.dependencies).count > 1
            return true if job.dependency_groups.any? { |group| group["applies-to"] == "security-updates" }

            return false
          end

          job.updating_a_pull_request?
        end
        # rubocop:enable Metrics/PerceivedComplexity

        sig { override.returns(Symbol) }
        def self.tag_name
          :update_version_group_pr
        end

        # rubocop:disable Metrics/AbcSize
        sig { override.void }
        def perform
          # This guards against any jobs being performed where the data is malformed, this should not happen unless
          # there was is defect in the service and we emitted a payload where the job and configuration data objects
          # were out of sync.
          unless dependency_snapshot.job_group
            Dependabot.logger.warn(
              "The '#{job.dependency_group_to_refresh || 'unknown'}' group has been removed from the update config."
            )

            service.capture_exception(
              error: DependabotError.new("Attempted to refresh a missing group."),
              job: job
            )
            return
          end

          job_group = T.must(dependency_snapshot.job_group)

          Dependabot.logger.info("Starting PR update job for #{job.source.repo}")

          if job_group.dependencies.empty?
            # If the group is empty that means any Dependencies that did match this group
            # have been removed from the project or are no longer allowed by the config.
            #
            # Let's warn that the group is empty and then signal the PR should be closed
            # so users are informed this group is no longer actionable by Dependabot.
            warn_group_is_empty(job_group)
            close_pull_request(reason: :dependency_group_empty, group: job_group)
          else
            Dependabot.logger.info("Updating the '#{job_group.name}' group")

            # Preprocess to discover existing group PRs and add their dependencies to the handled list before processing
            # the refresh. This prevents multiple PRs from being created for the same dependency during the refresh.
            dependency_snapshot.groups.each do |group|
              next unless group.name != job_group.name && pr_exists_for_dependency_group?(group)

              dependency_snapshot.add_handled_dependencies(
                dependencies_in_existing_pr_for_group(group).filter_map { |d| d["dependency-name"] }
              )
            end

            if dependency_change.nil?
              Dependabot.logger.info("Nothing could update for Dependency Group: '#{job_group.name}'")
              return
            end

            upsert_pull_request_with_error_handling(T.must(dependency_change), job_group)
          end
        end
        # rubocop:enable Metrics/AbcSize

        private

        sig { returns(T.nilable(Dependabot::DependencyChange)) }
        def dependency_change
          return @dependency_change if defined?(@dependency_change)

          job_group = T.must(dependency_snapshot.job_group)

          if job.source.directories.nil?
            @dependency_change = compile_all_dependency_changes_for(job_group)
          else
            dependency_changes = T.let(T.must(job.source.directories).filter_map do |directory|
              job.source.directory = directory
              dependency_snapshot.current_directory = directory
              compile_all_dependency_changes_for(job_group)
            end, T::Array[Dependabot::DependencyChange])

            # merge the changes together into one
            dependency_change = T.let(T.must(dependency_changes.first), Dependabot::DependencyChange)
            dependency_change.merge_changes!(T.must(dependency_changes[1..-1])) if dependency_changes.count > 1
            @dependency_change = T.let(dependency_change, T.nilable(Dependabot::DependencyChange))
          end
        end

        sig { params(dependency_change: Dependabot::DependencyChange, group: Dependabot::DependencyGroup).void }
        def upsert_pull_request_with_error_handling(dependency_change, group)
          if dependency_change.updated_dependencies.any?
            upsert_pull_request(dependency_change, group)
          else
            Dependabot.logger.info("No updated dependencies, closing existing Pull Request")
            close_pull_request(reason: :update_no_longer_possible, group: group)
          end
        rescue StandardError => e
          error_handler.handle_job_error(error: e, dependency_group: dependency_snapshot.job_group)
        end

        # Having created the dependency_change, we need to determine the right strategy to apply it to the project:
        # - Replace existing PR if the dependencies involved have changed
        # - Update the existing PR if the dependencies and the target versions remain the same
        # - Supersede the existing PR if the dependencies are the same but the target versions have changed
        sig { params(dependency_change: Dependabot::DependencyChange, group: Dependabot::DependencyGroup).void }
        def upsert_pull_request(dependency_change, group)
          if dependency_change.should_replace_existing_pr?
            Dependabot.logger.info("Dependencies have changed, closing existing Pull Request")
            close_pull_request(reason: :dependencies_changed, group: group)
            Dependabot.logger.info("Creating a new pull request for '#{group.name}'")
            service.create_pull_request(dependency_change, dependency_snapshot.base_commit_sha)
          elsif dependency_change.matches_existing_pr?
            Dependabot.logger.info("Updating pull request for '#{group.name}'")
            service.update_pull_request(dependency_change, dependency_snapshot.base_commit_sha)
          else
            # If the changes do not match an existing PR, then we should open a new pull request and leave it to
            # the backend to close the existing pull request with a comment that it has been superseded.
            Dependabot.logger.info("Target versions have changed, existing Pull Request should be superseded")
            Dependabot.logger.info("Creating a new pull request for '#{group.name}'")
            service.create_pull_request(dependency_change, dependency_snapshot.base_commit_sha)
          end
        end

        sig { params(reason: Symbol, group: Dependabot::DependencyGroup).void }
        def close_pull_request(reason:, group:)
          reason_string = reason.to_s.tr("_", " ")
          Dependabot.logger.info(
            "Telling backend to close pull request for the " \
            "#{group.name} group " \
            "(#{job.dependencies&.join(', ')}) - #{reason_string}"
          )

          service.close_pull_request(T.must(job.dependencies), reason)
        end
      end
    end
  end
end
