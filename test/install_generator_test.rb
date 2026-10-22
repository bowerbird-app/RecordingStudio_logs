# frozen_string_literal: true

require "test_helper"
require "generators/recording_studio_logs/install/install_generator"

class InstallGeneratorTest < Minitest::Test
  INSTALL_TEMPLATE_PATH = File.expand_path(
    "../lib/generators/recording_studio_logs/install/templates/INSTALL.md",
    __dir__
  )

  def build_generator(destination_root, options = {})
    RecordingStudioLogs::Generators::InstallGenerator.new(
      [],
      options,
      destination_root: destination_root
    )
  end

  def test_mount_engine_uses_configured_mount_path
    generator = build_generator("/tmp", mount_path: "/addons/recording")
    routes = []

    generator.stub(:route, ->(value) { routes << value }) do
      generator.mount_engine
    end

    assert_equal ["mount RecordingStudioLogs::Engine, at: \"/addons/recording\""], routes
  end

  def test_install_generator_does_not_inject_tailwind_sources
    path = File.expand_path("../lib/generators/recording_studio_logs/install/install_generator.rb", __dir__)
    source = File.read(path)

    refute_includes source, "add_tailwind_source"
    refute_includes source, "@source"
    refute RecordingStudioLogs::Generators::InstallGenerator.method_defined?(:add_tailwind_source, false)
  end

  def test_show_readme_displays_install_guide_for_invoke_behavior
    generator = build_generator("/tmp")
    shown_templates = []

    generator.stub(:behavior, :invoke) do
      generator.stub(:readme, ->(template) { shown_templates << template }) do
        generator.show_readme
      end
    end

    assert_equal ["INSTALL.md"], shown_templates
  end

  def test_install_guide_includes_migration_and_host_setup_steps
    install_guide = File.read(INSTALL_TEMPLATE_PATH)

    assert_includes install_guide, "bin/rails generate recording_studio_logs:migrations"
    assert_includes install_guide, "bin/rails db:migrate"
    assert_includes install_guide, "auth, layout, and current actor integration"
    assert_includes install_guide, "recording_studio_recordable"
    refute_includes install_guide, "tailwindcss:build"
    refute_includes install_guide, "RecordingStudio v3"
  end
end
