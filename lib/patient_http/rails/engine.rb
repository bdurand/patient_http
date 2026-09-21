# frozen_string_literal: true

# This file must be explicitly required to enable Rails integration.
# Usage: require "patient_http/rails/engine"
#
# This allows you to install migrations using:
#   rails patient_http:install:migrations

require "rails/engine"

module PatientHttp
  module Rails
    class Engine < ::Rails::Engine
      engine_name "patient_http"

      # Migrations are picked up automatically from db/migrate when the engine
      # is loaded. Copy them using:
      #   rails patient_http:install:migrations
    end
  end
end
