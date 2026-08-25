# frozen_string_literal: true

# Which order does Bundler write a GEM section's `remote:` lines in, and which
# order does it read them back in?
#
# gems4nix reverses the lockfile's order so that a gem's remotes reach the
# fetch in Bundler's own lookup priority. That reversal is only correct because
# Bundler writes the file in the opposite order to the one it looks remotes up
# in, and this is the measurement behind the claim. Reading `add_remote` and
# `to_lock` is what got it wrong the first time.
#
# Run under the Bundler on the path:
#   ruby scripts/bundler-remote-order.rb
#
# Run under a specific Bundler. `-I` is not enough on its own: RubyGems
# overrides `require`, activates the newest Bundler it can find, and the
# devshell puts one on both RUBYLIB and GEM_PATH. Take those away and point
# GEM_PATH at the tree holding the version you want:
#
#   env -u RUBYLIB GEM_PATH=<prefix>/lib/ruby/gems/<abi> GEM_HOME=<same> \
#     ruby scripts/bundler-remote-order.rb <version>
#
# The version argument is what makes that reliable; without it a mis-aimed run
# reports on whichever Bundler actually loaded.
#
# Pass the version you believe you are running and it will refuse to report on
# any other. RubyGems activates the newest installed Bundler in preference to
# one on the load path, so `-I` alone silently measures the wrong version:
#
#   ruby -I <2.6.9>/lib scripts/bundler-remote-order.rb 2.6.9
#
# Exits non-zero if the invariant gems4nix relies on stops holding.

require 'bundler'

expected = ARGV[0]
if expected && expected != Bundler::VERSION
  warn "asked for bundler #{expected} but loaded #{Bundler::VERSION}; " \
       'RubyGems prefers the newest installed Bundler over one on the load path. ' \
       'Narrow GEM_PATH, or activate it with `gem "bundler", "<version>"`.'
  exit 1
end

FIRST = 'https://a.example.invalid/'
LAST  = 'https://b.example.invalid/'

# A Gemfile declaring FIRST and then LAST produces this source.
source = Bundler::Source::Rubygems.new
source.add_remote(FIRST)
source.add_remote(LAST)

in_memory = source.remotes.map(&:to_s)
file_order = source.to_lock.lines.grep(/remote:/).map { |line| line[/remote: (.*)/, 1] }

lockfile = <<~LOCK
  #{source.to_lock.chomp}
      rake (13.3.1)

  PLATFORMS
    ruby

  DEPENDENCIES
    rake

  CHECKSUMS
    rake (13.3.1) sha256=8c9e89d09f66a26a01264e7e3480ec0607f0c497a861ef16063604b1b08eb19c
LOCK

reparsed = Bundler::LockfileParser.new(lockfile).sources.first.remotes.map(&:to_s)

puts format('bundler %s', Bundler::VERSION)
puts format('  declared:  %s then %s', FIRST, LAST)
puts format('  in-memory: %s', in_memory.inspect)
puts format('  file:      %s', file_order.inspect)
puts format('  reparsed:  %s', reparsed.inspect)

failures = []
failures << "in-memory order is not last-declared-first: #{in_memory.inspect}" if in_memory != [LAST, FIRST]
failures << "file order is not first-declared-first: #{file_order.inspect}" if file_order != [FIRST, LAST]
failures << "reparsed order is not the reverse of the file: #{reparsed.inspect}" if reparsed != file_order.reverse

if failures.empty?
  puts '  OK: the file is written in the reverse of Bundler lookup order'
  exit 0
end

failures.each { |f| warn "  FAIL: #{f}" }
exit 1
