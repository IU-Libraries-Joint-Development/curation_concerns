require 'uri'
require 'tempfile'
require 'browse_everything/retriever'

# Given a FileSet that has an import_url property,
# download that file and put it into Fedora
# Called by AttachFilesToWorkJob (when files are uploaded to s3)
# and CreateWithRemoteFilesActor when files are located in some other service.
class ImportUrlJob < ActiveJob::Base
  queue_as CurationConcerns.config.ingest_queue_name

  before_enqueue do |job|
    log = job.arguments.last
    log.pending_job(job)
  end

  def perform(file_set, log)
    log.performing!
    user = User.find_by_user_key(file_set.depositor)

    Tempfile.open(file_set.id.tr('/', '_')) do |f|
      copy_remote_file(file_set, f)

      # reload the FileSet once the data is copied since this is a long running task
      file_set.reload

      # We invoke the FileSetActor in a synchronous way so that this tempfile is available
      # when IngestFileJob is invoked. If it was asynchronous the IngestFileJob may be invoked
      # on a machine that did not have this temp file on it's file system.
      # NOTE: The return status may be successful even if the content never attaches.
      if CurationConcerns::Actors::FileSetActor.new(file_set, user).create_content(f, false)
        # send message to user on download success
        CurationConcerns.config.callback.run(:after_import_url_success, file_set, user)
        log.success!
      else
        CurationConcerns.config.callback.run(:after_import_url_failure, file_set, user)
        log.fail!(file_set.errors.full_messages.join(' '))
      end
    end
  end

  protected

    def copy_remote_file(file_set, f)
      f.binmode
      # download file from url
      uri = URI(file_set.import_url)
      spec = { 'url' => uri }
      retriever = BrowseEverything::Retriever.new
      retriever.retrieve(spec) do |chunk|
        f.write(chunk)
      end
      f.rewind
    end
end
