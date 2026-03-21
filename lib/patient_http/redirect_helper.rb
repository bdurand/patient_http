# frozen_string_literal: true

module PatientHttp
  # Shared redirect-checking logic used by both the async Processor
  # and the SynchronousExecutor.
  #
  # @api private
  module RedirectHelper
    private

    # Check if a redirect response should be followed.
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash] the response data with status, headers, body
    # @return [Boolean] true if the redirect should be followed
    def should_follow_redirect?(task, response_data)
      status = response_data[:status]
      return false unless FOLLOWABLE_REDIRECT_STATUSES.include?(status)
      return false if task.max_redirects == 0

      location = response_data[:headers]["location"]
      return false if location.nil? || location.empty?

      true
    end

    # Check for either too-many-redirects or recursive redirect.
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash] the response data with status, headers, body
    # @return [RedirectError, nil] error if redirect should not proceed, nil otherwise
    def check_redirect_error(task, response_data)
      location = response_data[:headers]["location"]
      redirect_url = resolve_redirect_url(task.request.url, location)

      check_too_many_redirects(task, location) || check_recursive_redirect(task, redirect_url)
    end

    # Check if the redirect count has exceeded the maximum.
    #
    # @param task [RequestTask] the request task
    # @param location [String] the redirect location URL
    # @return [TooManyRedirectsError, nil] error if exceeded, nil otherwise
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

    # Check if the redirect URL has already been visited (redirect loop).
    #
    # @param task [RequestTask] the request task
    # @param redirect_url [String] the resolved redirect URL
    # @return [RecursiveRedirectError, nil] error if loop detected, nil otherwise
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

    # Resolve a redirect URL, handling relative URLs.
    #
    # @param base_url [String] The base URL
    # @param location [String] The Location header value
    # @return [String] The resolved absolute URL
    def resolve_redirect_url(base_url, location)
      base_uri = URI.parse(base_url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
