# frozen_string_literal: true

module PatientHttp
  # Namespace for the payload store adapters that keep large payloads out of
  # serialized requests and responses.
  module PayloadStore
    autoload :Base, File.join(__dir__, "payload_store/base")
    autoload :ActiveRecordStore, File.join(__dir__, "payload_store/active_record_store")
    autoload :FileStore, File.join(__dir__, "payload_store/file_store")
    autoload :RedisStore, File.join(__dir__, "payload_store/redis_store")
    autoload :S3Store, File.join(__dir__, "payload_store/s3_store")
  end
end
