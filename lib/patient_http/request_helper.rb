# frozen_string_literal: true

module PatientHttp
  # Mixin that gives you a compact API for scheduling async HTTP requests.
  #
  # Include this module in your class to get instance-level and class-level helpers
  # that build requests and dispatch them through a registered handler.
  #
  # This module lets you keep one interface for making HTTP requests while you change
  # the queueing mechanism that handles the responses asynchronously. When you
  # register a custom handler, you can integrate with any job queue system, such as
  # Sidekiq or Solid Queue, without changing the application code that makes the HTTP
  # requests. Your request interface stays separate from your async processing
  # infrastructure.
  #
  # The usual workflow is:
  #
  # 1. Register a global request handler with {PatientHttp.register_handler}.
  # 2. Include this module in a class.
  # 3. Configure the defaults with {ClassMethods#request_template}, which is optional.
  # 4. Call `async_get`, `async_head`, `async_post`, `async_put`, `async_patch`,
  #    `async_delete`, `async_query`, or `async_request`.
  #
  # @example Register a handler
  #   PatientHttp.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
  #     # Dispatch the request through your app-specific task/enqueue operation
  #     # and return the request id
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
      # Adds the helper behavior to the class that includes this module.
      #
      # This method extends the class with {ClassMethods} and initializes the storage
      # for the request template.
      #
      # @param base [Class] The class that includes this module.
      # @return [void]
      def included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@patient_http_request_template, nil)
      end
    end

    # Helpers that build and dispatch a request for each HTTP method. The module is
    # available both on the class and on its instances.
    module HttpMethodHelpers
      # Enqueues an asynchronous HTTP GET request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_get(uri, callback:, **kwargs)
        async_request(:get, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP HEAD request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_head(uri, callback:, **kwargs)
        async_request(:head, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP POST request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_post(uri, callback:, **kwargs)
        async_request(:post, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP PUT request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_put(uri, callback:, **kwargs)
        async_request(:put, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP PATCH request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_patch(uri, callback:, **kwargs)
        async_request(:patch, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP DELETE request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_delete(uri, callback:, **kwargs)
        async_request(:delete, uri, callback: callback, **kwargs)
      end

      # Enqueues an asynchronous HTTP QUERY request.
      #
      # @param uri [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param kwargs [Hash] Additional options forwarded to `async_request`.
      # @return [Object] The return value from the registered request handler.
      def async_query(uri, callback:, **kwargs)
        async_request(:query, uri, callback: callback, **kwargs)
      end
    end

    # Class-level helpers that a class receives when it includes {RequestHelper}.
    module ClassMethods
      include HttpMethodHelpers

      # Defines a default request template for this class.
      #
      # A request that you create with a helper method merges these defaults, unless
      # the request overrides them.
      #
      # @param base_url [String, nil] An optional base URL that resolves relative
      #   request URLs.
      # @param headers [Hash] The default headers for the requests.
      # @param params [Hash, nil] The default query parameters for the requests.
      # @param timeout [Float] The default timeout, in seconds.
      # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The default
      #   names of the preprocessors that are registered on the configuration and that
      #   apply to the requests.
      # @param processor [String, Symbol, nil] The default processor name for the
      #   requests.
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
      # When a request template is configured, the request is built from the template.
      # Otherwise, it is built from the given arguments.
      #
      # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
      #   `:patch`, `:delete`, or `:query`.
      # @param url [String] The absolute URL, or the path when you use a request
      #   template.
      # @param callback [Class, String] The callback class that handles the response.
      # @param headers [Hash, nil] The request headers.
      # @param body [String, nil] The raw request body.
      # @param json [Hash, Array, nil] A JSON payload that the request layer encodes.
      # @param params [Hash, nil] The query parameters.
      # @param timeout [Numeric, nil] The timeout in seconds for this request.
      # @param raise_error_responses [Boolean, nil] Whether to report non-success
      #   responses as errors.
      # @param callback_args [Hash, nil] JSON-compatible callback arguments.
      # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
      #   redirect that changes the HTTP method. Use nil for the configured default.
      # @param redirect_strip_headers [String, Array<String>, nil] Header names (case
      #   insensitive) to strip from redirected requests, in addition to the
      #   configured names.
      # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
      #   the preprocessors that are registered on the configuration and that apply to
      #   the request when it is sent.
      # @param processor [String, Symbol, nil] The name of the processor that runs the
      #   request.
      # @return [Object] The return value from the registered request handler.
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

      # Returns the {RequestTemplate} that is defined for this class or for one of its
      # ancestors, or nil if no template is defined. A subclass that defines no
      # template of its own therefore inherits the template of its parent class.
      #
      # @return [RequestTemplate, nil] The request template for this class or for one
      #   of its ancestors.
      # @api private
      def async_request_template
        return @patient_http_request_template if @patient_http_request_template
        return superclass.async_request_template if superclass.include?(PatientHttp::RequestHelper)

        nil
      end
    end

    # Dispatches an asynchronous HTTP request from an instance.
    #
    # This method delegates to {ClassMethods#async_request} on the class that includes
    # this module.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
    #   `:patch`, `:delete`, or `:query`.
    # @param url [String] The absolute URL, or the path when you use a request
    #   template.
    # @param callback [Class, String] The callback class that handles the response.
    # @param headers [Hash, nil] The request headers.
    # @param body [String, nil] The raw request body.
    # @param json [Hash, Array, nil] A JSON payload that the request layer encodes.
    # @param params [Hash, nil] The query parameters.
    # @param timeout [Numeric, nil] The timeout in seconds for this request.
    # @param raise_error_responses [Boolean, nil] Whether to report non-success
    #   responses as errors.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
    #   redirect that changes the HTTP method. Use nil for the configured default.
    # @param redirect_strip_headers [String, Array<String>, nil] Header names (case
    #   insensitive) to strip from redirected requests, in addition to the configured
    #   names.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   the preprocessors that are registered on the configuration and that apply to
    #   the request when it is sent.
    # @param processor [String, Symbol, nil] The name of the processor that runs the
    #   request.
    # @return [Object] The return value from the registered request handler.
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
