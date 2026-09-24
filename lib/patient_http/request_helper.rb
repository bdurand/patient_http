# frozen_string_literal: true

module PatientHttp
  # Adds methods that make async HTTP requests to a class.
  #
  # Include this module to get the `async_get`, `async_head`, `async_post`,
  # `async_put`, `async_patch`, `async_delete`, `async_query`, and
  # `async_request` methods. The methods are available as instance methods and
  # as class methods. They send each request to the registered request handler,
  # so your code doesn't depend on the job system.
  #
  # To use the module:
  #
  # 1. Load a job system integration gem, or register a request handler with
  #    {PatientHttp.register_handler}.
  # 2. Include this module in a class.
  # 3. Optional: Set shared request options with `request_template`.
  # 4. Call the `async_*` methods.
  #
  # @example Include the module and make requests
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
      # Adds the class methods to a class that includes this module.
      #
      # @param base [Class] The class that includes this module.
      # @return [void]
      def included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@patient_http_request_template, nil)
      end
    end

    # The `async_*` methods for each HTTP method. They're available as instance
    # methods and as class methods.
    module HttpMethodHelpers
      # Makes an async GET request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_get(uri, callback:, **kwargs)
        async_request(:get, uri, callback: callback, **kwargs)
      end

      # Makes an async HEAD request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_head(uri, callback:, **kwargs)
        async_request(:head, uri, callback: callback, **kwargs)
      end

      # Makes an async POST request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_post(uri, callback:, **kwargs)
        async_request(:post, uri, callback: callback, **kwargs)
      end

      # Makes an async PUT request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_put(uri, callback:, **kwargs)
        async_request(:put, uri, callback: callback, **kwargs)
      end

      # Makes an async PATCH request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_patch(uri, callback:, **kwargs)
        async_request(:patch, uri, callback: callback, **kwargs)
      end

      # Makes an async DELETE request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_delete(uri, callback:, **kwargs)
        async_request(:delete, uri, callback: callback, **kwargs)
      end

      # Makes an async QUERY request.
      #
      # @param uri [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param kwargs [Hash] The request options. See `async_request`.
      # @return [Object] The value that the request handler returns.
      def async_query(uri, callback:, **kwargs)
        async_request(:query, uri, callback: callback, **kwargs)
      end
    end

    # The class methods that this module adds to a class.
    module ClassMethods
      include HttpMethodHelpers

      # Sets the default request options for this class and its subclasses.
      #
      # The `async_*` methods build each request from this template. Options
      # passed to a method override the template.
      #
      # @param base_url [String, nil] The base URL that relative paths are joined
      #   with.
      # @param headers [Hash] The default request headers.
      # @param params [Hash, nil] The default query parameters.
      # @param timeout [Numeric, nil] The default request timeout in seconds. If
      #   `nil`, the configured `request_timeout` applies.
      # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names
      #   of the default preprocessors.
      # @param processor [String, Symbol, nil] The name of the default processor.
      # @return [void]
      def request_template(base_url: nil, headers: {}, params: nil, timeout: nil, preprocessors: nil, processor: nil)
        @patient_http_request_template = RequestTemplate.new(
          base_url: base_url,
          headers: headers,
          params: params,
          timeout: timeout,
          preprocessors: preprocessors,
          processor: processor
        )
      end

      # Makes an async HTTP request.
      #
      # If the class has a request template, the template builds the request.
      #
      # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
      #   `:patch`, `:delete`, or `:query`.
      # @param url [String] The absolute URL, or a path relative to the base URL of
      #   the request template.
      # @param callback [Class, String] The callback service class, or its name.
      # @param headers [Hash, nil] The request headers.
      # @param body [String, nil] The request body.
      # @param json [Hash, Array, nil] An object to send as a JSON body. Can't be
      #   combined with `body`.
      # @param params [Hash, nil] The query parameters to add to the URL.
      # @param timeout [Numeric, nil] The request timeout in seconds.
      # @param raise_error_responses [Boolean, nil] If `true`, non-2xx responses go
      #   to the `on_error` callback as an {HttpError}.
      # @param callback_args [Hash, nil] The JSON-compatible arguments to pass to the
      #   callback.
      # @param max_redirects [Integer, nil] The maximum number of redirects to
      #   follow. If `0`, redirects aren't followed. If `nil`, the configuration
      #   value applies.
      # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
      #   redirect that changes the HTTP method. If `nil`, the configuration value
      #   applies.
      # @param redirect_strip_headers [String, Array<String>, nil] The names of headers
      #   to remove from redirected requests, in addition to the configured names.
      #   Names are case insensitive.
      # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
      #   the registered preprocessors that run on the request before it's sent.
      # @param processor [String, Symbol, nil] The name of the processor that runs
      #   the request.
      # @return [Object] The value that the request handler returns.
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
        max_redirects: nil,
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
          max_redirects: max_redirects,
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

      # Returns the request template for this class. A subclass without its own
      # template uses the template of its superclass.
      #
      # @return [RequestTemplate, nil] The request template, or `nil` if none is
      #   set.
      # @api private
      def async_request_template
        return @patient_http_request_template if @patient_http_request_template
        return superclass.async_request_template if superclass.include?(PatientHttp::RequestHelper)

        nil
      end
    end

    # Makes an async HTTP request. This method calls
    # {ClassMethods#async_request} on the class.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
    #   `:patch`, `:delete`, or `:query`.
    # @param url [String] The absolute URL, or a path relative to the base URL of
    #   the request template.
    # @param callback [Class, String] The callback service class, or its name.
    # @param headers [Hash, nil] The request headers.
    # @param body [String, nil] The request body.
    # @param json [Hash, Array, nil] An object to send as a JSON body. Can't be
    #   combined with `body`.
    # @param params [Hash, nil] The query parameters to add to the URL.
    # @param timeout [Numeric, nil] The request timeout in seconds.
    # @param raise_error_responses [Boolean, nil] If `true`, non-2xx responses go
    #   to the `on_error` callback as an {HttpError}.
    # @param callback_args [Hash, nil] The JSON-compatible arguments to pass to the
    #   callback.
    # @param max_redirects [Integer, nil] The maximum number of redirects to
    #   follow. If `0`, redirects aren't followed. If `nil`, the configuration
    #   value applies.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
    #   redirect that changes the HTTP method. If `nil`, the configuration value
    #   applies.
    # @param redirect_strip_headers [String, Array<String>, nil] The names of headers
    #   to remove from redirected requests, in addition to the configured names.
    #   Names are case insensitive.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   the registered preprocessors that run on the request before it's sent.
    # @param processor [String, Symbol, nil] The name of the processor that runs
    #   the request.
    # @return [Object] The value that the request handler returns.
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
      max_redirects: nil,
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
        max_redirects: max_redirects,
        follow_method_changing_redirects: follow_method_changing_redirects,
        redirect_strip_headers: redirect_strip_headers,
        preprocessors: preprocessors,
        processor: processor
      )
    end

    include HttpMethodHelpers
  end
end
