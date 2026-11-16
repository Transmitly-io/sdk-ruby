# Transmitly Ruby SDK

Dependency-free Ruby client for the Transmitly API. Requires Ruby 3.0+.

```ruby
require "transmitly"

tx = Transmitly::Client.new(api_key: ENV.fetch("TRANSMITLY_API_KEY"))

accepted = tx.emails.deliver(
  from: "Notify <notify@mail.acme.com>",
  to: ["ada@example.net"],
  subject: "Your workspace is ready",
  html: "<p>Welcome.</p>",
  reply_to: "Support <support@acme.com>",
  tags: { flow: "onboarding" }
)
# => {"id"=>"msg_…", "status"=>"accepted", "recipients"=>1}
```

`emails.deliver` generates an idempotency key. Pass `idempotency_key:` to
control it yourself; retries with the same key return the original message.

## Rails

Put the key in credentials and create one client:

```ruby
# config/initializers/transmitly.rb
TRANSMITLY = Transmitly::Client.new(
  api_key: Rails.application.credentials.transmitly_api_key!
)
```

```ruby
# app/controllers/welcome_controller.rb
TRANSMITLY.emails.deliver(
  from: "Notify <notify@mail.acme.com>",
  to: [current_user.email],
  subject: "Welcome to Acme",
  html: render_to_string(template: "welcome/email", formats: [:html])
)
```

Keep the key server-side. In Rails, prefer a background job for the network call
so the request does not wait on email delivery.

## Resources

```ruby
tx.messages.list(status: "bounced", limit: 20)
tx.messages.deliveries(message_id)
tx.domains.list
tx.domains.create("mail.acme.com")
tx.domains.verify(domain_id)
tx.suppressions.list
tx.suppressions.add(email: "bounce@example.net", reason: "manual")
tx.webhooks.list
tx.webhooks.create(url: "https://api.acme.com/hooks", events: ["email.delivered_to_mx"])
tx.inbound.routes
tx.usage.get
tx.events.list(limit: 50)
tx.health
```

Attachments accept base64 content or a public HTTPS path:

```ruby
tx.emails.deliver(
  from: "Notify <notify@mail.acme.com>",
  to: ["ada@example.net"],
  subject: "November invoice",
  html: "<p>Attached.</p>",
  attachments: [
    { filename: "invoice.pdf", path: "https://cdn.acme.com/invoice.pdf", content_type: "application/pdf" }
  ]
)
```

## Webhooks

Verify the raw request body before parsing it:

```ruby
# app/controllers/webhooks_controller.rb
def create
  raw = request.raw_post
  unless Transmitly::Client.verify_webhook(raw, request.headers["Transmitly-Signature"], ENV.fetch("TRANSMITLY_WEBHOOK_SECRET"))
    return head :bad_request
  end

  event = JSON.parse(raw)
  # handle event["type"]
  head :ok
end
```

Non-2xx responses raise `Transmitly::Error` with `status`, `code`, `message`
and `details`. Domain, webhook and inbound management require an API key with
the `admin` scope.

```bash
gem build transmitly.gemspec
gem install ./transmitly-1.0.0.gem
```
