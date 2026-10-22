# frozen_string_literal: true

require "rails/generators"

module RecordingStudioLogs
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Installs RecordingStudioLogs engine into your application"

      class_option(
        :mount_path,
        type: :string,
        default: "/recording_studio_logs",
        desc: "Route prefix used when mounting the engine"
      )

      def mount_engine
        route %(mount RecordingStudioLogs::Engine, at: "#{options[:mount_path]}")
      end

      def copy_initializer
        template "recording_studio_logs_initializer.rb", "config/initializers/recording_studio_logs.rb"
      end

      def add_yaml_config
        unless yes?("Would you like to add `config/recording_studio_logs.yml` for environment-specific settings? [y/N]")
          return
        end

        template "recording_studio_logs.yml", "config/recording_studio_logs.yml"
      end

      def show_readme
        readme "INSTALL.md" if behavior == :invoke
      end
    end
  end
end
