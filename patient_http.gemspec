Gem::Specification.new do |spec|
  spec.name = "patient_http"
  spec.version = File.read(File.expand_path("../VERSION", __FILE__)).strip
  spec.authors = ["Brian Durand"]
  spec.email = ["bbdurand@gmail.com"]

  spec.summary = "Generic async HTTP connection pool for Ruby applications using Fiber-based concurrency"
  spec.description = "This gem provides a dedicated async HTTP processor that uses Ruby's Fiber scheduler for non-blocking I/O. Application threads hand off HTTP requests to the processor and return immediately. The processor handles hundreds of concurrent HTTP connections using fibers, then notifies the application when responses arrive via a pluggable callback mechanism. This design keeps application threads free to do other work while HTTP requests are in flight."

  spec.homepage = "https://github.com/bdurand/patient_http"
  spec.license = "MIT"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md"
  }

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  ignore_files = %w[
    .
    AGENTS.md
    Appraisals
    Gemfile
    Gemfile.lock
    Rakefile
    docker-compose.yml
    bin/
    gemfiles/
    spec/
    test_app/
  ]
  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| ignore_files.any? { |path| f.start_with?(path) } }
  end

  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "async", "~> 2.0"
  spec.add_dependency "async-http", "~> 0.60"
  spec.add_dependency "concurrent-ruby", "~> 1.2"
  spec.add_dependency "logger"
end
