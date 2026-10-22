# frozen_string_literal: true

require "uri"

module LogsPostgresConnection
  def connect!(pool: nil)
    ActiveRecord::Base.establish_connection(maintenance_config)
    name = database_name
    exists = ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_database WHERE datname = #{quote_name(name)}")
    ActiveRecord::Base.connection.create_database(name) unless exists
    config = pool ? test_config.merge(pool: pool) : test_config
    ActiveRecord::Base.establish_connection(config)
    ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
  end

  def quote_name(name)
    ActiveRecord::Base.connection.quote(name)
  end

  def database_name
    "recording_studio_logs_gem_test"
  end

  def maintenance_config
    test_config.merge(database: "postgres", pool: 1)
  end

  def test_config
    if ENV["DATABASE_URL"]
      uri = URI.parse(ENV["DATABASE_URL"])
      return {
        adapter: "postgresql", host: uri.host, port: uri.port || 5432,
        username: uri.user, password: uri.password, database: database_name
      }
    end

    { adapter: "postgresql", host: ENV.fetch("DB_HOST", "localhost"), port: ENV.fetch("DB_PORT", 5432).to_i,
      username: ENV.fetch("DB_USER", "postgres"), password: ENV.fetch("DB_PASSWORD", "postgres"),
      database: database_name }
  end
end
