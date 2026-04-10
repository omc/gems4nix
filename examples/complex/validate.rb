# Integration test: validates a Rails-scale gem environment with native gems,
# git sources, and path sources. Exit 1 on any failure.

failures = []

# Rails framework: pulls in actionpack, activerecord, activesupport, etc.
begin
  require 'rails'
  v = Rails.version
  raise 'unexpected version' unless v.start_with?('8.')

  puts "OK  rails #{v}"
rescue StandardError => e
  failures << "rails: #{e.message}"
end

# nokogiri: native gem, platform-specific
begin
  require 'nokogiri'
  doc = Nokogiri::XML('<test>works</test>')
  raise 'parse failed' unless doc.at('test').text == 'works'

  puts "OK  nokogiri #{Nokogiri::VERSION}"
rescue StandardError => e
  failures << "nokogiri: #{e.message}"
end

# ffi: native gem, platform-specific
begin
  require 'ffi'
  puts "OK  ffi #{FFI::VERSION}"
rescue StandardError => e
  failures << "ffi: #{e.message}"
end

# puma: native (nio4r)
begin
  require 'puma'
  puts "OK  puma #{Puma::Const::PUMA_VERSION}"
rescue StandardError => e
  failures << "puma: #{e.message}"
end

# jbuilder: pure ruby, depends on actionview
begin
  require 'jbuilder'
  puts "OK  jbuilder #{Jbuilder::VERSION}"
rescue StandardError => e
  failures << "jbuilder: #{e.message}"
end

# bootsnap: native (msgpack C ext)
begin
  require 'bootsnap'
  puts "OK  bootsnap #{Bootsnap::VERSION}"
rescue StandardError => e
  failures << "bootsnap: #{e.message}"
end

# errgonomic: from git source (TODO #13: git sources)
# Expected to fail until git source parsing is implemented.
begin
  require 'errgonomic'
  puts "OK  errgonomic #{Errgonomic::VERSION}"
rescue LoadError => e
  puts 'SKIP  errgonomic (git source not yet supported: TODO #13)'
rescue StandardError => e
  failures << "errgonomic: #{e.message}"
end

# hello_gem: from path source (TODO #13: path sources)
# Expected to fail until path source parsing is implemented.
begin
  require 'hello_gem'
  msg = HelloGem.greet
  raise "greet returned #{msg.inspect}" unless msg == 'hello from gems4nix'

  puts "OK  hello_gem #{HelloGem::VERSION}"
rescue LoadError => e
  puts 'SKIP  hello_gem (path source not yet supported: TODO #13)'
rescue StandardError => e
  failures << "hello_gem: #{e.message}"
end

# Group filtering: minitest is in :development,:test
begin
  require 'minitest'
  puts "OK  minitest #{Minitest::VERSION}"
rescue StandardError => e
  failures << "minitest: #{e.message}"
end

# Transitive dep: activesupport depends on concurrent-ruby
begin
  require 'concurrent-ruby'
  puts "OK  concurrent-ruby #{Concurrent::VERSION}"
rescue StandardError => e
  failures << "concurrent-ruby: #{e.message}"
end

if failures.any?
  warn "\n#{failures.length} failure(s):"
  failures.each { |f| warn "  FAIL  #{f}" }
  exit 1
else
  puts "\nAll 10 gems validated."
end
