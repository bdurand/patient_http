# frozen_string_literal: true

# Require this file to add the Rails integration:
#
#   require "patient_http/rails/engine"
#
# Then install the migrations:
#
#   bin/rails patient_http:install:migrations

require "rails/engine"

module PatientHttp
  # The Rails integration.
  module Rails
    # A Rails engine that makes the gem's migrations available to the
    # application. It isn't loaded by default.
    #
    # @example Install the migrations
    #   bin/rails patient_http:install:migrations
    #   bin/rails db:migrate
    class Engine < ::Rails::Engine
      engine_name "patient_http"
    end
  end
end
