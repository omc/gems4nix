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
  inherit (filterHelpers) filterGroup filterPlatform resolvePlatforms applyGemConfigs platformsForSystem;
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

  # ── applyGemConfigs ───────────────────────────────────────────

  test_applyGemConfigs_matching =
    let
      myConfig = {
        rake = attrs: { buildFlags = [ "--verbose" ]; };
      };
      result = applyGemConfigs myConfig gemRake;
    in
    assertEq "applyGemConfigs: matching gem gets config merged"
      result.buildFlags
      [ "--verbose" ];

  test_applyGemConfigs_no_match =
    let
      myConfig = {
        nokogiri = attrs: { buildFlags = [ "--verbose" ]; };
      };
      result = applyGemConfigs myConfig gemRake;
    in
    # rake is not in myConfig, should be returned unchanged
    assertEq "applyGemConfigs: non-matching gem unchanged"
      (result ? buildFlags)
      false;

  test_applyGemConfigs_config_receives_attrs =
    let
      # config function that uses the gem's own version
      myConfig = {
        rake = attrs: { description = "rake version ${attrs.version}"; };
      };
      result = applyGemConfigs myConfig gemRake;
    in
    assertEq "applyGemConfigs: config function receives gem attrs"
      result.description
      "rake version 1.0.0";

  test_applyGemConfigs_empty_config =
    let
      result = applyGemConfigs { } gemRake;
    in
    assertEq "applyGemConfigs: empty config leaves gem unchanged"
      result.gemName
      "rake";

  # ── critique #9: reproduce the shadowing bug pattern ─────────
  #
  # In the old default.nix, the user-supplied gemConfig argument was shadowed
  # by a local `let` binding. This test reproduces that pattern to prove the
  # bug is real, then verifies our extracted applyGemConfigs avoids it.

  test_gemConfig_shadowing_bug =
    let
      # Simulate what old default.nix did:
      # 1. User passes userConfig as the "gemConfig" argument
      # 2. A local let binding redefines gemConfig, shadowing the argument
      # 3. applyGemConfigs closes over the local, not the user's
      userConfig = {
        rake = attrs: { userSupplied = true; };
      };
      localConfig = {
        nokogiri = attrs: { localOnly = true; };
      };

      # OLD PATTERN (buggy): applyGemConfigs closes over localConfig,
      # ignoring userConfig entirely
      buggyApply = attrs:
        if localConfig ? ${attrs.gemName} then
          attrs // localConfig.${attrs.gemName} attrs
        else
          attrs;

      buggyResult = buggyApply gemRake;
    in
    # The user wanted rake to get { userSupplied = true; } but the local config
    # doesn't have rake, so it passes through unchanged and the user's config is
    # silently lost.
    assertEq "gemConfig shadowing: buggy pattern loses user config"
      (buggyResult ? userSupplied)
      false
    # Now verify the correct pattern: applyGemConfigs takes config as a
    # parameter, so we can pass the user's config
    && assertEq "gemConfig shadowing: correct pattern applies user config"
      (applyGemConfigs userConfig gemRake).userSupplied
      true;

  # ── platformsForSystem (#19) ─────────────────────────────────
  #
  # Maps nixpkgs system strings to the Ruby platform strings that should be
  # accepted from a Gemfile.lock. Always includes "ruby" (pure-Ruby gems).

  test_platformsForSystem_aarch64_darwin =
    let result = platformsForSystem "aarch64-darwin";
    in
    assertEq "platformsForSystem: aarch64-darwin includes ruby"
      (builtins.elem "ruby" result)
      true
    && assertEq "platformsForSystem: aarch64-darwin includes arm64-darwin"
      (builtins.elem "arm64-darwin" result)
      true
    && assertEq "platformsForSystem: aarch64-darwin includes universal-darwin"
      (builtins.elem "universal-darwin" result)
      true;

  test_platformsForSystem_x86_64_darwin =
    let result = platformsForSystem "x86_64-darwin";
    in
    assertEq "platformsForSystem: x86_64-darwin includes ruby"
      (builtins.elem "ruby" result)
      true
    && assertEq "platformsForSystem: x86_64-darwin includes x86_64-darwin"
      (builtins.elem "x86_64-darwin" result)
      true
    && assertEq "platformsForSystem: x86_64-darwin includes universal-darwin"
      (builtins.elem "universal-darwin" result)
      true
    && assertEq "platformsForSystem: x86_64-darwin does NOT include arm64-darwin"
      (builtins.elem "arm64-darwin" result)
      false;

  test_platformsForSystem_aarch64_linux =
    let result = platformsForSystem "aarch64-linux";
    in
    assertEq "platformsForSystem: aarch64-linux includes ruby"
      (builtins.elem "ruby" result)
      true
    && assertEq "platformsForSystem: aarch64-linux includes aarch64-linux"
      (builtins.elem "aarch64-linux" result)
      true
    && assertEq "platformsForSystem: aarch64-linux includes aarch64-linux-gnu"
      (builtins.elem "aarch64-linux-gnu" result)
      true
    && assertEq "platformsForSystem: aarch64-linux includes aarch64-linux-musl"
      (builtins.elem "aarch64-linux-musl" result)
      true;

  test_platformsForSystem_x86_64_linux =
    let result = platformsForSystem "x86_64-linux";
    in
    assertEq "platformsForSystem: x86_64-linux includes ruby"
      (builtins.elem "ruby" result)
      true
    && assertEq "platformsForSystem: x86_64-linux includes x86_64-linux"
      (builtins.elem "x86_64-linux" result)
      true
    && assertEq "platformsForSystem: x86_64-linux includes x86_64-linux-gnu"
      (builtins.elem "x86_64-linux-gnu" result)
      true
    && assertEq "platformsForSystem: x86_64-linux includes x86_64-linux-musl"
      (builtins.elem "x86_64-linux-musl" result)
      true;

  test_platformsForSystem_unknown_throws =
    assertThrows "platformsForSystem: unknown system throws"
      (platformsForSystem "riscv64-linux");

  # Verify the mapping integrates with filterPlatform end-to-end
  test_platformsForSystem_filter_integration =
    let
      platforms = platformsForSystem "aarch64-darwin";
      # arm64-darwin gem should pass filterPlatform with aarch64-darwin mapping
      passes = filterPlatform platforms gemNokogiriArm;
      # x86_64-darwin gem should NOT pass
      rejects = filterPlatform platforms gemNokogiriX86;
    in
    assertEq "platformsForSystem integration: arm64-darwin gem passes on aarch64-darwin"
      passes true
    && assertEq "platformsForSystem integration: x86_64-darwin gem rejected on aarch64-darwin"
      rejects false;

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
    && test_resolve_mixed_gems
    # applyGemConfigs
    && test_applyGemConfigs_matching
    && test_applyGemConfigs_no_match
    && test_applyGemConfigs_config_receives_attrs
    && test_applyGemConfigs_empty_config
    # critique #9: shadowing
    && test_gemConfig_shadowing_bug
    # critique #19: platformsForSystem
    && test_platformsForSystem_aarch64_darwin
    && test_platformsForSystem_x86_64_darwin
    && test_platformsForSystem_aarch64_linux
    && test_platformsForSystem_x86_64_linux
    && test_platformsForSystem_unknown_throws
    && test_platformsForSystem_filter_integration;

in
allTests
