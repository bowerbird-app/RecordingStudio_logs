# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["SIMPLECOV_COMMAND_NAME"] ||= "dummy"

require_relative "../../simplecov_helper"
require_relative "../config/environment"
require "rails/test_help"
