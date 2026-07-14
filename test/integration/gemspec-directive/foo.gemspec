# frozen_string_literal: true

require_relative "lib/foo/version"

Gem::Specification.new do |spec|
  spec.name    = "foo"
  spec.version = Foo::VERSION
  spec.authors = ["gems4nix test"]
  spec.summary = "Fixture exercising the `gemspec` directive"
  spec.files   = ["lib/foo/version.rb"]
  spec.required_ruby_version = ">= 3.0.0"

  spec.add_dependency "rake", "~> 13.0"
end
