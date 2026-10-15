# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    @configuration = RecordingStudioLogs::Configuration.new
  end

  def test_merge_updates_known_attributes
    @configuration.merge!(months_ahead: 4, reconciliation_days: 9)

    assert_equal 4, @configuration.months_ahead
    assert_equal 9, @configuration.reconciliation_days
  end

  def test_merge_ignores_unknown_keys
    @configuration.merge!(unknown_key: "ignored", months_ahead: 7)

    refute_respond_to @configuration, :unknown_key
    assert_equal 7, @configuration.months_ahead
  end

  def test_merge_with_non_enumerable_is_noop
    original = @configuration.to_h

    @configuration.merge!(nil)

    assert_equal original[:months_ahead], @configuration.months_ahead
    assert_equal original[:reconciliation_days], @configuration.reconciliation_days
  end

  def test_initialize_defaults
    configuration = RecordingStudioLogs::Configuration.new

    assert_equal 2, configuration.months_ahead
    assert_equal 3, configuration.reconciliation_days
    assert_nil configuration.retention_override("SiteViewLog")
    assert_instance_of RecordingStudio::Hooks, configuration.hooks
  end

  def test_merge_accepts_string_keys
    @configuration.merge!("months_ahead" => 6, "reconciliation_days" => 12)

    assert_equal 6, @configuration.months_ahead
    assert_equal 12, @configuration.reconciliation_days
  end

  def test_to_h_reports_registered_hook_counts
    @configuration.hooks.before_initialize { nil }
    @configuration.hooks.before_initialize { nil }
    @configuration.hooks.after_service { nil }

    result = @configuration.to_h

    assert_equal 2, result.fetch(:hooks_registered).fetch(:before_initialize)
    assert_equal 1, result.fetch(:hooks_registered).fetch(:after_service)
  end

  def test_retention_override_replaces_the_registered_policy
    @configuration.retention_for("SiteViewLog", 5.days)

    assert_equal 5.days, @configuration.retention_override("SiteViewLog")
  end

  def test_configure_without_block_is_safe
    RecordingStudioLogs.configure

    assert_kind_of RecordingStudioLogs::Configuration, RecordingStudioLogs.configuration
  end
end
