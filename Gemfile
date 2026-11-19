# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in recording_studio_logs.gemspec
gemspec

# recording_studio is not published to RubyGems; resolve the gemspec pin from GitHub.
gem "recording_studio", "~> 7.8", github: "bowerbird-app/RecordingStudio", tag: "v7.8.0"

gem "devise"
gem "puma"
gem "sprockets-rails"

group :development, :test do
  gem "debug"
  gem "flat_pack", "~> 0.2", github: "bowerbird-app/flatpack", tag: "v0.2.0", require: false
  gem "minitest-mock"
  gem "pg", "~> 1.1"
  gem "recording_studio_accessible", "~> 0.56",
      github: "bowerbird-app/RecordingStudio_accessible", tag: "v0.56.0", require: false
  gem "recording_studio_admin", "~> 2.19", github: "bowerbird-app/RecordingStudio_admin", tag: "v2.19.1", require: false
  gem "recording_studio_metrics", "~> 0.10",
      github: "bowerbird-app/RecordingStudio_metrics", tag: "v0.10.0", require: false
  gem "recording_studio_trashable", "~> 1.2",
      github: "bowerbird-app/RecordingStudio_trashable", tag: "v1.2.3", require: false
  gem "simplecov", require: false
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails", require: false
end
