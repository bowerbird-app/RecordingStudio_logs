# frozen_string_literal: true

require "test_helper"

class MetricsBridgeTest < Minitest::Test
  def setup
    @definition = FakeSummary.new
    @metrics = FakeMetrics.new
    Object.const_set(:RecordingStudioMetrics, @metrics)
  end

  def teardown
    Object.send(:remove_const, :RecordingStudioMetrics) if defined?(RecordingStudioMetrics)
  end

  def test_count_and_sum_become_timeseries_over_the_summary_column
    @definition.measurements = [
      RecordingStudioLogs::Measurement.new(:views, :count),
      RecordingStudioLogs::Measurement.new(:watch_time, :sum, :duration_ms)
    ]

    RecordingStudioLogs::MetricsBridge.register_one(@definition)

    resource = @metrics.resources.fetch(:presskits_press_kit_views)
    assert_equal :root_recording_id, resource[:scope_attribute]
    assert_equal(
      [
        [:views, { field: :day, measurement: :sum, value_field: :views, title: "Views" }],
        [:watch_time, { field: :day, measurement: :sum, value_field: :watch_time, title: "Watch time" }]
      ],
      resource[:series]
    )
  end

  def test_average_and_unrooted_summaries_stay_tables
    @definition.measurements = [RecordingStudioLogs::Measurement.new(:duration, :average, :duration_ms)]
    RecordingStudioLogs::MetricsBridge.register_one(@definition)
    assert_empty @metrics.resources

    @definition.measurements = [RecordingStudioLogs::Measurement.new(:views, :count)]
    @definition.group_by = [:recording_id]
    RecordingStudioLogs::MetricsBridge.register_one(@definition)
    assert_empty @metrics.resources
  end

  def test_a_second_registration_is_left_alone_when_classes_are_cached
    @definition.measurements = [RecordingStudioLogs::Measurement.new(:views, :count)]
    RecordingStudioLogs::MetricsBridge.register_one(@definition)
    RecordingStudioLogs::MetricsBridge.register_one(@definition)

    assert_equal 1, @metrics.resources.fetch(:presskits_press_kit_views)[:calls]
  end

  class FakeSummary
    attr_accessor :measurements, :group_by

    def initialize
      @measurements = []
      @group_by = [:root_recording_id]
    end

    def summary_ready? = true
    def name = "presskits/press_kit_views"
    def metrics_resource = :presskits_press_kit_views
    def summary_model = self.class.summary_model
    def log = Struct.new(:root_column).new(:root_recording_id)

    def self.summary_model
      @summary_model ||= Class.new
    end
  end

  class FakeMetrics
    attr_reader :resources

    def initialize
      @resources = {}
    end

    def register(resource, model:, scope_attribute:, &block)
      dsl = Object.new
      series = []
      dsl.define_singleton_method(:timeseries) { |name, **options| series << [name, options] }
      dsl.instance_eval(&block) if block
      @resources[resource] = { model: model, scope_attribute: scope_attribute, series: series, calls: 1 }
    end

    def for_resource(resource)
      entry = @resources[resource]
      return [] unless entry

      [resource]
    end
  end
end
