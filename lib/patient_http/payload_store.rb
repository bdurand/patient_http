# frozen_string_literal: true

module PatientHttp
  # Adapters that store large payloads outside of the job queue.
  module PayloadStore
    autoload :Base, File.join(__dir__, "payload_store/base")
    autoload :ActiveRecordStore, File.join(__dir__, "payload_store/active_record_store")
    autoload :FileStore, File.join(__dir__, "payload_store/file_store")
    autoload :RedisStore, File.join(__dir__, "payload_store/redis_store")
    autoload :S3Store, File.join(__dir__, "payload_store/s3_store")
  end
end
