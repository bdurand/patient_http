# frozen_string_literal: true

module PatientHttp
  # Payload stores for large payloads. Register a store with
  # {Configuration#register_payload_store}.
  module PayloadStore
    autoload :Base, File.join(__dir__, "payload_store/base")
    autoload :ActiveRecordStore, File.join(__dir__, "payload_store/active_record_store")
    autoload :FileStore, File.join(__dir__, "payload_store/file_store")
    autoload :RedisStore, File.join(__dir__, "payload_store/redis_store")
    autoload :S3Store, File.join(__dir__, "payload_store/s3_store")
  end
end
