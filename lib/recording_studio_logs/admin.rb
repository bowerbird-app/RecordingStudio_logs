# frozen_string_literal: true

module RecordingStudioLogs
  # Read-only RecordingStudioAdmin screens. Loaded only when that gem is present.
  module Admin
    module_function

    def register!
      return unless defined?(::RecordingStudioAdmin)

      require_relative "admin/screens"
      register_widgets
      RecordingStudioAdmin.register_section(LogsSection)
      RecordingStudioAdmin.register_screen(LogHealthScreen)
      RecordingStudioAdmin.register_screen(LogDetailScreen)
      RecordingStudioAdmin.register_screen(SummariesScreen)
      RecordingStudioAdmin.register_screen(SummaryDetailScreen)
    end

    def register_widgets
      RecordingStudioAdmin.register_widget(NeedsAttentionWidget)
      RecordingStudioAdmin.register_widget(StuckSummariesWidget)
    end
  end
end
