# frozen_string_literal: true

# To enable Rails integration, require this file:
#
#   require "patient_http/rails/engine"
#
# You can then install the migrations with the following command:
#
#   rails patient_http:install:migrations

require "rails/engine"

module PatientHttp
  # Rails integration.
  module Rails
    # A Rails engine that provides the payload store migrations.
    #
    # When the engine loads, Rails finds the migrations in `db/migrate`. To copy
    # them into your application, run `rails patient_http:install:migrations`.
    class Engine < ::Rails::Engine
      engine_name "patient_http"
    end
  end
end
