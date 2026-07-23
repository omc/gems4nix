# Unit tests for resolve.nix (logic only, no fetchTarball)
#
# Accepts { lib }: so it can be imported by both:
#   - The standalone wrapper (test-resolve.nix) for `nix eval --file` usage
#   - The root flake.nix checks via `import ./test-resolve-logic.nix { lib = pkgs.lib; }`
#
# Returns: true (all assertions pass) or throws with a descriptive message.

{ lib }:

let
  filterHelpers = import ../../lib/gemfile-env/resolve.nix { inherit lib; };
  inherit (filterHelpers)
    filterGroup
    filterPlatform
    resolvePlatforms
    applyGemConfigs
    platformsForSystem
    expandTransitiveDeps
    ;
  inherit (import ../helpers.nix) assertEq assertThrows mkGem;

  gemRake = mkGem {
    gemName = "rake";
    groups = [ "default" ];
  };
  gemRspec = mkGem {
    gemName = "rspec";
    groups = [ "test" ];
  };
  gemPuma = mkGem {
    gemName = "puma";
    groups = [
      "default"
      "production"
    ];
  };
  gemOrphan = mkGem {
    gemName = "mini_portile2";
    groups = [ ];
  };

  gemNokogiriRuby = mkGem {
    gemName = "nokogiri";
    platform = "ruby";
  };
  gemNokogiriArm = mkGem {
    gemName = "nokogiri";
    platform = "arm64-darwin";
  };
  gemNokogiriX86 = mkGem {
    gemName = "nokogiri";
    platform = "x86_64-darwin";
  };
  gemFfiLinux = mkGem {
    gemName = "ffi";
    platform = "aarch64-linux-gnu";
  };

  # ── filterGroup ──────────────────────────────────────────────

  test_filterGroup_match = assertEq "filterGroup: gem in requested group" (filterGroup [
    "default"
  ] gemRake) true;

  test_filterGroup_no_match = assertEq "filterGroup: gem not in requested groups" (filterGroup [
    "production"
  ] gemRspec) false;

  test_filterGroup_partial_overlap = assertEq "filterGroup: gem with multiple groups, one matches" (
    filterGroup
    [ "production" ]
    gemPuma
  ) true;

  test_filterGroup_empty_gem_groups = assertEq "filterGroup: gem with empty groups excluded" (
    filterGroup
    [ "default" "development" "test" ]
    gemOrphan
  ) false;

  test_filterGroup_empty_requested =
    assertEq "filterGroup: empty requested groups excludes everything" (filterGroup [ ] gemRake)
      false;

  test_filterGroup_multi_request = assertEq "filterGroup: multiple requested groups" (filterGroup [
    "default"
    "test"
  ] gemRspec) true;

  # ── filterPlatform ───────────────────────────────────────────

  test_filterPlatform_ruby_match = assertEq "filterPlatform: ruby gem matches ruby platform" (
    filterPlatform
    [ "ruby" ]
    gemRake
  ) true;

  test_filterPlatform_specific_match = assertEq "filterPlatform: platform-specific gem matches" (
    filterPlatform
    [ "ruby" "arm64-darwin" ]
    gemNokogiriArm
  ) true;

  test_filterPlatform_no_match = assertEq "filterPlatform: gem platform not in requested list" (
    filterPlatform
    [ "ruby" "x86_64-linux" ]
    gemNokogiriArm
  ) false;

  test_filterPlatform_multi_segment =
    assertEq "filterPlatform: multi-segment platform matches exactly"
      (filterPlatform [ "aarch64-linux-gnu" ] gemFfiLinux)
      true;

  test_filterPlatform_empty = assertEq "filterPlatform: empty platform list excludes everything" (
    filterPlatform
    [ ]
    gemRake
  ) false;

  # ── combined filtering ───────────────────────────────────────

  allGems = [
    gemRake
    gemRspec
    gemPuma
    gemOrphan
    gemNokogiriRuby
    gemNokogiriArm
  ];

  test_filter_pipeline =
    let
      groups = [ "default" ];
      platforms = [
        "ruby"
        "arm64-darwin"
      ];
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
    assertEq "filter pipeline: group then platform" names [
      "rake"
      "puma"
      "nokogiri"
      "nokogiri"
    ];

  # ── resolvePlatforms ─────────────────────────────────────────

  # Default preference list for existing tests (aarch64-darwin)
  darwinPrefs = platformsForSystem "aarch64-darwin";

  test_resolve_prefers_specific =
    let
      result = resolvePlatforms darwinPrefs [
        gemNokogiriRuby
        gemNokogiriArm
      ];
    in
    assertEq "resolvePlatforms: prefers platform-specific over ruby" result.nokogiri.platform
      "arm64-darwin";

  test_resolve_ruby_only =
    let
      result = resolvePlatforms darwinPrefs [ gemRake ];
    in
    assertEq "resolvePlatforms: falls back to ruby when only option" result.rake.platform "ruby";

  test_resolve_multiple_specific =
    let
      # both arm64-darwin and x86_64-darwin present: arm64-darwin appears in
      # darwinPrefs, x86_64-darwin does not, so arm64 wins by rank
      result = resolvePlatforms darwinPrefs [
        gemNokogiriArm
        gemNokogiriX86
      ];
    in
    assertEq "resolvePlatforms: picks platform present in preference list" result.nokogiri.platform
      "arm64-darwin";

  test_resolve_mixed_gems =
    let
      # Use a combined prefs list that covers both darwin and linux platforms
      mixedPrefs = [
        "ruby"
        "arm64-darwin"
        "universal-darwin"
        "aarch64-linux-gnu"
      ];
      result = resolvePlatforms mixedPrefs [
        gemRake
        gemNokogiriRuby
        gemNokogiriArm
        gemFfiLinux
      ];
      names = builtins.attrNames result;
    in
    assertEq "resolvePlatforms: groups by name correctly" (builtins.sort builtins.lessThan names) [
      "ffi"
      "nokogiri"
      "rake"
    ]
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
    assertEq "applyGemConfigs: matching gem gets config merged" result.buildFlags [ "--verbose" ];

  test_applyGemConfigs_no_match =
    let
      myConfig = {
        nokogiri = attrs: { buildFlags = [ "--verbose" ]; };
      };
      result = applyGemConfigs myConfig gemRake;
    in
    # rake is not in myConfig, should be returned unchanged
    assertEq "applyGemConfigs: non-matching gem unchanged" (result ? buildFlags) false;

  test_applyGemConfigs_config_receives_attrs =
    let
      # config function that uses the gem's own version
      myConfig = {
        rake = attrs: { description = "rake version ${attrs.version}"; };
      };
      result = applyGemConfigs myConfig gemRake;
    in
    assertEq "applyGemConfigs: config function receives gem attrs" result.description
      "rake version 1.0.0";

  test_applyGemConfigs_empty_config =
    let
      result = applyGemConfigs { } gemRake;
    in
    assertEq "applyGemConfigs: empty config leaves gem unchanged" result.gemName "rake";

  # ── pipeline: resolve platforms before applying gemConfig ─────
  #
  # defaultGemConfig entries (e.g., grpc) contain build/patch instructions
  # for compiling from source (the ruby variant). The correct pipeline is:
  #   filter → resolvePlatforms → applyGemConfigs
  # so that gemConfig is only applied to the winning variant.
  #
  # When a precompiled variant wins (e.g., arm64-darwin), it should NOT
  # receive source-compilation config. When only the ruby variant exists,
  # it should still receive the config.

  # Simulate the grpc defaultGemConfig entry
  grpcConfig = {
    grpc = attrs: {
      postPatch = "substituteInPlace Makefile --replace foo bar";
      buildFlags = [ "--with-system-certs" ];
    };
  };

  # simulates the fixed pipeline: resolve platforms first, then apply gemConfig
  # only to ruby variants (precompiled gems skip it).
  fixedPipeline =
    {
      gems,
      gemConfig,
      requestedGroups ? [ "default" ],
      system ? "aarch64-darwin",
    }:
    let
      platforms = platformsForSystem system;
      afterGroup = builtins.filter (filterGroup requestedGroups) gems;
      afterPlatform = builtins.filter (filterPlatform platforms) afterGroup;
      resolved = resolvePlatforms platforms afterPlatform;
    in
    builtins.mapAttrs (
      name: gem: if gem.platform == "ruby" then applyGemConfigs gemConfig gem else gem
    ) resolved;

  # Negative: precompiled variant wins → gemConfig NOT applied
  test_pipeline_precompiled_skips_gemConfig =
    let
      gems = [
        (mkGem {
          gemName = "grpc";
          platform = "arm64-darwin";
          groups = [ "default" ];
        })
        (mkGem {
          gemName = "grpc";
          platform = "ruby";
          groups = [ "default" ];
        })
      ];
      result = fixedPipeline {
        inherit gems;
        gemConfig = grpcConfig;
      };
    in
    assertEq "pipeline: precompiled grpc wins on aarch64-darwin" result.grpc.platform "arm64-darwin"
    && assertEq "pipeline: precompiled grpc does NOT get postPatch" (result.grpc ? postPatch) false;

  # Positive: ruby-only variant wins → gemConfig IS applied
  test_pipeline_ruby_only_gets_gemConfig =
    let
      gems = [
        (mkGem {
          gemName = "grpc";
          platform = "ruby";
          groups = [ "default" ];
        })
      ];
      result = fixedPipeline {
        inherit gems;
        gemConfig = grpcConfig;
      };
    in
    assertEq "pipeline: ruby grpc wins when only variant" result.grpc.platform "ruby"
    && assertEq "pipeline: ruby grpc gets postPatch" (result.grpc ? postPatch) true;

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
      buggyApply =
        attrs:
        if localConfig ? ${attrs.gemName} then attrs // localConfig.${attrs.gemName} attrs else attrs;

      buggyResult = buggyApply gemRake;
    in
    # The user wanted rake to get { userSupplied = true; } but the local config
    # doesn't have rake, so it passes through unchanged and the user's config is
    # silently lost.
    assertEq "gemConfig shadowing: buggy pattern loses user config" (buggyResult ? userSupplied) false
    # Now verify the correct pattern: applyGemConfigs takes config as a
    # parameter, so we can pass the user's config
    &&
      assertEq "gemConfig shadowing: correct pattern applies user config"
        (applyGemConfigs userConfig gemRake).userSupplied
        true;

  # ── platformsForSystem (#19) ─────────────────────────────────
  #
  # Maps nixpkgs system strings to the Ruby platform strings that should be
  # accepted from a Gemfile.lock. Always includes "ruby" (pure-Ruby gems).

  test_platformsForSystem_aarch64_darwin =
    let
      result = platformsForSystem "aarch64-darwin";
    in
    assertEq "platformsForSystem: aarch64-darwin includes ruby" (builtins.elem "ruby" result) true
    &&
      assertEq "platformsForSystem: aarch64-darwin includes arm64-darwin"
        (builtins.elem "arm64-darwin" result)
        true
    &&
      assertEq "platformsForSystem: aarch64-darwin includes universal-darwin"
        (builtins.elem "universal-darwin" result)
        true;

  test_platformsForSystem_x86_64_darwin =
    let
      result = platformsForSystem "x86_64-darwin";
    in
    assertEq "platformsForSystem: x86_64-darwin includes ruby" (builtins.elem "ruby" result) true
    &&
      assertEq "platformsForSystem: x86_64-darwin includes x86_64-darwin"
        (builtins.elem "x86_64-darwin" result)
        true
    &&
      assertEq "platformsForSystem: x86_64-darwin includes universal-darwin"
        (builtins.elem "universal-darwin" result)
        true
    &&
      assertEq "platformsForSystem: x86_64-darwin does NOT include arm64-darwin"
        (builtins.elem "arm64-darwin" result)
        false;

  test_platformsForSystem_aarch64_linux =
    let
      result = platformsForSystem "aarch64-linux";
    in
    assertEq "platformsForSystem: aarch64-linux includes ruby" (builtins.elem "ruby" result) true
    &&
      assertEq "platformsForSystem: aarch64-linux includes aarch64-linux"
        (builtins.elem "aarch64-linux" result)
        true
    &&
      assertEq "platformsForSystem: aarch64-linux includes aarch64-linux-gnu"
        (builtins.elem "aarch64-linux-gnu" result)
        true
    &&
      assertEq "platformsForSystem: aarch64-linux includes aarch64-linux-musl"
        (builtins.elem "aarch64-linux-musl" result)
        true;

  test_platformsForSystem_x86_64_linux =
    let
      result = platformsForSystem "x86_64-linux";
    in
    assertEq "platformsForSystem: x86_64-linux includes ruby" (builtins.elem "ruby" result) true
    &&
      assertEq "platformsForSystem: x86_64-linux includes x86_64-linux"
        (builtins.elem "x86_64-linux" result)
        true
    &&
      assertEq "platformsForSystem: x86_64-linux includes x86_64-linux-gnu"
        (builtins.elem "x86_64-linux-gnu" result)
        true
    &&
      assertEq "platformsForSystem: x86_64-linux includes x86_64-linux-musl"
        (builtins.elem "x86_64-linux-musl" result)
        true;

  test_platformsForSystem_unknown_throws = assertThrows "platformsForSystem: unknown system throws" (
    platformsForSystem "riscv64-linux"
  );

  # Verify the mapping integrates with filterPlatform end-to-end
  test_platformsForSystem_filter_integration =
    let
      platforms = platformsForSystem "aarch64-darwin";
      # arm64-darwin gem should pass filterPlatform with aarch64-darwin mapping
      passes = filterPlatform platforms gemNokogiriArm;
      # x86_64-darwin gem should NOT pass
      rejects = filterPlatform platforms gemNokogiriX86;
    in
    assertEq "platformsForSystem integration: arm64-darwin gem passes on aarch64-darwin" passes true
    &&
      assertEq "platformsForSystem integration: x86_64-darwin gem rejected on aarch64-darwin" rejects
        false;

  # ── resolvePlatforms preference ordering (#8) ───────────────
  #
  # When both an exact arch match and a compatible match (e.g.,
  # arm64-darwin and universal-darwin) pass the platform filter,
  # resolvePlatforms should prefer the one appearing earlier in
  # the preferredPlatforms list (from platformsForSystem).

  gemNokogiriUniversal = mkGem {
    gemName = "nokogiri";
    platform = "universal-darwin";
  };

  # Scenario: arm64-darwin should win over universal-darwin on aarch64-darwin
  # because platformsForSystem "aarch64-darwin" = ["ruby" "arm64-darwin" "universal-darwin"]
  test_resolve_prefers_exact_over_compatible =
    let
      prefs = platformsForSystem "aarch64-darwin"; # ["ruby" "arm64-darwin" "universal-darwin"]
      # Pass gems in reverse preference order to ensure it's ranking, not insertion order
      result = resolvePlatforms prefs [
        gemNokogiriUniversal
        gemNokogiriArm
      ];
    in
    assertEq "resolvePlatforms: prefers arm64-darwin over universal-darwin on aarch64-darwin"
      result.nokogiri.platform
      "arm64-darwin";

  # Scenario: when only universal-darwin is available (no exact match), it wins over ruby
  test_resolve_compatible_over_ruby =
    let
      prefs = platformsForSystem "aarch64-darwin";
      result = resolvePlatforms prefs [
        gemNokogiriRuby
        gemNokogiriUniversal
      ];
    in
    assertEq "resolvePlatforms: prefers universal-darwin over ruby" result.nokogiri.platform
      "universal-darwin";

  # Scenario: x86_64-darwin should pick x86_64-darwin, not universal-darwin
  test_resolve_x86_prefers_exact =
    let
      prefs = platformsForSystem "x86_64-darwin";
      gemNokogiriX86Universal = mkGem {
        gemName = "nokogiri";
        platform = "universal-darwin";
      };
      result = resolvePlatforms prefs [
        gemNokogiriX86Universal
        gemNokogiriX86
      ];
    in
    assertEq "resolvePlatforms: prefers x86_64-darwin over universal-darwin on x86_64-darwin"
      result.nokogiri.platform
      "x86_64-darwin";

  # ── expandTransitiveDeps ──────────────────────────────────────

  test_expandTransitiveDeps_basic =
    let
      depGraph = {
        nokogiri = [
          "mini_portile2"
          "racc"
        ];
        racc = [ ];
        mini_portile2 = [ ];
      };
      result = expandTransitiveDeps depGraph [ "nokogiri" ];
    in
    assertEq "expandTransitiveDeps: nokogiri pulls in mini_portile2"
      (builtins.elem "mini_portile2" result)
      true
    && assertEq "expandTransitiveDeps: nokogiri pulls in racc" (builtins.elem "racc" result) true
    && assertEq "expandTransitiveDeps: nokogiri itself included" (builtins.elem "nokogiri" result) true;

  test_expandTransitiveDeps_transitive_chain =
    let
      # A depends on B, B depends on C
      depGraph = {
        a = [ "b" ];
        b = [ "c" ];
        c = [ ];
      };
      result = expandTransitiveDeps depGraph [ "a" ];
    in
    assertEq "expandTransitiveDeps: transitive chain A->B->C includes C" (builtins.elem "c" result) true
    && assertEq "expandTransitiveDeps: transitive chain includes B" (builtins.elem "b" result) true
    && assertEq "expandTransitiveDeps: transitive chain includes A" (builtins.elem "a" result) true;

  test_expandTransitiveDeps_no_deps =
    let
      depGraph = {
        rake = [ ];
      };
      result = expandTransitiveDeps depGraph [ "rake" ];
    in
    assertEq "expandTransitiveDeps: no deps is identity" result [ "rake" ];

  test_expandTransitiveDeps_circular =
    let
      # A depends on B, B depends on A
      depGraph = {
        a = [ "b" ];
        b = [ "a" ];
      };
      result = expandTransitiveDeps depGraph [ "a" ];
      sorted = builtins.sort builtins.lessThan result;
    in
    assertEq "expandTransitiveDeps: circular deps converge" sorted [
      "a"
      "b"
    ];

  test_expandTransitiveDeps_unknown_dep_not_added =
    let
      # depGraph only knows about nokogiri; "unknown_gem" not in graph
      depGraph = {
        nokogiri = [ "mini_portile2" ];
      };
      result = expandTransitiveDeps depGraph [ "nokogiri" ];
    in
    # mini_portile2 IS added (it's a dep of nokogiri)
    assertEq "expandTransitiveDeps: dep of known gem is added" (builtins.elem "mini_portile2" result)
      true
    # but only gems reachable from the initial set appear
    && assertEq "expandTransitiveDeps: only reachable gems in result" (builtins.length result) 2;

  test_expandTransitiveDeps_empty_initial =
    let
      depGraph = {
        a = [ "b" ];
      };
      result = expandTransitiveDeps depGraph [ ];
    in
    assertEq "expandTransitiveDeps: empty initial set stays empty" result [ ];

  # ── regression: ruby-only nokogiri drops mini_portile2 ───────
  #
  # When a lockfile has only the `ruby` variant of nokogiri (no precompiled
  # platform gems), platform resolution selects it. The ruby variant needs
  # mini_portile2 to compile, but mini_portile2 gets groups=[] (transitive
  # build dep not in any Gemfile group) and filterGroup drops it.
  #
  # Fixed by expandTransitiveDeps: after group filtering, we expand
  # transitive deps so build-time dependencies like mini_portile2 survive.

  test_ruby_only_nokogiri_keeps_build_deps =
    let
      # Lockfile has only the ruby variant of nokogiri (no arm64-darwin etc.)
      allGems = [
        (mkGem {
          gemName = "nokogiri";
          platform = "ruby";
          groups = [ "default" ];
        })
        (mkGem {
          gemName = "mini_portile2";
          platform = "ruby";
          groups = [ ];
        })
        (mkGem {
          gemName = "racc";
          platform = "ruby";
          groups = [ "default" ];
        })
      ];
      depGraph = {
        nokogiri = [
          "mini_portile2"
          "racc"
        ];
        racc = [ ];
        mini_portile2 = [ ];
      };
      requestedGroups = [ "default" ];
      platforms = platformsForSystem "aarch64-darwin";

      # Step 1: filter by groups
      afterGroup = builtins.filter (filterGroup requestedGroups) allGems;
      afterGroupNames = map (g: g.gemName) afterGroup;

      # Step 2: expand transitive deps to recover filtered-out build deps
      expandedNames = expandTransitiveDeps depGraph afterGroupNames;

      # Step 3: select gems whose names are in the expanded set from the full list
      expandedGems = builtins.filter (g: builtins.elem g.gemName expandedNames) allGems;

      # Step 4: filter by platform and resolve
      afterPlatform = builtins.filter (filterPlatform platforms) expandedGems;
      resolved = resolvePlatforms platforms afterPlatform;
      names = builtins.attrNames resolved;
    in
    # nokogiri must resolve to ruby (only variant available)
    assertEq "ruby-only nokogiri: resolves to ruby platform" resolved.nokogiri.platform "ruby"
    # mini_portile2 must survive filtering, it's needed to build nokogiri
    &&
      assertEq "ruby-only nokogiri: mini_portile2 included for build"
        (builtins.elem "mini_portile2" names)
        true;

  # ── error message prefixes (Phase 4) ─────────────────────────

  test_platformsForSystem_error_lists_supported = assertThrows "platformsForSystem: unsupported system throws with gems4nix prefix and supported list" (
    platformsForSystem "riscv64-linux"
  );

  test_platformsForSystem_error_mips = assertThrows "platformsForSystem: mips throws with clear message" (
    platformsForSystem "mips-linux"
  );

  # ── warnIfNoPlatformGems ────────────────────────────────────

  test_warnIfNoPlatformGems_no_native =
    let
      gems = [
        (mkGem {
          gemName = "rake";
          platform = "ruby";
        })
        (mkGem {
          gemName = "nokogiri";
          platform = "ruby";
        })
      ];
      platforms = [
        "ruby"
        "arm64-darwin"
        "universal-darwin"
      ];
      # warnIfNoPlatformGems should pass through platforms unchanged (warning is a side effect)
      result = filterHelpers.warnIfNoPlatformGems gems platforms;
    in
    assertEq "warnIfNoPlatformGems: returns platforms unchanged when warning fires" result platforms;

  test_warnIfNoPlatformGems_has_native =
    let
      gems = [
        (mkGem {
          gemName = "rake";
          platform = "ruby";
        })
        (mkGem {
          gemName = "nokogiri";
          platform = "arm64-darwin";
        })
      ];
      platforms = [
        "ruby"
        "arm64-darwin"
        "universal-darwin"
      ];
      result = filterHelpers.warnIfNoPlatformGems gems platforms;
    in
    assertEq "warnIfNoPlatformGems: returns platforms when native gems present" result platforms;

  test_warnIfNoPlatformGems_ruby_only_platforms =
    let
      gems = [
        (mkGem {
          gemName = "rake";
          platform = "ruby";
        })
      ];
      platforms = [ "ruby" ];
      result = filterHelpers.warnIfNoPlatformGems gems platforms;
    in
    assertEq "warnIfNoPlatformGems: no warning when only ruby platforms requested" result platforms;

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
    # pipeline: resolve platforms before gemConfig
    && test_pipeline_precompiled_skips_gemConfig
    && test_pipeline_ruby_only_gets_gemConfig
    # critique #9: shadowing
    && test_gemConfig_shadowing_bug
    # critique #8: platform preference ordering
    && test_resolve_prefers_exact_over_compatible
    && test_resolve_compatible_over_ruby
    && test_resolve_x86_prefers_exact
    # critique #19: platformsForSystem
    && test_platformsForSystem_aarch64_darwin
    && test_platformsForSystem_x86_64_darwin
    && test_platformsForSystem_aarch64_linux
    && test_platformsForSystem_x86_64_linux
    && test_platformsForSystem_unknown_throws
    && test_platformsForSystem_filter_integration
    # expandTransitiveDeps
    && test_expandTransitiveDeps_basic
    && test_expandTransitiveDeps_transitive_chain
    && test_expandTransitiveDeps_no_deps
    && test_expandTransitiveDeps_circular
    && test_expandTransitiveDeps_unknown_dep_not_added
    && test_expandTransitiveDeps_empty_initial
    # regression: ruby-only nokogiri keeps build deps (was quarantined)
    && test_ruby_only_nokogiri_keeps_build_deps
    # error message prefixes (Phase 4)
    && test_platformsForSystem_error_lists_supported
    && test_platformsForSystem_error_mips
    # warnIfNoPlatformGems
    && test_warnIfNoPlatformGems_no_native
    && test_warnIfNoPlatformGems_has_native
    && test_warnIfNoPlatformGems_ruby_only_platforms;

in
allTests
