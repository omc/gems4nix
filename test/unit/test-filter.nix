# Unit tests for filter-helpers.nix
#
# Run: nix eval --file test/unit/test-filter.nix --json
# Returns: true (all assertions pass) or throws with a descriptive message.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
  lib = nixpkgs.lib;
  filterHelpers = import ../../lib/gemfile-env/filter-helpers.nix { inherit lib; };
  inherit (filterHelpers) filterGroup filterPlatform resolvePlatforms;
  inherit (import ../test-helpers.nix) assertEq assertThrows;

  # ── test fixtures ────────────────────────────────────────────

  mkGem = { gemName, platform ? "ruby", groups ? [ "default" ], version ? "1.0.0" }: {
    inherit gemName platform groups version;
    source = { sha256 = "fake"; remotes = [ "https://rubygems.org" ]; type = "gem"; };
  };

  gemRake = mkGem { gemName = "rake"; groups = [ "default" ]; };
  gemRspec = mkGem { gemName = "rspec"; groups = [ "test" ]; };
  gemPuma = mkGem { gemName = "puma"; groups = [ "default" "production" ]; };
  gemOrphan = mkGem { gemName = "mini_portile2"; groups = [ ]; };

  gemNokogiriRuby = mkGem { gemName = "nokogiri"; platform = "ruby"; };
  gemNokogiriArm = mkGem { gemName = "nokogiri"; platform = "arm64-darwin"; };
  gemNokogiriX86 = mkGem { gemName = "nokogiri"; platform = "x86_64-darwin"; };
  gemFfiLinux = mkGem { gemName = "ffi"; platform = "aarch64-linux-gnu"; };

  # ── filterGroup ──────────────────────────────────────────────

  test_filterGroup_match = assertEq
    "filterGroup: gem in requested group"
    (filterGroup [ "default" ] gemRake)
    true;

  test_filterGroup_no_match = assertEq
    "filterGroup: gem not in requested groups"
    (filterGroup [ "production" ] gemRspec)
    false;

  test_filterGroup_partial_overlap = assertEq
    "filterGroup: gem with multiple groups, one matches"
    (filterGroup [ "production" ] gemPuma)
    true;

  test_filterGroup_empty_gem_groups = assertEq
    "filterGroup: gem with empty groups excluded"
    (filterGroup [ "default" "development" "test" ] gemOrphan)
    false;

  test_filterGroup_empty_requested = assertEq
    "filterGroup: empty requested groups excludes everything"
    (filterGroup [ ] gemRake)
    false;

  test_filterGroup_multi_request = assertEq
    "filterGroup: multiple requested groups"
    (filterGroup [ "default" "test" ] gemRspec)
    true;

  # ── filterPlatform ───────────────────────────────────────────

  test_filterPlatform_ruby_match = assertEq
    "filterPlatform: ruby gem matches ruby platform"
    (filterPlatform [ "ruby" ] gemRake)
    true;

  test_filterPlatform_specific_match = assertEq
    "filterPlatform: platform-specific gem matches"
    (filterPlatform [ "ruby" "arm64-darwin" ] gemNokogiriArm)
    true;

  test_filterPlatform_no_match = assertEq
    "filterPlatform: gem platform not in requested list"
    (filterPlatform [ "ruby" "x86_64-linux" ] gemNokogiriArm)
    false;

  test_filterPlatform_multi_segment = assertEq
    "filterPlatform: multi-segment platform matches exactly"
    (filterPlatform [ "aarch64-linux-gnu" ] gemFfiLinux)
    true;

  test_filterPlatform_empty = assertEq
    "filterPlatform: empty platform list excludes everything"
    (filterPlatform [ ] gemRake)
    false;

  # ── combined filtering ───────────────────────────────────────

  allGems = [ gemRake gemRspec gemPuma gemOrphan gemNokogiriRuby gemNokogiriArm ];

  test_filter_pipeline =
    let
      groups = [ "default" ];
      platforms = [ "ruby" "arm64-darwin" ];
      afterGroup = builtins.filter (filterGroup groups) allGems;
      afterPlatform = builtins.filter (filterPlatform platforms) afterGroup;
      names = map (g: g.gemName) afterPlatform;
    in
    # rake (default, ruby) ✓
    # rspec (test) ✗ group
    # puma (default+production, ruby) ✓
    # mini_portile2 (empty groups) ✗ group
    # nokogiri ruby (default, ruby) ✓
    # nokogiri arm64 (default, arm64-darwin) ✓
    assertEq "filter pipeline: group then platform"
      names
      [ "rake" "puma" "nokogiri" "nokogiri" ];

  # ── resolvePlatforms ─────────────────────────────────────────

  test_resolve_prefers_specific =
    let
      result = resolvePlatforms [ gemNokogiriRuby gemNokogiriArm ];
    in
    assertEq "resolvePlatforms: prefers platform-specific over ruby"
      result.nokogiri.platform
      "arm64-darwin";

  test_resolve_ruby_only =
    let
      result = resolvePlatforms [ gemRake ];
    in
    assertEq "resolvePlatforms: falls back to ruby when only option"
      result.rake.platform
      "ruby";

  test_resolve_multiple_specific =
    let
      # both arm64-darwin and x86_64-darwin present: picks first non-ruby
      result = resolvePlatforms [ gemNokogiriArm gemNokogiriX86 ];
    in
    # documents current behavior: first platform-specific wins
    assertEq "resolvePlatforms: multiple specific platforms, first wins"
      result.nokogiri.platform
      "arm64-darwin";

  test_resolve_mixed_gems =
    let
      result = resolvePlatforms [ gemRake gemNokogiriRuby gemNokogiriArm gemFfiLinux ];
      names = builtins.attrNames result;
    in
    assertEq "resolvePlatforms: groups by name correctly"
      (builtins.sort builtins.lessThan names)
      [ "ffi" "nokogiri" "rake" ]
    && assertEq "resolvePlatforms: rake stays ruby" result.rake.platform "ruby"
    && assertEq "resolvePlatforms: nokogiri resolved to arm64" result.nokogiri.platform "arm64-darwin"
    && assertEq "resolvePlatforms: ffi resolved to linux" result.ffi.platform "aarch64-linux-gnu";

  # ── all tests ────────────────────────────────────────────────

  allTests =
    # filterGroup
    test_filterGroup_match
    && test_filterGroup_no_match
    && test_filterGroup_partial_overlap
    && test_filterGroup_empty_gem_groups
    && test_filterGroup_empty_requested
    && test_filterGroup_multi_request
    # filterPlatform
    && test_filterPlatform_ruby_match
    && test_filterPlatform_specific_match
    && test_filterPlatform_no_match
    && test_filterPlatform_multi_segment
    && test_filterPlatform_empty
    # combined
    && test_filter_pipeline
    # resolvePlatforms
    && test_resolve_prefers_specific
    && test_resolve_ruby_only
    && test_resolve_multiple_specific
    && test_resolve_mixed_gems;

in
allTests
