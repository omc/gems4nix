# frozen_string_literal: true

# Verifies group inference succeeds against a Gemfile using the `gemspec`
# directive (default `bundle gem` layout). See github.com/omc/gems4nix
# issue #2. The regression is that the group-detection IFD sandbox
# previously omitted the gemspec, so Bundler aborted before any gems
# could be resolved.

require "rake"

unless defined?(Rake::VERSION)
  warn "expected Rake constant to be defined after require"
  exit 1
end

puts "gemspec-directive: rake #{Rake::VERSION} loaded from #{Rake.method(:application).source_location.first}"
