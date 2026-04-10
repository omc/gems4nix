# Integration test: validates that pure-ruby gems are loadable and functional.
# Exit 1 on any failure so `nix build` treats it as a build error.

failures = []

# rack
begin
  require "rack"
  v = Rack.release
  raise "unexpected version" unless v.start_with?("3.")
  puts "OK  rack #{v}"
rescue => e
  failures << "rack: #{e.message}"
end

# rake
begin
  require "rake"
  v = Rake::VERSION
  raise "unexpected version" unless v.start_with?("13.")
  puts "OK  rake #{v}"
rescue => e
  failures << "rake: #{e.message}"
end

if failures.any?
  failures.each { |f| $stderr.puts "FAIL  #{f}" }
  exit 1
else
  puts "All #{2} gems validated."
end
