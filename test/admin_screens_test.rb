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
end
