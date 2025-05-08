# frozen_string_literal: true

require 'bundler'
require 'json'

# collect all specs by name
specs = Bundler.locked_gems.specs.each_with_object({}) do |spec, h|
  h[spec.name] = spec
end

# recurse to find and flatten the names for the dependencies of a given spec
def collect_descendants(name, specs, seen = Set.new)
  return [] if seen.include?(name)
  return [] if specs[name].nil?

  seen.add name
  descendants = specs[name].dependencies.map(&:name)
  (descendants + descendants.map do |n|
    collect_descendants(n, specs, seen)
  end).flatten.sort
end

# groups start with top level dependencies
groups = Hash.new { |h, k| h[k] = [] }
Bundler.definition.dependencies.each_with_object(groups) do |dep, h|
  dep.groups.each do |group|
    h[dep.name] << group.to_s
  end
end

# work through all the rest
Bundler.locked_gems.specs.each_with_object(groups) do |spec, h|
  collect_descendants(spec.name, specs).each do |name|
    h[name] = (h[name] + h[spec.name]).uniq
  end
end

puts JSON.generate(groups)
