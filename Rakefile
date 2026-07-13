begin
  require "bundler/setup"
rescue LoadError
  puts "You must `gem install bundler` and `bundle install` to run rake tasks"
end

require "bundler/gem_tasks"

task :verify_release_branch do
  unless `git rev-parse --abbrev-ref HEAD`.chomp == "main"
    warn "Gem can only be released from the main branch"
    exit 1
  end
end

Rake::Task[:release].prerequisites.prepend("verify_release_branch")

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: [:spec]

namespace :appraisal do
  desc "Update the appraisal gemfiles"
  task :update do
    Dir.glob("gemfiles/*.gemfile*") do |file|
      File.delete(file) if File.file?(file)
    end

    system "bundle exec appraisal generate" || abort("appraisal generate failed")

    Dir.glob("gemfiles/*.gemfile") do |file|
      puts "Locking #{file}"
      Bundler.with_unbundled_env do
        system(
          {
            "BUNDLE_GEMFILE" => file
          },
          "bundle", "lock", "--update"
        ) || abort("appraisal lock failed on #{file}")
      end
    end
  end
end

desc "Start a valkey container for testing running on port 24455"
task :valkey do
  exec "exec bin/run-valkey"
end

desc "Run the test application for manual testing"
task test_app: "test_app:start"

namespace :test_app do
  desc "Start the test application"
  task :start do
    ENV["BUNDLE_GEMFILE"] = File.expand_path("test_app/Gemfile", __dir__)
    exec "cd test_app && ruby server"
  end

  desc "Stop the running test application on default port 9292 or PORT env var"
  task :stop do
    port = ENV.fetch("PORT", "9292").to_i
    pids = `lsof -ti :#{port}`.split("\n").map(&:strip).reject(&:empty?)

    if pids.empty?
      puts "No running test application found (port #{port} is not in use)"
    else
      pids.each do |pid|
        puts "Killing process #{pid}..."
        system("kill #{pid}")
      end
      sleep 1
      puts "Test application stopped"
    end
  end

  desc "Open an interactive console with test application loaded"
  task :console do
    ENV["BUNDLE_GEMFILE"] = File.expand_path("test_app/Gemfile", __dir__)
    exec "cd test_app && ruby console"
  end

  desc "Install bundle for the test application"
  task :bundle do
    ENV["BUNDLE_GEMFILE"] = File.expand_path("test_app/Gemfile", __dir__)
    exec "cd test_app && bundle install"
  end
end
