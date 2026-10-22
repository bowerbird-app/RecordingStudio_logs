# frozen_string_literal: true

module RecordingStudioLogs
  class Engine < ::Rails::Engine
    isolate_namespace RecordingStudioLogs

    initializer "recording_studio_logs.before_initialize", before: "recording_studio_logs.load_config" do |_app|
      RecordingStudioLogs.configuration.hooks.run(:before_initialize, self)
    end

    initializer "recording_studio_logs.load_config" do |app|
      if app.respond_to?(:config_for)
        path = yaml_config_path(app)
        unless path.nil? || !File.exist?(path)
          yaml = app.config_for(:recording_studio_logs)
          RecordingStudioLogs.configuration.merge!(yaml) if yaml.respond_to?(:each)
        end
      end
      Engine.load_x_config(app)
      RecordingStudioLogs.configuration.hooks.run(:on_configuration, RecordingStudioLogs.configuration)
    end

    initializer "recording_studio_logs.after_initialize", after: "recording_studio_logs.load_config" do |_app|
      RecordingStudioLogs.configuration.hooks.run(:after_initialize, self)
    end

    initializer "recording_studio_logs.prepare" do
      config.after_initialize { RecordingStudioLogs.finalize! }

      config.to_prepare do
        RecordingStudioLogs::Admin.register!
        RecordingStudioLogs.finalize!
      end
    end

    class << self
      def load_x_config(app)
        return unless app.config.respond_to?(:x) && app.config.x.respond_to?(:recording_studio_logs)

        merge_x_config(app.config.x.recording_studio_logs)
      end

      def merge_x_config(xcfg)
        return RecordingStudioLogs.configuration.merge!(xcfg.to_h) if xcfg.respond_to?(:to_h)
        return unless xcfg.respond_to?(:each_pair)

        hash = {}
        xcfg.each_pair { |key, value| hash[key] = value }
        RecordingStudioLogs.configuration.merge!(hash) if hash.any?
      end

      def yaml_config_path(app)
        if app.respond_to?(:paths) && (config_paths = app.paths["config"])
          first = Array(config_paths.respond_to?(:existent) ? config_paths.existent : config_paths).first
          File.join(first, "recording_studio_logs.yml") if first
        elsif app.respond_to?(:root) && app.root
          File.join(app.root, "config", "recording_studio_logs.yml")
        end
      end
    end
  end
end
