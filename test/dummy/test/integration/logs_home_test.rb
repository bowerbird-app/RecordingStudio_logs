# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class LogsHomeTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "home page lists dummy logs and summaries" do
    user = User.find_or_create_by!(email: "logs-home@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end
    sign_in user

    get root_path

    assert_response :success
    assert_select "h1", text: "What's counting"
    assert_includes response.body, "SiteView"
    assert_includes response.body, "SampleDownload"
    assert_includes response.body, "presskits/press_kit_views"
    assert_includes response.body, "downloadable/download_counts"
    refute_includes response.body, "Template Demo"
  end
end
