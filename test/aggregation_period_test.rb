# frozen_string_literal: true

require "test_helper"

class AggregationPeriodTest < Minitest::Test
  def test_hour_buckets_align_to_utc_midnight
    period = RecordingStudioLogs::Aggregation::Period.new(:hour, 3)

    assert_equal Time.utc(2026, 10, 14, 0), period.start_for(Time.utc(2026, 10, 14, 0))
    assert_equal Time.utc(2026, 10, 14, 0), period.start_for(Time.utc(2026, 10, 14, 2, 59, 59))
    assert_equal Time.utc(2026, 10, 14, 3), period.start_for(Time.utc(2026, 10, 14, 3))
    assert_equal Time.utc(2026, 10, 14, 21), period.start_for(Time.utc(2026, 10, 14, 23, 30))
    assert_equal Time.utc(2026, 10, 15, 0), period.finish(Time.utc(2026, 10, 14, 21))
  end

  def test_day_every_two_counts_from_unix_epoch
    period = RecordingStudioLogs::Aggregation::Period.new(:day, 2)
    epoch = Date.new(1970, 1, 1)
    fourteenth = Date.new(2026, 10, 14)
    offset = (fourteenth - epoch).to_i
    expected = fourteenth - (offset % 2)

    assert_equal Time.utc(expected.year, expected.month, expected.day),
                 period.start_for(Time.utc(2026, 10, 14, 18))
    assert_equal period.start_for(Time.utc(2026, 10, 14, 1)),
                 period.start_for(Time.utc(2026, 10, 14, 23))
  end

  def test_weeks_start_on_monday_from_a_fixed_anchor
    period = RecordingStudioLogs::Aggregation::Period.new(:week, 1)

    assert_equal Time.utc(2026, 10, 12), period.start_for(Time.utc(2026, 10, 14, 12))
    assert_equal Time.utc(2026, 10, 12), period.start_for(Time.utc(2026, 10, 12, 0))
    assert_equal Time.utc(2026, 10, 12), period.start_for(Time.utc(2026, 10, 18, 23))
    assert_equal Time.utc(2026, 10, 19), period.start_for(Time.utc(2026, 10, 19, 0))
    assert_equal Time.utc(2026, 10, 19), period.finish(Time.utc(2026, 10, 12))
  end

  def test_every_two_weeks_aligns_to_the_epoch_monday
    period = RecordingStudioLogs::Aggregation::Period.new(:week, 2)
    epoch = Date.new(1970, 1, 5)
    monday = Date.new(2026, 10, 12)
    weeks = (monday - epoch).to_i / 7
    aligned = epoch + (((weeks / 2) * 2) * 7)

    assert_equal Time.utc(aligned.year, aligned.month, aligned.day),
                 period.start_for(Time.utc(2026, 10, 14, 12))
  end

  def test_months_align_to_january_so_every_three_is_a_quarter
    period = RecordingStudioLogs::Aggregation::Period.new(:month, 3)

    assert_equal Time.utc(2026, 1, 1), period.start_for(Time.utc(2026, 2, 14))
    assert_equal Time.utc(2026, 4, 1), period.start_for(Time.utc(2026, 4, 1))
    assert_equal Time.utc(2026, 4, 1), period.start_for(Time.utc(2026, 6, 30, 12))
    assert_equal Time.utc(2026, 7, 1), period.start_for(Time.utc(2026, 8, 1))
    assert_equal Time.utc(2026, 10, 1), period.start_for(Time.utc(2026, 11, 20))
    assert_equal Time.utc(2027, 1, 1), period.finish(Time.utc(2026, 10, 1))
  end

  def test_one_month_is_the_first_of_that_month
    period = RecordingStudioLogs::Aggregation::Period.new(:month, 1)

    assert_equal Time.utc(2026, 10, 1), period.start_for(Time.utc(2026, 10, 21, 9))
  end

  def test_starts_overlapping_includes_a_week_that_began_before_the_range
    period = RecordingStudioLogs::Aggregation::Period.new(:week, 1)
    starts = period.starts_overlapping(Time.utc(2026, 10, 14), Time.utc(2026, 10, 16))

    assert_equal [Time.utc(2026, 10, 12)], starts
  end

  def test_hour_every_five_is_invalid
    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs::Aggregation::Period.new(:hour, 5)
    end
    assert_includes error.message, "divide 24"
  end

  def test_every_must_be_positive
    assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs::Aggregation::Period.new(:day, 0)
    end
  end
end
