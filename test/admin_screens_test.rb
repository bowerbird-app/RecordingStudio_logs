# frozen_string_literal: true

require "test_helper"

class AdminScreensTest < Minitest::Test
  FakeRow = Struct.new(:status)

  def test_screens_load_against_the_admin_dsl
    require "recording_studio_admin"
    source = Gem.loaded_specs.fetch("recording_studio_admin").source
    assert_equal "v2.7.0", source.options["tag"]

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

  def test_logs_section_links_detail_screens_without_a_primary_health_link
    require "recording_studio_admin"
    RecordingStudioAdmin.registry.clear!
    RecordingStudioLogs::Admin.register!

    section = RecordingStudioAdmin.section_for("logs")
    names = section.links.map(&:name)
    health = section.links.find { |link| link.name == :health }

    assert_equal :secondary, health.style
    assert_includes names, :log_detail
    assert_includes names, :summary_detail
  end

  def test_detail_screens_resolve_for_an_enabled_root
    require "recording_studio_admin"
    require "recording_studio_accessible"
    RecordingStudioAdmin.registry.clear!
    RecordingStudioLogs::Admin.register!

    with_enabled_logs_root do |context|
      %w[log_detail summary_detail].each do |key|
        assert RecordingStudioAdmin.screen_enabled?(key: key, recording: context.access_recording, context: context),
               key

        screen = RecordingStudioAdmin.resolve_screen(key: key, context: context)
        assert_equal key, screen.key
      end
    end
  end

  def test_status_filters_and_widget_links_match_needs_attention
    require "recording_studio_admin"
    RecordingStudioAdmin.registry.clear!
    RecordingStudioLogs::Admin.register!

    health = RecordingStudioAdmin.screen_for("log_health")
    summaries = RecordingStudioAdmin.screen_for("summaries")
    health_filter = health.filters.find { |filter| filter.key == :status }
    summary_filter = summaries.filters.find { |filter| filter.key == :status }
    rows = [FakeRow.new("OK"), FakeRow.new("Missing month"), FakeRow.new("Failed")]
    context = RecordingStudioAdmin::Context.new
    look = RecordingStudioAdmin.widget_for("widgets.logs.needs_attention")
    stuck = RecordingStudioAdmin.widget_for("widgets.logs.stuck_summaries")

    assert_equal RecordingStudioLogs::Admin::Status::LOG_FILTERS, health_filter.allowed_values
    assert_equal RecordingStudioLogs::Admin::Status::SUMMARY_FILTERS, summary_filter.allowed_values
    assert_equal ["Missing month", "Failed"],
                 health_filter.apply(rows, RecordingStudioLogs::Admin::Status::NEEDS_ATTENTION, nil).map(&:status)
    assert_equal ["Failed"], summary_filter.apply(rows, "Failed", nil).map(&:status)
    assert_equal RecordingStudioLogs::Admin::Status::NEEDS_ATTENTION,
                 query_status(look.link_to.call(context))
    assert_equal RecordingStudioLogs::Admin::Status::NEEDS_ATTENTION,
                 query_status(stuck.link_to.call(context))
  end

  def test_status_columns_use_colored_badges
    require "recording_studio_admin"
    RecordingStudioAdmin.registry.clear!
    RecordingStudioLogs::Admin.register!

    %w[log_health summaries summary_detail].each do |key|
      column = RecordingStudioAdmin.screen_for(key).table_value.columns.find { |entry| entry.key == :status }
      options = column.display_options.call(nil, nil, "OK")

      assert_equal :badge, column.display, key
      assert_equal :success, options[:style]
    end

    assert_equal :danger, RecordingStudioLogs::Admin::Status.badge_style("Failed")
    assert_equal :danger, RecordingStudioLogs::Admin::Status.badge_style("Missing table")
    assert_equal :danger, RecordingStudioLogs::Admin::Status.badge_style("failed")
    assert_equal :warning, RecordingStudioLogs::Admin::Status.badge_style("Missing month")
    assert_equal :warning, RecordingStudioLogs::Admin::Status.badge_style("Cleanup waiting")
    assert_equal :default, RecordingStudioLogs::Admin::Status.badge_style("Waiting")
    assert_equal :success, RecordingStudioLogs::Admin::Status.badge_style("succeeded")
  end

  private

  def with_enabled_logs_root
    recording = Object.new
    original_sections = RecordingStudioAdmin.configuration.admin_sections_resolver
    original_recording = RecordingStudioAdmin.configuration.access_recording_resolver
    RecordingStudioAdmin.configuration.admin_sections_resolver = -> { %w[logs] }
    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) { recording }
    context = RecordingStudioAdmin::Context.new(current_actor: Object.new)

    RecordingStudioAccessible.stub(:authorized?, true) do
      yield context
    end
  ensure
    RecordingStudioAdmin.configuration.admin_sections_resolver = original_sections
    RecordingStudioAdmin.configuration.access_recording_resolver = original_recording
  end

  def query_status(path)
    uri = URI.parse(path)
    Rack::Utils.parse_query(uri.query).fetch("status")
  end
end
