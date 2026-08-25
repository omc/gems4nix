# frozen_string_literal: true

# Verifies group inference succeeds against a Gemfile using the `gemspec`
# directive (default `bundle gem` layout). See github.com/omc/gems4nix
# issue #2. The regression is that the group-detection IFD sandbox
# previously omitted the gemspec, so Bundler aborted before any gems
# could be resolved.
#
# The same Gemfile locks the project itself as a PATH source at ".", so this
# also covers a path gem whose remote is the lockfile's own directory. Loading
# it is the point: a build that produces a wrong-but-non-empty gem passes every
# check that only asks whether the build succeeded.

require 'rake'

unless defined?(Rake::VERSION)
  warn 'expected Rake constant to be defined after require'
  exit 1
end

# foo comes from the PATH section. Its gemspec ships lib/foo/version.rb and
# nothing else, so that is what there is to require.
require 'foo/version'

unless defined?(Foo::VERSION)
  warn 'expected Foo::VERSION to be defined after requiring the path gem'
  exit 1
end

unless Foo::VERSION == '0.1.0'
  warn "expected Foo::VERSION to be 0.1.0, got #{Foo::VERSION.inspect}"
  exit 1
end

loaded_from = $LOADED_FEATURES.find { |f| f.end_with?('foo/version.rb') }

unless loaded_from&.start_with?('/nix/store/')
  warn "expected foo/version.rb to load from the Nix store, got #{loaded_from.inspect}"
  exit 1
end

puts "gemspec-directive: rake #{Rake::VERSION} loaded from #{Rake.method(:application).source_location.first}"
puts "gemspec-directive: foo #{Foo::VERSION} (PATH source) loaded from #{loaded_from}"
