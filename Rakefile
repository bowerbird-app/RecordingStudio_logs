# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

DUMMY_TEST_FILES = [
  File.expand_path("test/controllers/docs_controller_test.rb", __dir__),
  File.expand_path("test/recording_studio_declarations_test.rb", __dir__)
].freeze
DUMMY_GEMFILE = File.expand_path("test/dummy/Gemfile", __dir__)
SIMPLECOV_HELPER = File.expand_path("test/simplecov_helper.rb", __dir__)
DUMMY_APP_ROOT = File.expand_path("test/dummy", __dir__)
TEST_ROOT = File.expand_path("test", __dir__)
ROOT_TEST_EXCLUSIONS = %w[
  test/controllers/docs_controller_test.rb
  test/dummy/**/*_test.rb
  test/recording_studio_declarations_test.rb
].freeze
DUMMY_BUNDLE_CLEARED_ENV = {
  "BUNDLE_APP_CONFIG" => nil,
  "BUNDLE_BIN_PATH" => nil,
  "BUNDLE_GEMFILE" => DUMMY_GEMFILE,
  "BUNDLE_LOCKFILE" => nil,
  "BUNDLER_SETUP" => nil,
  "BUNDLER_VERSION" => nil,
  "RUBYLIB" => nil,
  "RUBYOPT" => nil
}.freeze

def run_command!(env, *command)
  return if Bundler.with_unbundled_env { system(env, *command) }

  raise "Command failed (#{Process.last_status.exitstatus}): #{command.join(' ')}"
end

def dummy_bundle_env
  dummy_bundle_base_env.merge(DUMMY_BUNDLE_CLEARED_ENV).tap do |env|
    env["BUNDLE_PATH"] = ENV["BUNDLE_PATH"] if ENV["BUNDLE_PATH"]
  end
end

def dummy_bundle_base_env
  {
    "BUNDLE_GEMFILE" => DUMMY_GEMFILE
  }
end

def run_dummy_suite
  Dir.chdir(DUMMY_APP_ROOT) do
    env = dummy_bundle_env
    run_command!(env, "bundle", "exec", "bin/rails", "db:prepare")
    run_dummy_rails_tests(env)
    run_dummy_host_tests(env)
  end
end

# bin/rails boots the app before test_helper, so start SimpleCov in this process first.
def run_dummy_rails_tests(env)
  run_command!(
    env.merge("SIMPLECOV_COMMAND_NAME" => "dummy"),
    "bundle", "exec", "ruby", "-r#{SIMPLECOV_HELPER}", "bin/rails", "test"
  )
end

def run_dummy_host_tests(env)
  DUMMY_TEST_FILES.each do |test_file|
    command_name = "dummy-host-#{File.basename(test_file, '.rb')}"
    run_command!(
      env.merge("SIMPLECOV_COMMAND_NAME" => command_name),
      "bundle", "exec", "ruby", "-I#{TEST_ROOT}", test_file
    )
  end
end

def collate_coverage
  require "simplecov"

  result_files = Dir[File.expand_path("coverage/results/**/.resultset.json", __dir__)]
  raise "No coverage results to collate. Run the gem and dummy suites first." if result_files.empty?

  SimpleCov.collate(result_files, &coverage_profile)
  report_collated_coverage(SimpleCov.result)
end

def coverage_profile
  gem_root = File.expand_path(".", __dir__)
  proc do
    root gem_root
    enable_coverage :branch
    coverage_dir File.join(gem_root, "coverage")
    cover "{app,lib}/**/*.rb"
  end
end

def report_collated_coverage(result)
  line = result.coverage_statistics(:line)
  branch = result.coverage_statistics(:branch)
  puts "Combined app/+lib/ line coverage: #{line.percent.floor(2)}% (#{line.covered}/#{line.total})"
  puts "Combined app/+lib/ branch coverage: #{branch.percent.floor(2)}% (#{branch.covered}/#{branch.total})"
  write_coverage_gaps(result)
end

def write_coverage_gaps(result)
  lines = result.files.filter_map { |file| coverage_gap_line(file) }
  File.write(File.expand_path("coverage/gaps.txt", __dir__), "#{lines.join("\n")}\n")
end

def coverage_gap_line(file)
  missed = file.missed_lines.size
  return if missed.zero?

  "#{missed} missed / #{file.lines_of_code} #{file.covered_percent}% #{file.filename}"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude(*ROOT_TEST_EXCLUSIONS)
  t.verbose = false
end

namespace :test do
  desc "Run dummy app integration tests under the dummy app bundle"
  task(:dummy) { run_dummy_suite }

  desc "Collate gem and dummy SimpleCov results over app/ and lib/"
  task(:coverage) { collate_coverage }

  desc "Run gem and dummy app tests, then collate coverage"
  task all: %i[test dummy coverage]
end

namespace :app do
  desc "Run all tests for the gem"
  task test: "test:all"
end

task default: :test
