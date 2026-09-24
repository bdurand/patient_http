# frozen_string_literal: true

module PatientHttp
  # A mixin with a compact API for scheduling asynchronous HTTP requests.
  #
  # Include this module in your class to get instance and class helpers that build
  # requests and dispatch them through the registered handler.
  #
  # Your code makes HTTP requests through the same interface no matter which job
  # queue handles the responses. To integrate with a job queue system, such as
  # Sidekiq or Solid Queue, register a handler. You don't need to change the
  # application code that makes the requests.
  #
  # To use this module, follow these steps:
  #
  # 1. Register a global request handler with {PatientHttp.register_handler}.
  # 2. Include this module in a class.
  # 3. Optional: Configure defaults with {ClassMethods#request_template}.
  # 4. Call `async_get`, `async_head`, `async_post`, `async_put`, `async_patch`,
  #    `async_delete`, `async_query`, or `async_request`.
  #
  # @example Register a handler
  #   PatientHttp.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
  #     # Dispatch the request through your application's enqueue operation
  #     # and return the request ID.
  #   end
  #
  # @example Include in a class and enqueue requests
  #   class ApiClient
  #     include PatientHttp::RequestHelper
  #
  #     request_template base_url: "https://api.example.com", headers: {"Authorization" => "Bearer token"}
  #
  #     def fetch_user(user_id)
  #       async_get("/users/#{user_id}", callback: UserCallback, callback_args: {"user_id" => user_id})
  #     end
  #   end
  module RequestHelper
    extend self

    class << self
      # Adds the helper methods to the including class.
      #
      # This method extends the class with {ClassMethods} and sets up template storage.
      #
      # @param base [Class] The class that includes this module.
      # @return [void]
      def included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@patient_http_request_template, nil)
      end
    end

    # Helper methods for each HTTP method. They're available as both class and
    # instance methods.
    module HttpMethodHelpers
      # Enqueues an asynchronous HTTP GET request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_get(uri, callback:, **kwargs)
        async_request(:get, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP HEAD request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_head(uri, callback:, **kwargs)
        async_request(:head, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP POST request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_post(uri, callback:, **kwargs)
        async_request(:post, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP PUT request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_put(uri, callback:, **kwargs)
        async_request(:put, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP PATCH request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_patch(uri, callback:, **kwargs)
        async_request(:patch, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP DELETE request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_delete(uri, callback:, **kwargs)
        async_request(:delete, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP QUERY request.
      #
      # @param uri [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options to pass to {#async_request}.
      # @return [Object] The return value of the registered request handler.
      def async_query(uri, callback:, **kwargs)
        async_request(:query, uri, callback: callback, **kwargs)
      end
    end

    # Class methods added to classes that include {RequestHelper}.
    module ClassMethods
      include HttpMethodHelpers

      # Defines a default request template for this class.
      #
      # Requests created with the helper methods use these defaults unless you
      # override them.
      #
      # @param base_url [String, nil] An optional base URL for resolving relative request URLs.
      # @param headers [Hash] The default request headers.
      # @param params [Hash, nil] The default query parameters.
      # @param timeout [Float] The default timeout, in seconds.
      # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The default names of
      #   preprocessors, registered on the configuration, to apply to requests.
      # @param processor [String, Symbol, nil] The default processor name for requests.
      # @return [void]
      def request_template(base_url: nil, headers: {}, params: nil, timeout: 30, preprocessors: nil, processor: nil)
        @patient_http_request_template = RequestTemplate.new(
          base_url: base_url,
          headers: headers,
          params: params,
          timeout: timeout,
          preprocessors: preprocessors,
          processor: processor
        )
      end

      # Builds and dispatches an asynchronous HTTP request.
      #
      # If a request template is configured, the request is built from the template.
      # Otherwise, it's built from the arguments.
      #
      # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
      #   `:delete`, or `:query`.
      # @param url [String] An absolute URL, or a path if you use a request template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param headers [Hash, nil] The request headers.
      # @param body [String, nil] The raw request body.
      # @param json [Hash, Array, nil] A payload to encode as the JSON request body.
      # @param params [Hash, nil] The query parameters.
      # @param timeout [Numeric, nil] The timeout for this request, in seconds.
      # @param raise_error_responses [Boolean, nil] If `true`, non-success responses are
      #   reported as errors.
      # @param callback_args [Hash, nil] JSON-compatible callback arguments.
      # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a redirect that
      #   changes the HTTP method. `nil` uses the configuration default.
      # @param redirect_strip_headers [String, Array<String>, nil] Header names to strip from
      #   redirected requests, in addition to the configured names. Names are case insensitive.
      # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
      #   preprocessors, registered on the configuration, to apply when the request is sent.
      # @param processor [String, Symbol, nil] The name of the processor that executes the
      #   request.
      # @return [Object] The return value of the registered request handler.
      def async_request(
        method,
        url,
        callback:,
        headers: nil,
        body: nil,
        json: nil,
        params: nil,
        timeout: nil,
        raise_error_responses: nil,
        callback_args: nil,
        follow_method_changing_redirects: nil,
        redirect_strip_headers: nil,
        preprocessors: nil,
        processor: nil
      )
        template = async_request_template
        kwargs = {
          body: body,
          json: json,
          headers: headers,
          params: params,
          timeout: timeout,
          follow_method_changing_redirects: follow_method_changing_redirects,
          redirect_strip_headers: redirect_strip_headers,
          preprocessors: preprocessors,
          processor: processor
        }
        request = if template
          template.request(method, url, **kwargs)
        else
          Request.new(method, url, **kwargs)
        end

        PatientHttp.execute(
          request: request,
          callback: callback,
          callback_args: callback_args,
          raise_error_responses: raise_error_responses
        )
      end

      # Returns the {RequestTemplate} defined for this class or its ancestors, or `nil`
      # if none is defined. A subclass that doesn't define a template inherits the
      # template from its parent class.
      #
      # @return [RequestTemplate, nil] The request template for this class or its ancestors.
      # @api private
      def async_request_template
        return @patient_http_request_template if @patient_http_request_template
        return superclass.async_request_template if superclass.include?(PatientHttp::RequestHelper)

        nil
      end
    end

    # Dispatches an asynchronous HTTP request from an instance context.
    #
    # This method delegates to {ClassMethods#async_request} on the including class.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
    #   `:delete`, or `:query`.
    # @param url [String] An absolute URL, or a path if you use a request template.
    # @param callback [Class, String] The callback class that handles the response.
    # @param headers [Hash, nil] The request headers.
    # @param body [String, nil] The raw request body.
    # @param json [Hash, Array, nil] A payload to encode as the JSON request body.
    # @param params [Hash, nil] The query parameters.
    # @param timeout [Numeric, nil] The timeout for this request, in seconds.
    # @param raise_error_responses [Boolean, nil] If `true`, non-success responses are
    #   reported as errors.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a redirect that
    #   changes the HTTP method. `nil` uses the configuration default.
    # @param redirect_strip_headers [String, Array<String>, nil] Header names to strip from
    #   redirected requests, in addition to the configured names. Names are case insensitive.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   preprocessors, registered on the configuration, to apply when the request is sent.
    # @param processor [String, Symbol, nil] The name of the processor that executes the
    #   request.
    # @return [Object] The return value of the registered request handler.
    def async_request(
      method,
      url,
      callback:,
      headers: nil,
      body: nil,
      json: nil,
      params: nil,
      timeout: nil,
      raise_error_responses: nil,
      callback_args: nil,
      follow_method_changing_redirects: nil,
      redirect_strip_headers: nil,
      preprocessors: nil,
      processor: nil
    )
      self.class.async_request(
        method,
        url,
        callback: callback,
        headers: headers,
        body: body,
        json: json,
        params: params,
        timeout: timeout,
        raise_error_responses: raise_error_responses,
        callback_args: callback_args,
        follow_method_changing_redirects: follow_method_changing_redirects,
        redirect_strip_headers: redirect_strip_headers,
        preprocessors: preprocessors,
        processor: processor
      )
    end

    include HttpMethodHelpers
  end
end
