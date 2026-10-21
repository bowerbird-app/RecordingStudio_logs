# frozen_string_literal: true

require "test_helper"

class DocsCoverageTest < Minitest::Test
  def test_semantics_covers_the_audit_topics
    text = File.read(File.expand_path("../docs/semantics.md", __dir__))

    %w[Cardinality Duplicates Unique views Late events UTC Mixed retention].each do |heading|
      assert_includes text, heading
    end
    assert_includes text, "delete_for_root"
    assert_includes text, "Cancelling a subscription does not delete logs"
    assert_includes text, "session"
    assert_includes text, "period"
  end

  def test_metrics_docs_do_not_extend_metrics
    readme = File.read(File.expand_path("../README.md", __dir__))
    adoption = File.read(File.expand_path("../docs/adoption.md", __dir__))

    assert_includes readme, "Only count and sum are published"
    assert_includes readme, "Do not extend Metrics from this gem"
    assert_includes readme, "Metrics registered by other gems keep the `group_by` dimensions they declared"
    assert_includes adoption, "Only `count` and `sum` become timeseries"
  end

  def test_adoption_is_an_ordered_guide
    text = File.read(File.expand_path("../docs/adoption.md", __dir__))

    assert_includes text, "Do this in Downloadable, in order"
    assert_includes text, "Do this in Embeddable, in order"
    assert_includes text, "Do this in the API gem, in order"
    assert_includes text, "Do this in MCP, in order"
    assert_includes text, "Do not adopt Logs for webhook deliveries"
    refute_includes text, "is not ready to partition in place.\n\n- The primary key"
  end

  def test_guides_exist
    root = File.expand_path("../docs", __dir__)
    %w[
      semantics.md
      cutover.md
      adoption.md
      guides/producing-gem.md
      guides/cross-gem-aggregation.md
      guides/scheduling.md
      guides/admin-screens.md
      guides/site-views-press-kits.md
    ].each do |path|
      assert File.file?(File.join(root, path)), path
    end
    assert_includes File.read(File.join(root, "guides/admin-screens.md")), "this dummy stays on"
    assert_includes File.read(File.join(root, "cutover.md")), "ACCESS EXCLUSIVE"
  end
end
