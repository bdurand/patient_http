# frozen_string_literal: true

module PatientHttp
  # Shared redirect logic that both the async {Processor} and the
  # {SynchronousExecutor} use. A class that includes this module must expose the
  # active {Configuration} as `@config`.
  #
  # @api private
  module RedirectHelper
    class << self
      # Returns the HTTP method to use when the processor follows a redirect.
      #
      # The rules follow RFC 9110 and the WHATWG Fetch standard:
      #
      # - 301 and 302 change POST to GET and keep every other method. The QUERY
      #   specification states that this POST exception does not apply to QUERY, so a
      #   QUERY is sent again as a QUERY.
      # - 303 keeps GET and HEAD, and changes every other method to GET.
      # - 300, 307, and 308 keep the method.
      #
      # @param http_method [Symbol] The current request method.
      # @param status [Integer] The redirect status code.
      # @return [Symbol] The method for the redirected request.
      def redirect_method(http_method, status)
        case status
        when 301, 302
          (http_method == :post) ? :get : http_method
        when 303
          %i[get head].include?(http_method) ? http_method : :get
        else
          http_method
        end
      end

      # Checks whether following a redirect requires a change of the request method.
      #
      # @param http_method [Symbol] The current request method.
      # @param status [Integer] The redirect status code.
      # @return [Boolean] Whether the method must change to follow the redirect.
      def method_change_required?(http_method, status)
        redirect_method(http_method, status) != http_method
      end

      # Normalizes the header names that are used to strip headers from redirected
      # requests. The names are converted to lowercase so that they match header names
      # case insensitively.
      #
      # @param names [String, Symbol, Array<String, Symbol>, nil] The header names.
      # @return [Array<String>] The frozen lowercase header names.
      # @raise [ArgumentError] If a name is empty, or is neither a string nor a
      #   symbol.
      def normalize_header_names(names)
        Array(names).map do |name|
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise ArgumentError.new("header names must be strings, got: #{name.inspect}")
          end

          name = name.to_s.downcase
          raise ArgumentError.new("header names cannot be empty") if name.empty?
          name.freeze
        end.freeze
      end
    end

    private

    # Checks whether the processor follows a redirect response.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data, with the status, headers, and
    #   body.
    # @return [Boolean] Whether the redirect is followed.
    def should_follow_redirect?(task, response_data)
      status = response_data[:status]
      return false unless FOLLOWABLE_REDIRECT_STATUSES.include?(status)
      return false if task.max_redirects == 0

      location = response_data[:headers]["location"]
      return false if location.nil? || location.empty?

      if RedirectHelper.method_change_required?(task.request.http_method, status)
        return false unless follow_method_changing_redirect?(task)
      end

      true
    end

    # Checks whether the request can change its method to follow a redirect. The
    # request setting takes precedence over the configuration.
    #
    # @param task [RequestTask] The request task.
    # @return [Boolean] Whether the method can change.
    def follow_method_changing_redirect?(task)
      value = task.request.follow_method_changing_redirects
      value = @config.follow_method_changing_redirects if value.nil?
      value
    end

    # Builds the task that follows a redirect, and applies the configured rules for
    # stripping headers.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data, with the status, headers, and
    #   body.
    # @return [RequestTask] The redirect task.
    def build_redirect_task(task, response_data)
      task.redirect_task(
        location: response_data[:headers]["location"],
        status: response_data[:status],
        strip_headers: @config.redirect_strip_headers
      )
    end

    # Checks for too many redirects and for a redirect loop.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data, with the status, headers, and
    #   body.
    # @return [RedirectError, nil] The error if the redirect must not proceed, or nil.
    def check_redirect_error(task, response_data)
      location = response_data[:headers]["location"]
      redirect_url = resolve_redirect_url(task.request.url, location)

      check_too_many_redirects(task, location) || check_recursive_redirect(task, redirect_url)
    end

    # Checks whether the number of redirects is larger than the maximum.
    #
    # @param task [RequestTask] The request task.
    # @param location [String] The redirect location URL.
    # @return [TooManyRedirectsError, nil] The error if the maximum is exceeded, or
    #   nil.
    def check_too_many_redirects(task, location)
      return nil if task.redirects.size < task.max_redirects

      TooManyRedirectsError.new(
        url: location,
        http_method: task.request.http_method,
        duration: task.duration,
        request_id: task.id,
        redirects: task.redirects + [task.request.url],
        callback_args: task.callback_args
      )
    end

    # Checks whether the redirect URL was already visited, which means that the
    # redirects form a loop.
    #
    # @param task [RequestTask] The request task.
    # @param redirect_url [String] The resolved redirect URL.
    # @return [RecursiveRedirectError, nil] The error if a loop is detected, or nil.
    def check_recursive_redirect(task, redirect_url)
      visited_urls = task.redirects + [task.request.url]
      return nil unless visited_urls.include?(redirect_url)

      RecursiveRedirectError.new(
        url: redirect_url,
        http_method: task.request.http_method,
        duration: task.duration,
        request_id: task.id,
        redirects: visited_urls,
        callback_args: task.callback_args
      )
    end

    # Resolves a redirect URL, including a relative URL.
    #
    # @param base_url [String] The base URL.
    # @param location [String] The Location header value.
    # @return [String] The resolved absolute URL.
    def resolve_redirect_url(base_url, location)
      base_uri = URI.parse(base_url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
