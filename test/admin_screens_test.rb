# frozen_string_literal: true

require "test_helper"

class AdminScreensTest < Minitest::Test
  def test_screens_load_against_the_admin_dsl
    require "recording_studio_admin"
    source = Gem.loaded_specs.fetch("recording_studio_admin").source
    assert_equal "v2.3.2", source.options["tag"]

    RecordingStudioAdmin.registry.clear!
    RecordingStudioLogs::Admin.register!

    assert RecordingStudioAdmin.section_for("logs")
    %w[log_health log_detail summaries summary_detail].each do |key|
      assert RecordingStudioAdmin.screen_for(key), key
    end
    assert RecordingStudioAdmin.widget_for("widgets.logs.needs_attention")
    assert RecordingStudioAdmin.widget_for("widgets.logs.stuck_summaries")
  end

  def test_health_and_detail_tables_are_read_only
    require "recording_studio_admin"
    RecordingStudioAdmin.registry.clear!
    RecordingStudioLogs::Admin.register!

    health = RecordingStudioAdmin.screen_for("log_health")
    detail = RecordingStudioAdmin.screen_for("log_detail")
    keys = health.table_value.columns.map(&:key)

    assert_operator health, :<, RecordingStudioAdmin::Screen
    refute_operator health, :<, RecordingStudioAdmin::Resource
    assert_includes keys, :table_name
    assert_includes keys, :rows
    assert_includes keys, :storage
    assert_includes keys, :status
    health.table_value.actions.each do |action|
      assert_nil action.method
    end
    assert_equal %i[setting value], detail.table_value.columns.map(&:key)
    assert_empty detail.table_value.actions
  end

  def test_authorization_fails_closed_without_an_actor_or_recording
    require "recording_studio_admin"
    actor = Object.new
    recording = Object.new

    error = assert_raises(RecordingStudioAdmin::AuthorizationFailed) do
      RecordingStudioAdmin::Authorization.authorize!(
        RecordingStudioAdmin::Context.new(current_actor: nil),
        recording: recording
      )
    end
    assert_match(/current actor is not configured/, error.message)

    error = assert_raises(RecordingStudioAdmin::AuthorizationFailed) do
      RecordingStudioAdmin::Authorization.authorize!(
        RecordingStudioAdmin::Context.new(current_actor: actor),
        recording: nil
      )
    end
    assert_match(/access recording is not configured/, error.message)
  end

  def test_authorization_defers_to_accessible_view
    require "recording_studio_admin"
    require "recording_studio_accessible"

    actor = Object.new
    recording = Object.new
    context = RecordingStudioAdmin::Context.new(current_actor: actor)

    RecordingStudioAccessible.stub(:authorized?, false) do
      assert_raises(RecordingStudioAdmin::AuthorizationFailed) do
        RecordingStudioAdmin::Authorization.authorize!(context, recording: recording)
      end
    end
    RecordingStudioAccessible.stub(:authorized?, true) do
      assert RecordingStudioAdmin::Authorization.authorize!(context, recording: recording)
    end
  end
end
