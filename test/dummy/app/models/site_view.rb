# frozen_string_literal: true

class SiteView < ApplicationRecord
  self.primary_key = %i[id occurred_at]
  include RecordingStudioLogs::EnsuresPartition
end
