# Integration test: validates platform-dependent gems are loadable and functional.
# Focuses on nokogiri (native XML extension) and ffi (foreign function interface)
# since these are the gems whose platform inference is being tested.
# Exit 1 on any failure so `nix build` treats it as a build error.

failures = []

# nokogiri: native gem with platform-specific precompiled variants.
# If platform resolution is wrong, this will either fail to load or
# fall back to the ruby variant (which requires compiling libxml2).
begin
  require "nokogiri"
  v = Nokogiri::VERSION
  # Actually parse XML to prove the native extension works
  doc = Nokogiri::XML("<root><item>hello</item></root>")
  text = doc.at_xpath("//item").text
  raise "XML parse failed: got #{text.inspect}" unless text == "hello"
  puts "OK  nokogiri #{v} (XML parsing works)"
rescue => e
  failures << "nokogiri: #{e.message}"
end

# ffi: native gem with platform-specific precompiled variants.
# Included transitively via ethon (not a direct Gemfile dependency).
# Tests that the correct platform variant was selected.
begin
  require "ffi"
  v = FFI::VERSION

  # Exercise basic FFI functionality
  puts "OK  ffi #{v}"
rescue => e
  failures << "ffi: #{e.message}"
end

if failures.any?
  failures.each { |f| $stderr.puts "FAIL  #{f}" }
  exit 1
else
  puts "All #{2} platform-dependent gems validated."
end
