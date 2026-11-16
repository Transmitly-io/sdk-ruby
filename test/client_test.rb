# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "openssl"
require "socket"
require_relative "../lib/transmitly"

class TransmitlyClientTest < Minitest::Test
  def test_requires_api_key
    assert_raises(ArgumentError) { Transmitly::Client.new(api_key: "") }
  end

  def test_verify_webhook
    secret = "whsec_test"
    body = '{"type":"email.delivered_to_mx"}'
    ts = Time.now.to_i
    signature = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}")
    header = "t=#{ts},v1=#{signature}"

    assert Transmitly::Client.verify_webhook(body, header, secret)
    refute Transmitly::Client.verify_webhook(body, header, "wrong")
    refute Transmitly::Client.verify_webhook(body, "t=#{ts - 400},v1=#{signature}", secret)
    refute Transmitly::Client.verify_webhook(body, "garbage", secret)
  end

  def test_send_posts_payload_and_idempotency_key
    status, body, captured = with_server(202, '{"id":"msg_123","status":"accepted","recipients":1}') do |base_url|
      tx = Transmitly::Client.new(api_key: "txk_test", base_url: base_url)
      tx.emails.deliver(
        {
          from: "Notify <notify@acme.com>",
          to: ["ada@example.net"],
          subject: "Welcome",
          html: "<p>Hi</p>",
          tags: { flow: "onboarding" }
        },
        idempotency_key: "welcome-1"
      )
    end

    assert_equal 202, status
    assert_equal "msg_123", body["id"]
    assert_equal "POST /v1/emails HTTP/1.1", captured[:request_line]
    assert_equal "Bearer txk_test", captured[:headers]["authorization"]
    assert_equal "welcome-1", captured[:headers]["idempotency-key"]
    payload = JSON.parse(captured[:body])
    assert_equal "Notify <notify@acme.com>", payload["from"]
    assert_equal ["ada@example.net"], payload["to"]
    assert_equal({ "flow" => "onboarding" }, payload["tags"])
  end

  def test_errors_raise_with_api_details
    error = assert_raises(Transmitly::Error) do
      with_server(409, '{"error":{"code":"idempotency_conflict","message":"Already used"}}') do |base_url|
        Transmitly::Client.new(api_key: "txk_test", base_url: base_url)
                        .emails.deliver({ from: "a@acme.com", to: "b@example.net", subject: "s", text: "t" })
      end
    end
    assert_equal 409, error.status
    assert_equal "idempotency_conflict", error.code
    assert_equal "Already used", error.message
  end

  def test_validation_happens_before_network
    tx = Transmitly::Client.new(api_key: "txk_test")
    assert_raises(ArgumentError) { tx.emails.deliver({ from: "a@acme.com", to: [], subject: "s", text: "t" }) }
    assert_raises(ArgumentError) { tx.emails.deliver({ from: "a@acme.com", to: "b@example.net", subject: "s" }) }
  end

  private

  # Minimal one-shot HTTP server. Returns [status, parsed_body, captured_request].
  def with_server(status, response_body)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = {}
    thread = Thread.new do
      socket = server.accept
      request_line = socket.gets&.strip
      headers = {}
      while (line = socket.gets)
        break if line == "\r\n"

        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip if key && value
      end
      length = headers.fetch("content-length", "0").to_i
      body = length.positive? ? socket.read(length) : ""
      captured[:request_line] = request_line
      captured[:headers] = headers
      captured[:body] = body
      socket.write("HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\nContent-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}")
      socket.close
    end

    result = yield("http://127.0.0.1:#{port}")
    thread.join(2)
    [status, result, captured]
  ensure
    server&.close
  end
end
