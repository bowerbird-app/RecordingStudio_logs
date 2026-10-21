# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    module DefinitionPeriod
      def interval
        calendar_day? ? :daily : period.kind
      end

      def every
        period.every
      end

      def day_for(time)
        period.start_for(time).to_date
      end

      def period_start_for(time)
        period.start_for(time)
      end

      def summary_period_key(period_start)
        period_options.summary_period_key(period_start, date_column: summary_period_is_date?)
      end

      def count_period(period_start)
        case count
        when :sync
          Runner.call(self, period_start: period_start)
        when :async
          AggregatePeriodJob.enqueue(name, period_start)
        end
      end

      def install_count_hook!
        return unless live_count?

        CountTrigger.install(source_model)
      end

      private

      def validate_period_column!
        period_options.validate_column!(self)
      end

      def summary_period_is_date?
        return period.kind != :hour unless summary_ready?

        summary_model.columns_hash[period_column.to_s]&.type == :date
      end
    end
  end
end
