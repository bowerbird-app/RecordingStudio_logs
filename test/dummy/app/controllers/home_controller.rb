class HomeController < ApplicationController
  def index
    @logs = RecordingStudioLogs.logs
    @aggregations = RecordingStudioLogs.aggregations
  end
end
