# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in recording_studio_logs.gemspec
gemspec

# recording_studio is not published to RubyGems; resolve the gemspec pin from GitHub.
gem "recording_studio", github: "bowerbird-app/RecordingStudio", tag: "v7.4.0"

gem "devise"
gem "puma"
gem "sprockets-rails"

group :development, :test do
  gem "debug"
  gem "flat_pack", github: "bowerbird-app/flatpack", tag: "v0.1.377", require: false
  gem "minitest-mock"
  gem "pg", "~> 1.1"
  gem "recording_studio_accessible", github: "bowerbird-app/RecordingStudio_accessible", tag: "v0.46.0", require: false
  gem "recording_studio_admin", github: "bowerbird-app/RecordingStudio_admin", tag: "v2.18.0", require: false
  gem "recording_studio_metrics", github: "bowerbird-app/RecordingStudio_metrics", tag: "v0.9.1", require: false
  gem "recording_studio_trashable", github: "bowerbird-app/RecordingStudio_trashable", tag: "v1.0.1", require: false
  gem "simplecov", require: false
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails", require: false
end
