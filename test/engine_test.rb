# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class EngineTest < Minitest::Test
  def setup
    @original_months_ahead = RecordingStudioLogs.configuration.months_ahead
    @original_reconciliation_days = RecordingStudioLogs.configuration.reconciliation_days
    RecordingStudioLogs.configuration.months_ahead = 2
    RecordingStudioLogs.configuration.reconciliation_days = 3
    RecordingStudioLogs.configuration.clear_retention_overrides!
    RecordingStudioLogs.configuration.hooks.clear!
  end

  def teardown
    RecordingStudioLogs.configuration.months_ahead = @original_months_ahead
    RecordingStudioLogs.configuration.reconciliation_days = @original_reconciliation_days
    RecordingStudioLogs.configuration.clear_retention_overrides!
    RecordingStudioLogs.configuration.hooks.clear!
  end

  def test_before_and_after_initialize_initializers_run_hooks
    before_called = false
    after_called = false

    RecordingStudioLogs.configuration.hooks.before_initialize { |_engine| before_called = true }
    RecordingStudioLogs.configuration.hooks.after_initialize { |_engine| after_called = true }

    find_initializer("recording_studio_logs.before_initialize").block.call(Object.new)
    find_initializer("recording_studio_logs.after_initialize").block.call(Object.new)

    assert before_called
    assert after_called
  end

  def test_load_config_merges_config_sources_and_runs_on_configuration_hook
    hook_called = false
    hook_payload = nil
    RecordingStudioLogs.configuration.hooks.on_configuration do |cfg|
      hook_called = true
      hook_payload = cfg
    end

    xcfg = Struct.new(:recording_studio_logs).new({ months_ahead: 4 })
    app_config = Struct.new(:x).new(xcfg)
    app = Struct.new(:config) do
      def config_for(_name)
        { reconciliation_days: 12 }
      end
    end.new(app_config)

    find_initializer("recording_studio_logs.load_config").block.call(app)

    assert hook_called
    assert_equal RecordingStudioLogs.configuration, hook_payload
    assert_equal 4, RecordingStudioLogs.configuration.months_ahead
    assert_equal 12, RecordingStudioLogs.configuration.reconciliation_days
  end

  def test_load_config_skips_a_missing_yaml_file
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      app = yaml_app(config_dir, extra: { months_ahead: 8 }) do |_name|
        flunk "config_for should not run when the yaml file is missing"
      end

      find_initializer("recording_studio_logs.load_config").block.call(app)

      assert_equal 8, RecordingStudioLogs.configuration.months_ahead
      assert_equal 3, RecordingStudioLogs.configuration.reconciliation_days
    end
  end

  def test_load_config_raises_on_invalid_yaml
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "recording_studio_logs.yml"), "not: [valid")
      error_class = Class.new(StandardError)
      app = yaml_app(config_dir) { |_name| raise error_class, "invalid yaml" }

      assert_raises(error_class) do
        find_initializer("recording_studio_logs.load_config").block.call(app)
      end
    end
  end

  def test_load_config_merges_each_pair_x_config
    pair_config = Class.new do
      def each_pair
        yield(:reconciliation_days, 15)
      end
    end.new

    xcfg = Struct.new(:recording_studio_logs).new(pair_config)
    app_config = Struct.new(:x).new(xcfg)
    app = Struct.new(:config) do
      def config_for(_name)
        {}
      end
    end.new(app_config)

    find_initializer("recording_studio_logs.load_config").block.call(app)

    assert_equal 15, RecordingStudioLogs.configuration.reconciliation_days
  end

  def test_load_config_raises_when_each_pair_fails
    bad_pair_config = Class.new do
      def each_pair
        raise KeyError, "bad pair"
      end
    end.new

    xcfg = Struct.new(:recording_studio_logs).new(bad_pair_config)
    app_config = Struct.new(:x).new(xcfg)
    app = Struct.new(:config) do
      def config_for(_name)
        { months_ahead: 6 }
      end
    end.new(app_config)

    assert_raises(KeyError) do
      find_initializer("recording_studio_logs.load_config").block.call(app)
    end
  end

  def test_load_config_is_noop_without_config_sources
    app = Struct.new(:config).new(Object.new)

    find_initializer("recording_studio_logs.load_config").block.call(app)

    assert_equal 2, RecordingStudioLogs.configuration.months_ahead
    assert_equal 3, RecordingStudioLogs.configuration.reconciliation_days
  end

  def test_load_config_skips_a_nil_yaml_path
    app = Struct.new(:config, :root).new(Struct.new(:x).new(nil), nil)
    def app.config_for(_name)
      flunk "config_for should not run when the yaml path is nil"
    end

    find_initializer("recording_studio_logs.load_config").block.call(app)

    assert_equal 2, RecordingStudioLogs.configuration.months_ahead
  end

  def test_engine_does_not_extend_host_models_or_controllers
    names = RecordingStudioLogs::Engine.initializers.map(&:name)

    refute_includes names, "recording_studio_logs.apply_model_extensions"
    refute_includes names, "recording_studio_logs.apply_controller_extensions"
    refute RecordingStudioLogs::Engine.respond_to?(:apply_model_extensions)
    refute RecordingStudioLogs::Engine.respond_to?(:apply_controller_extensions)
  end

  private

  def yaml_app(config_dir, extra: nil, &config_for)
    paths = { "config" => [config_dir] }
    xcfg = Struct.new(:recording_studio_logs).new(extra)
    app_config = Struct.new(:x).new(xcfg)
    app = Struct.new(:config, :paths).new(app_config, paths)
    app.define_singleton_method(:config_for, config_for)
    app
  end

  def find_initializer(name)
    RecordingStudioLogs::Engine.initializers.find { |initializer| initializer.name == name }
  end
end
