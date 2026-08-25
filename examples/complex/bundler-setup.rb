# Boots the way a stock Rails app's config/boot.rb does. This is a different
# claim from validate.rb's: plain `require` finds a gem anywhere on GEM_PATH,
# while Bundler resolves the lockfile itself and insists a git gem sit where it
# would have checked one out. Only one of the two can catch a regression there.

require 'bundler/setup'

failures = []

# The source Bundler resolved a gem through, not merely that the gem loaded.
# A git gem found through the rubygems index would mean the lockfile's GIT
# section was ignored, and that passes a bare `require` just fine.
def check_source(name, expected_source)
  spec = Bundler.load.specs.find { |s| s.name == name }
  raise "#{name} is not in the resolved bundle" if spec.nil?

  actual = spec.source.class.name
  raise "resolved through #{actual}, expected #{expected_source}" unless actual == expected_source

  spec
end

# errgonomic comes from the GIT section. Bundler looks for it under
# bundler/gems/<repo>-<shortrev>, never on the GEM_PATH.
begin
  spec = check_source('errgonomic', 'Bundler::Source::Git')
  unless spec.full_gem_path.include?('/bundler/gems/')
    raise "loaded from #{spec.full_gem_path}, not from a bundler/gems checkout"
  end

  # Its railtie references ActiveModel and ActiveRecord at class-definition
  # time, and a real app gets those from the framework boot.
  require 'active_model'
  require 'active_record'
  require 'errgonomic'
  puts "OK  errgonomic #{Errgonomic::VERSION} from #{spec.full_gem_path}"
rescue StandardError => e
  failures << "errgonomic: #{e.message}"
end

# hello_gem comes from the PATH section, read out of its source directory
# relative to the Gemfile.
begin
  spec = check_source('hello_gem', 'Bundler::Source::Path')
  require 'hello_gem'
  raise "greet returned #{HelloGem.greet.inspect}" unless HelloGem.greet == 'hello from gems4nix'

  puts "OK  hello_gem #{HelloGem::VERSION} from #{spec.full_gem_path}"
rescue StandardError => e
  failures << "hello_gem: #{e.message}"
end

# rails comes from the GEM section, found through the rubygems index.
begin
  spec = check_source('rails', 'Bundler::Source::Rubygems')
  require 'rails'
  raise "unexpected version #{Rails.version}" unless Rails.version.start_with?('8.')

  puts "OK  rails #{Rails.version} from #{spec.full_gem_path}"
rescue StandardError => e
  failures << "rails: #{e.message}"
end

if failures.any?
  warn "\n#{failures.length} failure(s):"
  failures.each { |f| warn "  FAIL  #{f}" }
  exit 1
else
  puts "\nbundler/setup resolved every source kind."
end
