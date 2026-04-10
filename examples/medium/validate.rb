# Integration test: validates native gems with platform variants are loadable
# and functional. Exit 1 on any failure so `nix build` treats it as a build error.

failures = []

# nokogiri: native gem with platform-specific precompiled variants.
# If platform resolution is wrong, this will either fail to load or
# fall back to the ruby variant (which requires compiling libxml2).
begin
  require "nokogiri"
  v = Nokogiri::VERSION
  raise "unexpected version" unless v.start_with?("1.1")

  # Actually parse XML to prove the native extension works
  doc = Nokogiri::XML("<root><item>hello</item></root>")
  text = doc.at_xpath("//item").text
  raise "XML parse failed: got #{text.inspect}" unless text == "hello"
  puts "OK  nokogiri #{v} (XML parsing works)"
rescue => e
  failures << "nokogiri: #{e.message}"
end

# puma: native gem (nio4r dependency has C extension)
begin
  require "puma"
  v = Puma::Const::PUMA_VERSION
  raise "unexpected version" unless v.start_with?("6.")
  puts "OK  puma #{v}"
rescue => e
  failures << "puma: #{e.message}"
end

# rack: pure ruby, sanity check
begin
  require "rack"
  v = Rack.release
  raise "unexpected version" unless v.start_with?("3.")
  puts "OK  rack #{v}"
rescue => e
  failures << "rack: #{e.message}"
end

# minitest: from :test group. If group filtering drops it, this fails.
begin
  require "minitest"
  v = Minitest::VERSION
  raise "unexpected version" unless v.start_with?("5.")
  puts "OK  minitest #{v}"
rescue => e
  failures << "minitest: #{e.message}"
end

if failures.any?
  failures.each { |f| $stderr.puts "FAIL  #{f}" }
  exit 1
else
  puts "All #{4} gems validated."
end
