# frozen_string_literal: true

# Suppress experimental feature warnings (IO::Buffer used by async gems)
Warning[:experimental] = false

require "bundler/setup"

# SimpleCov must be started before requiring the lib
begin
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
  end
rescue LoadError
  # SimpleCov is not available
end

Bundler.require(:default, :test)

require "webmock/rspec"
require "async/rspec"
require "console"

require_relative "../lib/patient_http"

# Suppress Async task warnings (like EPIPE errors from early connection closes)
# These are expected in tests that intentionally close connections early
Console.logger.level = Logger::FATAL

# Configure Redis URL for tests - use Valkey container on port 24455, database 0
# Can be overridden with REDIS_URL environment variable
# Using 127.0.0.1 instead of localhost to avoid macOS local network permission issues
ENV["REDIS_URL"] ||= "redis://127.0.0.1:24455/0"

# Disable all real HTTP connections except localhost (for test server)
WebMock.disable_net_connect!(allow_localhost: true)

Dir.glob(File.join(__dir__, "support", "**", "*.rb")).sort.each do |file|
  require file
end

$test_web_server = nil # rubocop:disable Style/GlobalVars
def test_web_server
  $test_web_server ||= TestWebServer.new # rubocop:disable Style/GlobalVars
end

PatientHttp.testing = true

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one? || ENV["RSPEC_FORMATTER"] == "doc"
  config.order = :random
  Kernel.srand config.seed

  config.profile_examples = 5 if config.files_to_run.length > 1

  if config.files_to_run.any? { |f| f.include?("/integration/") }
    config.before(:suite) do
      test_web_server.start
    end
  end

  # Include Async::RSpec::Reactor for async tests
  config.include Async::RSpec::Reactor

  config.before(:suite) do
    S3Helper.setup
    ActiveRecordHelper.setup
    RedisHelper.setup
  end

  # Clear S3 bucket before each S3 test
  config.before(:each, :s3) do
    S3Helper.clear_bucket
  end

  config.before(:each, :active_record) do
    ActiveRecordHelper.flushdb
  end

  config.before(:each, :redis) do
    RedisHelper.flushdb
  end

  config.before(:each, :integration) do
    test_web_server.start.ready?
  end

  config.around(:each, :disable_testing_mode) do |example|
    PatientHttp.testing = false
    example.run
  ensure
    PatientHttp.testing = true
  end

  config.after(:suite) do
    test_web_server.stop
  end
end
