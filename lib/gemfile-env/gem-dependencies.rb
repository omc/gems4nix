# frozen_string_literal: true

require 'bundler'
require 'json'

deps = Hash.new { |h, k| h[k] = [] }

puts JSON.generate(deps)
