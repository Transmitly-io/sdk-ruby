# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

require_relative "transmitly/version"

module Transmitly
  class Error < StandardError
    attr_reader :status, :code, :details

    def initialize(status:, code: nil, message: nil, details: nil)
      super(message || "Request failed (#{status})")
      @status = status
      @code = code
      @details = details
    end
  end

  # Raised when a response cannot be decoded as JSON.
  class DecodeError < Error; end

  # Dependency-free client for the Transmitly email API.
  #
  #   tx = Transmitly::Client.new(api_key: ENV.fetch("TRANSMITLY_API_KEY"))
  #   accepted = tx.emails.deliver(
  #     from: "Notify <notify@mail.acme.com>",
  #     to: ["ada@example.net"],
  #     subject: "Welcome",
  #     html: "<p>Your workspace is ready.</p>"
  #   )
  class Client
    DEFAULT_BASE_URL = "https://transmitly.io"
    DEFAULT_TIMEOUT = 15

    attr_reader :base_url, :timeout, :emails, :messages, :domains, :suppressions,
                :webhooks, :inbound, :usage, :events

    def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT)
      raise ArgumentError, "api_key is required" if api_key.nil? || api_key.to_s.empty?

      @api_key = api_key.to_s
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @timeout = timeout

      @emails = Emails.new(self)
      @messages = Messages.new(self)
      @domains = Domains.new(self)
      @suppressions = Suppressions.new(self)
      @webhooks = Webhooks.new(self)
      @inbound = Inbound.new(self)
      @usage = Usage.new(self)
      @events = Events.new(self)
    end

    def send_email(payload, idempotency_key: nil)
      emails.deliver(payload, idempotency_key: idempotency_key)
    end

    def health
      request(:get, "/v1/health", auth: false)
    end

    # Verify a webhook delivery. Pass the raw request body (not a parsed hash),
    # the Transmitly-Signature header and the endpoint signing secret.
    def self.verify_webhook(raw_body, signature_header, secret, tolerance: 300)
      return false if signature_header.nil? || signature_header.empty?

      timestamp = nil
      signature = nil
      signature_header.split(",").each do |part|
        key, value = part.strip.split("=", 2)
        next if value.nil?

        timestamp = value.to_i if key == "t"
        signature = value if key == "v1"
      end
      return false unless timestamp && signature

      if tolerance.positive? && (Time.now.to_i - timestamp).abs > tolerance
        return false
      end

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{raw_body}")
      self.secure_compare(signature, expected)
    end

    def self.secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      result = 0
      left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
      result.zero?
    end

    # @api private
    def request(method, path, body: nil, query: nil, headers: {}, auth: true)
      uri = URI.parse("#{@base_url}#{path}")
      if query
        clean = query.each_with_object({}) do |(key, value), out|
          out[key] = value unless value.nil? || value == ""
        end
        uri.query = URI.encode_www_form(clean) unless clean.empty?
      end

      request_class = case method
                      when :get then Net::HTTP::Get
                      when :post then Net::HTTP::Post
                      when :patch then Net::HTTP::Patch
                      when :put then Net::HTTP::Put
                      when :delete then Net::HTTP::Delete
                      else raise ArgumentError, "unsupported method: #{method}"
                      end

      req = request_class.new(uri.request_uri)
      req["Accept"] = "application/json"
      req["Authorization"] = "Bearer #{@api_key}" if auth
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      headers.each { |key, value| req[key] = value }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout

      response = http.request(req)
      parse(response)
    end

    private

    def parse(response)
      raw = response.body.to_s
      payload =
        if raw.empty?
          nil
        else
          begin
            JSON.parse(raw)
          rescue JSON::ParserError
            raise DecodeError.new(status: response.code.to_i, message: "Could not decode JSON response")
          end
        end

      return payload if response.is_a?(Net::HTTPSuccess)

      error = payload.is_a?(Hash) ? payload["error"] || {} : {}
      raise Error.new(
        status: response.code.to_i,
        code: error["code"],
        message: error["message"] || "Request failed (#{response.code})",
        details: error["details"]
      )
    end

    class Resource
      def initialize(client)
        @client = client
      end

      private

      def clean(hash)
        hash.each_with_object({}) do |(key, value), out|
          out[key] = value unless value.nil?
        end
      end

      def encode(id)
        URI.encode_www_form_component(id.to_s)
      end
    end

    class Emails < Resource
      def deliver(payload, idempotency_key: nil)
        raise ArgumentError, "from is required" if payload[:from].nil? || payload[:from].to_s.empty?
        raise ArgumentError, "to is required" if payload[:to].nil? || Array(payload[:to]).empty?
        raise ArgumentError, "subject is required" if payload[:subject].nil? || payload[:subject].to_s.empty?
        unless payload[:html] || payload[:text] || payload[:template_id]
          raise ArgumentError, "html, text or template_id is required"
        end

        key = idempotency_key || SecureRandom.uuid
        @client.request(
          :post,
          "/v1/emails",
          body: clean(payload),
          headers: { "Idempotency-Key" => key }
        )
      end
      alias send_email deliver

      def get(id)
        @client.request(:get, "/v1/emails/#{encode(id)}")
      end
    end

    class Messages < Resource
      def list(**params)
        @client.request(:get, "/v1/messages", query: clean(params))
      end

      def get(id)
        @client.request(:get, "/v1/messages/#{encode(id)}")
      end

      def deliveries(id)
        @client.request(:get, "/v1/messages/#{encode(id)}/deliveries")
      end
    end

    class Domains < Resource
      def list
        @client.request(:get, "/v1/domains")
      end

      def create(domain)
        @client.request(:post, "/v1/domains", body: { domain: domain })
      end

      def verify(id)
        @client.request(:post, "/v1/domains/#{encode(id)}/verify", body: {})
      end

      def remove(id)
        @client.request(:delete, "/v1/domains/#{encode(id)}")
      end
    end

    class Suppressions < Resource
      def list(**params)
        @client.request(:get, "/v1/suppressions", query: clean(params))
      end

      def add(**input)
        @client.request(:post, "/v1/suppressions", body: clean(input))
      end

      def remove(id)
        @client.request(:delete, "/v1/suppressions/#{encode(id)}")
      end
    end

    class Webhooks < Resource
      def list
        @client.request(:get, "/v1/webhooks")
      end

      def create(**input)
        @client.request(:post, "/v1/webhooks", body: clean(input))
      end

      def remove(id)
        @client.request(:delete, "/v1/webhooks/#{encode(id)}")
      end
    end

    class Inbound < Resource
      def routes
        @client.request(:get, "/v1/inbound/routes")
      end

      def add_route(**input)
        @client.request(:post, "/v1/inbound/routes", body: clean(input))
      end

      def remove_route(id)
        @client.request(:delete, "/v1/inbound/routes/#{encode(id)}")
      end
    end

    class Usage < Resource
      def get(**params)
        @client.request(:get, "/v1/usage", query: clean(params))
      end
    end

    class Events < Resource
      def list(**params)
        @client.request(:get, "/v1/events", query: clean(params))
      end
    end
  end
end
