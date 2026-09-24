# frozen_string_literal: true

module PatientHttp
  # Shared redirect-checking logic used by both the async Processor
  # and the SynchronousExecutor. Including classes must expose the
  # active {Configuration} as `@config`.
  #
  # @api private
  module RedirectHelper
    class << self
      # Returns the HTTP method to use when following a redirect.
      #
      # The rules follow RFC 9110 and the WHATWG Fetch standard:
      #
      # - 301 and 302 change POST to GET; every other method is preserved.
      #   The QUERY specification states this POST exception does not apply
      #   to QUERY, so a QUERY is re-sent as a QUERY.
      # - 303 preserves GET and HEAD; every other method becomes GET.
      # - 300, 307, and 308 preserve the method.
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

      # Returns whether following a redirect requires changing the request method.
      #
      # @param http_method [Symbol] The current request method.
      # @param status [Integer] The redirect status code.
      # @return [Boolean] `true` if the method must change to follow the redirect.
      def method_change_required?(http_method, status)
        redirect_method(http_method, status) != http_method
      end

      # Normalizes header names used to strip headers from redirected requests.
      # Names are downcased so they match header names case insensitively.
      #
      # @param names [String, Symbol, Array<String, Symbol>, nil] Header names.
      # @return [Array<String>] Frozen lowercase header names.
      # @raise [ArgumentError] If a name is not a string or symbol, or is empty.
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

    # Returns whether a redirect response should be followed.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data with status, headers, body.
    # @return [Boolean] `true` if the redirect should be followed.
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

    # Returns whether the request may change its method to follow a redirect.
    # The request setting takes precedence over the configuration.
    #
    # @param task [RequestTask] The request task.
    # @return [Boolean]
    def follow_method_changing_redirect?(task)
      value = task.request.follow_method_changing_redirects
      value = @config.follow_method_changing_redirects if value.nil?
      value
    end

    # Builds the task for following a redirect, applying the configured
    # header stripping rules.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data with status, headers, body.
    # @return [RequestTask] The redirect task.
    def build_redirect_task(task, response_data)
      task.redirect_task(
        location: response_data[:headers]["location"],
        status: response_data[:status],
        strip_headers: @config.redirect_strip_headers
      )
    end

    # Returns an error if a redirect exceeds the limit or makes a loop.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data with status, headers, body.
    # @return [RedirectError, nil] Error if redirect should not proceed, nil otherwise.
    def check_redirect_error(task, response_data)
      location = response_data[:headers]["location"]
      redirect_url = resolve_redirect_url(task.request.url, location)

      check_too_many_redirects(task, location) || check_recursive_redirect(task, redirect_url)
    end

    # Returns whether the redirect count has exceeded the maximum.
    #
    # @param task [RequestTask] The request task.
    # @param location [String] The redirect location URL.
    # @return [TooManyRedirectsError, nil] Error if exceeded, nil otherwise.
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

    # Returns whether the redirect URL has already been visited (redirect loop).
    #
    # @param task [RequestTask] The request task.
    # @param redirect_url [String] The resolved redirect URL.
    # @return [RecursiveRedirectError, nil] Error if loop detected, nil otherwise.
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

    # Resolves a redirect URL, handling relative URLs.
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
