# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "generators/recording_studio_logs/migrations/migrations_generator"

class MigrationsGeneratorTest < Minitest::Test
  RUNS = "create_recording_studio_logs_runs.rb"
  RENAME = "rename_aggregation_run_day_to_period_start.rb"

  def test_copies_engine_migrations_and_skips_ones_the_host_already_has
    Dir.mktmpdir do |dir|
      migrate = File.join(dir, "db/migrate")
      FileUtils.mkdir_p(migrate)
      File.write(File.join(migrate, "20260101000000_#{RUNS}"), "# already installed\n")

      output, = capture_io { generator(dir).copy_migrations }
      created = Dir.children(migrate).reject { |name| name == "20260101000000_#{RUNS}" }

      assert_equal 1, created.size
      assert created.first.end_with?("_#{RENAME}")
      assert_includes File.read(File.join(migrate, created.first)), "RenameAggregationRunDayToPeriodStart"
      assert_includes output, "skip  #{RUNS}"
      assert_includes output, "create  db/migrate/#{created.first}"

      again, = capture_io { generator(dir).copy_migrations }
      assert_equal 2, Dir.children(migrate).size
      assert_includes again, "skip  #{RENAME}"
    end
  end

  def test_tells_the_host_when_the_engine_has_no_migrations_to_copy
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      empty_engine = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(empty_engine, "db/migrate"))
      missing = File.join(dir, "missing-engine")

      empty_output, = capture_io do
        generator(dir).class.stub(:source_root, empty_engine) { generator(dir).copy_migrations }
      end
      missing_output, = capture_io do
        generator(dir).class.stub(:source_root, missing) { generator(dir).copy_migrations }
      end

      assert_empty Dir.children(File.join(dir, "db/migrate"))
      assert_includes empty_output, "No migrations found"
      assert_includes missing_output, "No migrations found"
    end
  end

  private

  def generator(dir)
    RecordingStudioLogs::Generators::MigrationsGenerator.new([], {}, destination_root: dir)
  end
end
