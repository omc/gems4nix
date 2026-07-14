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

# Propagate groups transitively through the dependency graph.
# Uses a fixpoint loop: iterate until no new group assignments are made.
# This is necessary because Bundler.locked_gems.specs iteration order is
# not topologically sorted, so a single pass can miss transitive deps
# whose parent groups haven't been assigned yet.
#
# We snapshot keys before each pass to avoid mutating the hash during
# iteration (Ruby's Hash.new default block auto-vivifies missing keys).
loop do
  changed = false
  groups.keys.each do |parent_name|
    parent_groups = groups[parent_name]
    next if parent_groups.empty?

    collect_descendants(parent_name, specs).each do |child_name|
      before = groups[child_name]
      merged = (before + parent_groups).uniq
      if merged.length > before.length
        groups[child_name] = merged
        changed = true
      end
    end
  end
  break unless changed
end

puts JSON.generate(groups)
