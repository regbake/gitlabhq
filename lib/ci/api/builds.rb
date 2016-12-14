module Ci
  module API
    # Builds API
    class Builds < Grape::API
      resource :builds do
        # Runs oldest pending build by runner - Runners only
        #
        # Parameters:
        #   token (required) - The uniq token of runner
        #
        # Example Request:
        #   POST /builds/register
        post "register" do
          authenticate_runner!
          required_attributes! [:token]
          not_found! unless current_runner.active?
          update_runner_info

          last_update = Gitlab::Redis.with { |redis| redis.get(current_runner_redis_key)}

          if params[:last_update] != ""
            if :last_update == last_update
              headers 'X-GitLab-Last-Update', last_update
              return build_not_found!
            end
          end

          build = Ci::RegisterBuildService.new.execute(current_runner)

          if build
            Gitlab::Metrics.add_event(:build_found,
                                      project: build.project.path_with_namespace)

            present build, with: Entities::BuildDetails
          else
            Gitlab::Metrics.add_event(:build_not_found)

            if last_update == ""
              Gitlab::Redis.with do |redis|
                new_update = Time.new.inspect
                redis.set(current_runner_redis_key, new_update, ex: 60.minutes)
                headers 'X-GitLab-Last-Update', new_update
              end
            end

            build_not_found!
          end
        end

        # Update an existing build - Runners only
        #
        # Parameters:
        #   id (required) - The ID of a project
        #   state (optional) - The state of a build
        #   trace (optional) - The trace of a build
        # Example Request:
        #   PUT /builds/:id
        put ":id" do
          authenticate_runner!
          build = Ci::Build.where(runner_id: current_runner.id).running.find(params[:id])
          forbidden!('Build has been erased!') if build.erased?

          update_runner_info

          build.update_attributes(trace: params[:trace]) if params[:trace]

          Gitlab::Metrics.add_event(:update_build,
                                    project: build.project.path_with_namespace)

          case params[:state].to_s
          when 'success'
            build.success
          when 'failed'
            build.drop
          end
        end

        # Send incremental log update - Runners only
        #
        # Parameters:
        #   id (required) - The ID of a build
        # Body:
        #   content of logs to append
        # Headers:
        #   Content-Range (required) - range of content that was sent
        #   BUILD-TOKEN (required) - The build authorization token
        # Example Request:
        #   PATCH /builds/:id/trace.txt
        patch ":id/trace.txt" do
          build = Ci::Build.find_by_id(params[:id])
          not_found! unless build
          authenticate_build_token!(build)
          forbidden!('Build has been erased!') if build.erased?

          error!('400 Missing header Content-Range', 400) unless request.headers.has_key?('Content-Range')
          content_range = request.headers['Content-Range']
          content_range = content_range.split('-')

          current_length = build.trace_length
          unless current_length == content_range[0].to_i
            return error!('416 Range Not Satisfiable', 416, { 'Range' => "0-#{current_length}" })
          end

          build.append_trace(request.body.read, content_range[0].to_i)

          status 202
          header 'Build-Status', build.status
          header 'Range', "0-#{build.trace_length}"
        end

        # Authorize artifacts uploading for build - Runners only
        #
        # Parameters:
        #   id (required) - The ID of a build
        #   token (required) - The build authorization token
        #   filesize (optional) - the size of uploaded file
        # Example Request:
        #   POST /builds/:id/artifacts/authorize
        post ":id/artifacts/authorize" do
          require_gitlab_workhorse!
          Gitlab::Workhorse.verify_api_request!(headers)
          not_allowed! unless Gitlab.config.artifacts.enabled
          build = Ci::Build.find_by_id(params[:id])
          not_found! unless build
          authenticate_build_token!(build)
          forbidden!('build is not running') unless build.running?

          if params[:filesize]
            file_size = params[:filesize].to_i
            file_to_large! unless file_size < max_artifacts_size
          end

          status 200
          content_type Gitlab::Workhorse::INTERNAL_API_CONTENT_TYPE
          Gitlab::Workhorse.artifact_upload_ok
        end

        # Upload artifacts to build - Runners only
        #
        # Parameters:
        #   id (required) - The ID of a build
        #   token (required) - The build authorization token
        #   file (required) - Artifacts file
        #   expire_in (optional) - Specify when artifacts should expire (ex. 7d)
        # Parameters (accelerated by GitLab Workhorse):
        #   file.path - path to locally stored body (generated by Workhorse)
        #   file.name - real filename as send in Content-Disposition
        #   file.type - real content type as send in Content-Type
        #   metadata.path - path to locally stored body (generated by Workhorse)
        #   metadata.name - filename (generated by Workhorse)
        # Headers:
        #   BUILD-TOKEN (required) - The build authorization token, the same as token
        # Body:
        #   The file content
        #
        # Example Request:
        #   POST /builds/:id/artifacts
        post ":id/artifacts" do
          require_gitlab_workhorse!
          not_allowed! unless Gitlab.config.artifacts.enabled
          build = Ci::Build.find_by_id(params[:id])
          not_found! unless build
          authenticate_build_token!(build)
          forbidden!('Build is not running!') unless build.running?
          forbidden!('Build has been erased!') if build.erased?

          artifacts_upload_path = ArtifactUploader.artifacts_upload_path
          artifacts = uploaded_file(:file, artifacts_upload_path)
          metadata = uploaded_file(:metadata, artifacts_upload_path)

          bad_request!('Missing artifacts file!') unless artifacts
          file_to_large! unless artifacts.size < max_artifacts_size

          build.artifacts_file = artifacts
          build.artifacts_metadata = metadata
          build.artifacts_expire_in = params['expire_in']

          if build.save
            present(build, with: Entities::BuildDetails)
          else
            render_validation_error!(build)
          end
        end

        # Download the artifacts file from build - Runners only
        #
        # Parameters:
        #   id (required) - The ID of a build
        #   token (required) - The build authorization token
        # Headers:
        #   BUILD-TOKEN (required) - The build authorization token, the same as token
        # Example Request:
        #   GET /builds/:id/artifacts
        get ":id/artifacts" do
          build = Ci::Build.find_by_id(params[:id])
          not_found! unless build
          authenticate_build_token!(build)
          artifacts_file = build.artifacts_file

          unless artifacts_file.file_storage?
            return redirect_to build.artifacts_file.url
          end

          unless artifacts_file.exists?
            not_found!
          end

          present_file!(artifacts_file.path, artifacts_file.filename)
        end

        # Remove the artifacts file from build - Runners only
        #
        # Parameters:
        #   id (required) - The ID of a build
        #   token (required) - The build authorization token
        # Headers:
        #   BUILD-TOKEN (required) - The build authorization token, the same as token
        # Example Request:
        #   DELETE /builds/:id/artifacts
        delete ":id/artifacts" do
          build = Ci::Build.find_by_id(params[:id])
          not_found! unless build
          authenticate_build_token!(build)

          build.erase_artifacts!
        end
      end
    end
  end
end
