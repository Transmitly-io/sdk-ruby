# frozen_string_literal: true

require_relative "lib/transmitly/version"

Gem::Specification.new do |spec|
  spec.name = "transmitly"
  spec.version = Transmitly::VERSION
  spec.authors = ["Swift Nodes LLC"]
  spec.email = ["support@transmitly.io"]
  spec.summary = "Ruby client for the Transmitly email API"
  spec.description = "Dependency-free Ruby client for sending transactional email and inspecting delivery state with Transmitly."
  spec.homepage = "https://transmitly.io/docs/sdks"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/Transmitly-io/sdk-ruby",
    "changelog_uri" => "https://github.com/Transmitly-io/sdk-ruby/releases",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake", ">= 13.0"
end
