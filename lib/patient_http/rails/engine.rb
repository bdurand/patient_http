# frozen_string_literal: true

# Require this file explicitly to enable the Rails integration:
#
#   require "patient_http/rails/engine"
#
# You can then install the migrations with:
#
#   rails patient_http:install:migrations

require "rails/engine"

module PatientHttp
  # Namespace for the Rails integration.
  module Rails
    # Rails engine that makes the migrations of the gem available to a Rails
    # application.
    class Engine < ::Rails::Engine
      engine_name "patient_http"

      # The engine picks the migrations up from db/migrate when it is loaded. Copy
      # them with:
      #
      #   rails patient_http:install:migrations
    end
  end
end
