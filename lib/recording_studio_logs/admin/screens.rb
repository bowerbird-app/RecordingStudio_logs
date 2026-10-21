# frozen_string_literal: true

module RecordingStudioLogs
  module Admin
    STATUS_BADGE = lambda { |_row, _context, value|
      Status.badge_options(value)
    }

    NeedsAttentionWidget = RecordingStudioAdmin::Widget.new("widgets.logs.needs_attention") do
      type :number
      title "Needs a look"
      info "A log is missing this month, or cleanup is waiting on a summary."
      value { Catalog.attention_count }
      link_to { |context| Status.needs_attention_path(context, "log_health") }
    end

    StuckSummariesWidget = RecordingStudioAdmin::Widget.new("widgets.logs.stuck_summaries") do
      type :number
      title "Summaries stuck"
      info "A summary failed or its table is not ready."
      value { Catalog.stuck_count }
      link_to { |context| Status.needs_attention_path(context, "summaries") }
    end

    class LogsSection < RecordingStudioAdmin::Section
      key "logs"
      title "Logs"
      subtitle "Month tables and summaries"

      link :health, text: "Log health", url: ->(context) { context.admin_screen_path("log_health") }
      link :summaries, text: "Summaries", url: ->(context) { context.admin_screen_path("summaries") }
      link :log_detail, text: "One log", url: ->(context) { context.admin_screen_path("log_detail") }
      link :summary_detail, text: "One summary", url: ->(context) { context.admin_screen_path("summary_detail") }
      widget "widgets.logs.needs_attention"
      widget "widgets.logs.stuck_summaries"
    end

    class LogHealthScreen < RecordingStudioAdmin::Screen
      key "log_health"
      title "Log health"
      subtitle "What is registered, and what needs a person"
      query { Catalog.logs }
      filter :status, options: Status::LOG_FILTERS, apply: ->(rows, value, _context) { Status.matching(rows, value) }

      table do
        column :name, sortable: false
        column :owner, title: "From", sortable: false
        column :table_name, title: "Table", sortable: false
        column :rows, title: "Approx. rows", sortable: false
        column :storage, sortable: false
        column :status, sortable: false, display: :badge, display_options: STATUS_BADGE
        column :retention, title: "Keeps", sortable: false
        column :partitioning, title: "Months", sortable: false
        column :aggregations, title: "Summaries", sortable: false
        action :open, text: "Open", url: lambda { |row, context|
          "#{context.admin_screen_path('log_detail')}?log=#{row.key}"
        }
      end
    end

    class LogDetailScreen < RecordingStudioAdmin::Screen
      key "log_detail"
      title "One log"
      subtitle "What this log is wired to"
      query { |context| Catalog.configuration_for(context.params[:log] || context.params["log"]) }

      table do
        column :setting, sortable: false
        column :value, sortable: false
      end
    end

    class SummariesScreen < RecordingStudioAdmin::Screen
      key "summaries"
      title "Summaries"
      subtitle "Each one reads the same raw log without copying it"
      query { Catalog.aggregations }
      filter :status, options: Status::SUMMARY_FILTERS, apply: lambda { |rows, value, _context|
        Status.matching(rows, value)
      }

      table do
        column :name, sortable: false
        column :source, sortable: false
        column :owner, title: "From", sortable: false
        column :grouping, sortable: false
        column :measurements, sortable: false
        column :last_success, title: "Last good run", sortable: false
        column :status, sortable: false, display: :badge, display_options: STATUS_BADGE
        action :open, text: "Open", url: lambda { |row, context|
          "#{context.admin_screen_path('summary_detail')}?aggregation=#{row.key}"
        }
      end
    end

    class SummaryDetailScreen < RecordingStudioAdmin::Screen
      key "summary_detail"
      title "One summary"
      subtitle "Recent runs, including failures"
      query { |context| Catalog.runs_for(context.params[:aggregation] || context.params["aggregation"]) }

      table do
        column :period_start, title: "Period", sortable: false
        column :status, sortable: false, display: :badge, display_options: STATUS_BADGE
        column :finished_at, title: "Finished", sortable: false
        column :error_message, title: "Error", sortable: false
      end
    end
  end
end
