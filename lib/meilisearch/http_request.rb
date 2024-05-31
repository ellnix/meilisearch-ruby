# frozen_string_literal: true

require 'http'
require 'meilisearch/error'

module MeiliSearch
  class HTTPRequest
    class << self
      def httprb_req(verb, path, headers, config, timeout)
        HTTP
          .timeout(timeout)
          .headers(headers)
          .public_send(verb, path, config)
      end

      %i[get post put patch delete].each do |verb|
        define_method(verb) do |path, config|
          headers = config.delete(:headers)
          timeout = config.delete(:timeout)
          retries = (config.delete(:max_retries) || 0) + 1

          response = nil
          last_error = nil
          retries.times do |try_n|
            begin
              response = httprb_req(verb, path, headers, config, timeout)
              break
            rescue HTTP::ConnectionError, Errno::EPIPE => e
              last_error = CommunicationError.new e.message
              sleep try_n
            rescue HTTP::ConnectTimeoutError => e
              last_error = TimeoutError.new e.message
              sleep try_n
            end
          end

          raise last_error unless response
          response
        end
      end
    end

    attr_reader :options, :headers

    DEFAULT_OPTIONS = {
      timeout: 1,
      max_retries: 0,
      convert_body?: true
    }.freeze

    def initialize(url, api_key = nil, options = {})
      @base_url = url
      @api_key = api_key
      @options = DEFAULT_OPTIONS.merge(options)
      @headers = build_default_options_headers
    end

    def http_get(relative_path = '', query_params = {})
      conf = {
        query_params: query_params,
        headers: remove_headers(@headers.dup, 'Content-Type'),
        options: @options
      }

      send_request(
        proc { |path, config| self.class.get(path, config) },
        relative_path,
        config: {
          query_params: query_params,
          headers: remove_headers(@headers.dup, 'Content-Type'),
          options: @options
        }
      )
    end

    def http_post(relative_path = '', body = nil, query_params = nil, options = {})
      send_request(
        proc { |path, config| self.class.post(path, config) },
        relative_path,
        config: {
          query_params: query_params,
          body: body,
          headers: @headers.dup.merge(options[:headers] || {}),
          options: @options.merge(options)
        }
      )
    end

    def http_put(relative_path = '', body = nil, query_params = nil)
      send_request(
        proc { |path, config| self.class.put(path, config) },
        relative_path,
        config: {
          query_params: query_params,
          body: body,
          headers: @headers,
          options: @options
        }
      )
    end

    def http_patch(relative_path = '', body = nil, query_params = nil)
      send_request(
        proc { |path, config| self.class.patch(path, config) },
        relative_path,
        config: {
          query_params: query_params,
          body: body,
          headers: @headers,
          options: @options
        }
      )
    end

    def http_delete(relative_path = '', query_params = nil)
      send_request(
        proc { |path, config| self.class.delete(path, config) },
        relative_path,
        config: {
          query_params: query_params,
          headers: remove_headers(@headers.dup, 'Content-Type'),
          options: @options
        }
      )
    end

    private

    def build_default_options_headers
      {
        'Content-Type' => 'application/json',
        'Authorization' => ("Bearer #{@api_key}" unless @api_key.nil?),
        'User-Agent' => [
          @options.fetch(:client_agents, []),
          MeiliSearch.qualified_version
        ].flatten.join(';')
      }.compact
    end

    def remove_headers(data, *keys)
      data.delete_if { |k| keys.include?(k) }
    end

    def send_request(http_method, relative_path, config: {})
      config = http_config(config[:query_params], config[:body], config[:options], config[:headers])

      begin
        response = http_method.call(@base_url + relative_path, config)
      rescue HTTP::ConnectionError, Errno::EPIPE => e
        raise CommunicationError, e.message
      rescue HTTP::ConnectTimeoutError => e
        raise TimeoutError, e.message
      end

      validate(response)
    end

    def http_config(query_params, body, options, headers)
      body = body.to_json if options[:convert_body?] == true
      {
        headers: headers,
        params: query_params,
        timeout: options[:timeout],
        max_retries: options[:max_retries],
        body: body,
      }.compact
    end

    def validate(response)
      raise ApiError.new(response.status.code, response.status.reason, response.body.to_s) unless response.status.success?

      JSON.parse response.body unless response.body.empty?
    end
  end
end
