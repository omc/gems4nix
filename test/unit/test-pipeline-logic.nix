# Unit tests for pipeline: full pipeline from lockfile content to
# resolved gems per system.
#
# Accepts { lib }: so it can be imported by both:
#   - The standalone wrapper (test-pipeline.nix) for `nix eval --file` usage
#   - The root flake.nix checks via `import ./test-pipeline-logic.nix { lib = pkgs.lib; }`
#
# Tests the FULL pipeline: parseLockfile -> filterPlatform -> resolvePlatforms
# across all 4 systems with realistic synthetic lockfile data.
#
# Returns: true (all assertions pass) or throws with a descriptive message.

{ lib }:

let
  parserHelpers = import ../../lib/gemfile-env/parse.nix { inherit lib; };
  filterHelpers = import ../../lib/gemfile-env/resolve.nix { inherit lib; };
  inherit (parserHelpers)
    parseLockfile
    indexRemotes
    mergeGemMetadata
    parseDependencies
    ;
  inherit (filterHelpers)
    filterGroup
    filterPlatform
    resolvePlatforms
    platformsForSystem
    expandTransitiveDeps
    ;
  inherit (import ../helpers.nix) assertEq assertThrows;

  # ── synthetic lockfile: nokogiri + ffi + grpc (old-style bare platforms) ──
  #
  # This simulates a lockfile with:
  #   - nokogiri: all standard platform variants
  #   - ffi: all standard platform variants
  #   - grpc (v1.73): OLD-STYLE bare platform names (aarch64-linux, x86_64-linux)
  #   - rake: ruby-only (control gem)

  syntheticLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        ffi (1.17.3)
        ffi (1.17.3-aarch64-linux-gnu)
        ffi (1.17.3-aarch64-linux-musl)
        ffi (1.17.3-arm64-darwin)
        ffi (1.17.3-x86_64-darwin)
        ffi (1.17.3-x86_64-linux-gnu)
        ffi (1.17.3-x86_64-linux-musl)
        grpc (1.73.0)
        grpc (1.73.0-aarch64-linux)
        grpc (1.73.0-x86_64-linux)
        grpc (1.73.0-arm64-darwin)
        grpc (1.73.0-x86_64-darwin)
        nokogiri (1.19.2)
          mini_portile2 (~> 2.8.2)
          racc (~> 1.4)
        nokogiri (1.19.2-aarch64-linux-gnu)
          racc (~> 1.4)
        nokogiri (1.19.2-aarch64-linux-musl)
          racc (~> 1.4)
        nokogiri (1.19.2-arm64-darwin)
          racc (~> 1.4)
        nokogiri (1.19.2-x86_64-darwin)
          racc (~> 1.4)
        nokogiri (1.19.2-x86_64-linux-gnu)
          racc (~> 1.4)
        nokogiri (1.19.2-x86_64-linux-musl)
          racc (~> 1.4)
        rake (13.2.1)

    PLATFORMS
      aarch64-linux-gnu
      aarch64-linux-musl
      arm64-darwin
      ruby
      x86_64-darwin
      x86_64-linux-gnu
      x86_64-linux-musl

    CHECKSUMS
      ffi (1.17.3) sha256=aaa0000000000000000000000000000000000000000000000000000000000001
      ffi (1.17.3-aarch64-linux-gnu) sha256=aaa0000000000000000000000000000000000000000000000000000000000002
      ffi (1.17.3-aarch64-linux-musl) sha256=aaa0000000000000000000000000000000000000000000000000000000000003
      ffi (1.17.3-arm64-darwin) sha256=aaa0000000000000000000000000000000000000000000000000000000000004
      ffi (1.17.3-x86_64-darwin) sha256=aaa0000000000000000000000000000000000000000000000000000000000005
      ffi (1.17.3-x86_64-linux-gnu) sha256=aaa0000000000000000000000000000000000000000000000000000000000006
      ffi (1.17.3-x86_64-linux-musl) sha256=aaa0000000000000000000000000000000000000000000000000000000000007
      grpc (1.73.0) sha256=bbb0000000000000000000000000000000000000000000000000000000000001
      grpc (1.73.0-aarch64-linux) sha256=bbb0000000000000000000000000000000000000000000000000000000000002
      grpc (1.73.0-x86_64-linux) sha256=bbb0000000000000000000000000000000000000000000000000000000000003
      grpc (1.73.0-arm64-darwin) sha256=bbb0000000000000000000000000000000000000000000000000000000000004
      grpc (1.73.0-x86_64-darwin) sha256=bbb0000000000000000000000000000000000000000000000000000000000005
      nokogiri (1.19.2) sha256=ccc0000000000000000000000000000000000000000000000000000000000001
      nokogiri (1.19.2-aarch64-linux-gnu) sha256=ccc0000000000000000000000000000000000000000000000000000000000002
      nokogiri (1.19.2-aarch64-linux-musl) sha256=ccc0000000000000000000000000000000000000000000000000000000000003
      nokogiri (1.19.2-arm64-darwin) sha256=ccc0000000000000000000000000000000000000000000000000000000000004
      nokogiri (1.19.2-x86_64-darwin) sha256=ccc0000000000000000000000000000000000000000000000000000000000005
      nokogiri (1.19.2-x86_64-linux-gnu) sha256=ccc0000000000000000000000000000000000000000000000000000000000006
      nokogiri (1.19.2-x86_64-linux-musl) sha256=ccc0000000000000000000000000000000000000000000000000000000000007
      rake (13.2.1) sha256=ddd0000000000000000000000000000000000000000000000000000000000001

    BUNDLED WITH
       2.5.22
  '';

  # ── synthetic lockfile: grpc new-style (aarch64-linux-gnu) ──
  #
  # Simulates grpc >= 1.74 which uses -gnu/-musl suffixed platform names.

  grpcNewStyleLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        grpc (1.74.0)
        grpc (1.74.0-aarch64-linux-gnu)
        grpc (1.74.0-aarch64-linux-musl)
        grpc (1.74.0-x86_64-linux-gnu)
        grpc (1.74.0-x86_64-linux-musl)
        grpc (1.74.0-arm64-darwin)
        grpc (1.74.0-x86_64-darwin)

    PLATFORMS
      aarch64-linux-gnu
      aarch64-linux-musl
      arm64-darwin
      ruby
      x86_64-darwin
      x86_64-linux-gnu
      x86_64-linux-musl

    CHECKSUMS
      grpc (1.74.0) sha256=eee0000000000000000000000000000000000000000000000000000000000001
      grpc (1.74.0-aarch64-linux-gnu) sha256=eee0000000000000000000000000000000000000000000000000000000000002
      grpc (1.74.0-aarch64-linux-musl) sha256=eee0000000000000000000000000000000000000000000000000000000000003
      grpc (1.74.0-x86_64-linux-gnu) sha256=eee0000000000000000000000000000000000000000000000000000000000004
      grpc (1.74.0-x86_64-linux-musl) sha256=eee0000000000000000000000000000000000000000000000000000000000005
      grpc (1.74.0-arm64-darwin) sha256=eee0000000000000000000000000000000000000000000000000000000000006
      grpc (1.74.0-x86_64-darwin) sha256=eee0000000000000000000000000000000000000000000000000000000000007

    BUNDLED WITH
       2.5.22
  '';

  # ── synthetic lockfile: grpc with BOTH bare and -gnu (preference test) ──
  #
  # This is a hypothetical lockfile containing both aarch64-linux AND
  # aarch64-linux-gnu for the same gem. Tests that bare wins because it
  # appears earlier in platformsForSystem.

  grpcBothStylesLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        grpc (1.73.99)
        grpc (1.73.99-aarch64-linux)
        grpc (1.73.99-aarch64-linux-gnu)
        grpc (1.73.99-x86_64-linux)
        grpc (1.73.99-x86_64-linux-gnu)
        grpc (1.73.99-arm64-darwin)
        grpc (1.73.99-x86_64-darwin)

    PLATFORMS
      aarch64-linux
      aarch64-linux-gnu
      arm64-darwin
      ruby
      x86_64-darwin
      x86_64-linux
      x86_64-linux-gnu

    CHECKSUMS
      grpc (1.73.99) sha256=fff0000000000000000000000000000000000000000000000000000000000001
      grpc (1.73.99-aarch64-linux) sha256=fff0000000000000000000000000000000000000000000000000000000000002
      grpc (1.73.99-aarch64-linux-gnu) sha256=fff0000000000000000000000000000000000000000000000000000000000003
      grpc (1.73.99-x86_64-linux) sha256=fff0000000000000000000000000000000000000000000000000000000000004
      grpc (1.73.99-x86_64-linux-gnu) sha256=fff0000000000000000000000000000000000000000000000000000000000005
      grpc (1.73.99-arm64-darwin) sha256=fff0000000000000000000000000000000000000000000000000000000000006
      grpc (1.73.99-x86_64-darwin) sha256=fff0000000000000000000000000000000000000000000000000000000000007

    BUNDLED WITH
       2.5.22
  '';

  # ── synthetic lockfile: ruby-only gem (no platform variants) ──
  #
  # Tests that a gem with only the ruby variant is correctly selected.

  rubyOnlyLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        httparty (0.22.0)

    PLATFORMS
      ruby

    CHECKSUMS
      httparty (0.22.0) sha256=ggg0000000000000000000000000000000000000000000000000000000000001

    BUNDLED WITH
       2.5.22
  '';

  # ── helpers: run the full pipeline for a given lockfile and system ──

  # Simulate gemGroups: all gems in "default" group.
  # Note: real group assignment comes from gem-groups.rb (a Ruby script run via
  # runCommand in parse-gemfile-and-lockfile.nix). This pure-Nix test cannot
  # exercise that IO boundary; it synthesizes groups to test the platform
  # resolution pipeline in isolation. Group parsing coverage is provided by
  # the integration test (which runs the full gemfileEnv pipeline with real
  # Gemfile/Gemfile.lock) and by the filterGroup unit tests in test-resolve-logic.nix.
  defaultGroups =
    checksumSection:
    builtins.listToAttrs (
      map (gem: {
        name = gem.gemName;
        value = [ "default" ];
      }) checksumSection
    );

  runPipeline =
    { lockfileContent, system }:
    let
      parsed = parseLockfile lockfileContent;
      gemRemotes = indexRemotes parsed.gemSections;
      gemGroups = defaultGroups parsed.checksumSection;
      gems = mergeGemMetadata {
        inherit (parsed) checksumSection;
        inherit gemRemotes gemGroups;
      };
      platforms = platformsForSystem system;
      afterGroup = builtins.filter (filterGroup [ "default" ]) gems;
      afterPlatform = builtins.filter (filterPlatform platforms) afterGroup;
      resolved = resolvePlatforms platforms afterPlatform;
    in
    resolved;

  # ── main lockfile tests: nokogiri, ffi, grpc (old-style) ────

  # aarch64-darwin
  resultAarch64Darwin = runPipeline {
    lockfileContent = syntheticLockfile;
    system = "aarch64-darwin";
  };

  test_aarch64_darwin_nokogiri =
    assertEq "aarch64-darwin: nokogiri resolves to arm64-darwin" resultAarch64Darwin.nokogiri.platform
      "arm64-darwin";

  test_aarch64_darwin_ffi =
    assertEq "aarch64-darwin: ffi resolves to arm64-darwin" resultAarch64Darwin.ffi.platform
      "arm64-darwin";

  test_aarch64_darwin_grpc =
    assertEq "aarch64-darwin: grpc (old-style) resolves to arm64-darwin"
      resultAarch64Darwin.grpc.platform
      "arm64-darwin";

  test_aarch64_darwin_rake =
    assertEq "aarch64-darwin: rake stays ruby" resultAarch64Darwin.rake.platform
      "ruby";

  # aarch64-linux
  resultAarch64Linux = runPipeline {
    lockfileContent = syntheticLockfile;
    system = "aarch64-linux";
  };

  test_aarch64_linux_nokogiri =
    assertEq "aarch64-linux: nokogiri resolves to aarch64-linux-gnu"
      resultAarch64Linux.nokogiri.platform
      "aarch64-linux-gnu";

  test_aarch64_linux_ffi =
    assertEq "aarch64-linux: ffi resolves to aarch64-linux-gnu" resultAarch64Linux.ffi.platform
      "aarch64-linux-gnu";

  test_aarch64_linux_grpc_old_style =
    assertEq "aarch64-linux: grpc (old-style bare) resolves to aarch64-linux"
      resultAarch64Linux.grpc.platform
      "aarch64-linux";

  test_aarch64_linux_rake =
    assertEq "aarch64-linux: rake stays ruby" resultAarch64Linux.rake.platform
      "ruby";

  # x86_64-darwin
  resultX8664Darwin = runPipeline {
    lockfileContent = syntheticLockfile;
    system = "x86_64-darwin";
  };

  test_x86_64_darwin_nokogiri =
    assertEq "x86_64-darwin: nokogiri resolves to x86_64-darwin" resultX8664Darwin.nokogiri.platform
      "x86_64-darwin";

  test_x86_64_darwin_ffi =
    assertEq "x86_64-darwin: ffi resolves to x86_64-darwin" resultX8664Darwin.ffi.platform
      "x86_64-darwin";

  test_x86_64_darwin_grpc =
    assertEq "x86_64-darwin: grpc (old-style) resolves to x86_64-darwin" resultX8664Darwin.grpc.platform
      "x86_64-darwin";

  test_x86_64_darwin_rake =
    assertEq "x86_64-darwin: rake stays ruby" resultX8664Darwin.rake.platform
      "ruby";

  # x86_64-linux
  resultX8664Linux = runPipeline {
    lockfileContent = syntheticLockfile;
    system = "x86_64-linux";
  };

  test_x86_64_linux_nokogiri =
    assertEq "x86_64-linux: nokogiri resolves to x86_64-linux-gnu" resultX8664Linux.nokogiri.platform
      "x86_64-linux-gnu";

  test_x86_64_linux_ffi =
    assertEq "x86_64-linux: ffi resolves to x86_64-linux-gnu" resultX8664Linux.ffi.platform
      "x86_64-linux-gnu";

  test_x86_64_linux_grpc_old_style =
    assertEq "x86_64-linux: grpc (old-style bare) resolves to x86_64-linux"
      resultX8664Linux.grpc.platform
      "x86_64-linux";

  test_x86_64_linux_rake =
    assertEq "x86_64-linux: rake stays ruby" resultX8664Linux.rake.platform
      "ruby";

  # ── grpc new-style tests (>= 1.74, -gnu suffixed) ──────────

  resultGrpcNewAarch64Linux = runPipeline {
    lockfileContent = grpcNewStyleLockfile;
    system = "aarch64-linux";
  };

  test_grpc_new_style_aarch64_linux =
    assertEq "aarch64-linux: grpc (new-style -gnu) resolves to aarch64-linux-gnu"
      resultGrpcNewAarch64Linux.grpc.platform
      "aarch64-linux-gnu";

  resultGrpcNewX8664Linux = runPipeline {
    lockfileContent = grpcNewStyleLockfile;
    system = "x86_64-linux";
  };

  test_grpc_new_style_x86_64_linux =
    assertEq "x86_64-linux: grpc (new-style -gnu) resolves to x86_64-linux-gnu"
      resultGrpcNewX8664Linux.grpc.platform
      "x86_64-linux-gnu";

  resultGrpcNewAarch64Darwin = runPipeline {
    lockfileContent = grpcNewStyleLockfile;
    system = "aarch64-darwin";
  };

  test_grpc_new_style_aarch64_darwin =
    assertEq "aarch64-darwin: grpc (new-style) resolves to arm64-darwin"
      resultGrpcNewAarch64Darwin.grpc.platform
      "arm64-darwin";

  resultGrpcNewX8664Darwin = runPipeline {
    lockfileContent = grpcNewStyleLockfile;
    system = "x86_64-darwin";
  };

  test_grpc_new_style_x86_64_darwin =
    assertEq "x86_64-darwin: grpc (new-style) resolves to x86_64-darwin"
      resultGrpcNewX8664Darwin.grpc.platform
      "x86_64-darwin";

  # ── grpc preference test: bare vs -gnu (when both present) ──

  resultGrpcBothAarch64Linux = runPipeline {
    lockfileContent = grpcBothStylesLockfile;
    system = "aarch64-linux";
  };

  test_grpc_both_aarch64_linux_prefers_bare =
    assertEq "aarch64-linux: grpc prefers bare aarch64-linux over aarch64-linux-gnu"
      resultGrpcBothAarch64Linux.grpc.platform
      "aarch64-linux";

  resultGrpcBothX8664Linux = runPipeline {
    lockfileContent = grpcBothStylesLockfile;
    system = "x86_64-linux";
  };

  test_grpc_both_x86_64_linux_prefers_bare =
    assertEq "x86_64-linux: grpc prefers bare x86_64-linux over x86_64-linux-gnu"
      resultGrpcBothX8664Linux.grpc.platform
      "x86_64-linux";

  # ── ruby fallback: gem with no platform-specific variants ───

  resultRubyOnlyAarch64Darwin = runPipeline {
    lockfileContent = rubyOnlyLockfile;
    system = "aarch64-darwin";
  };

  test_ruby_fallback_aarch64_darwin =
    assertEq "aarch64-darwin: ruby-only gem correctly selects ruby"
      resultRubyOnlyAarch64Darwin.httparty.platform
      "ruby";

  resultRubyOnlyAarch64Linux = runPipeline {
    lockfileContent = rubyOnlyLockfile;
    system = "aarch64-linux";
  };

  test_ruby_fallback_aarch64_linux =
    assertEq "aarch64-linux: ruby-only gem correctly selects ruby"
      resultRubyOnlyAarch64Linux.httparty.platform
      "ruby";

  # ── ruby NOT selected when platform-specific exists ─────────

  test_ruby_not_selected_when_specific_exists_darwin =
    assertEq "aarch64-darwin: ruby variant NOT selected for nokogiri (platform-specific exists)"
      (resultAarch64Darwin.nokogiri.platform != "ruby")
      true;

  test_ruby_not_selected_when_specific_exists_linux =
    assertEq "aarch64-linux: ruby variant NOT selected for ffi (platform-specific exists)"
      (resultAarch64Linux.ffi.platform != "ruby")
      true;

  # ── gemConfig-skipping pipeline ─────────────────────────────
  #
  # Precompiled gems should NOT receive defaultGemConfig (which contains
  # source-compilation instructions). Ruby-only gems SHOULD receive it.

  grpcConfig = {
    grpc = attrs: {
      postPatch = "substituteInPlace Makefile --replace foo bar";
      buildFlags = [ "--with-system-certs" ];
    };
  };

  test_pipeline_precompiled_skips_gemConfig =
    let
      resolved = resultAarch64Darwin;
      # Simulate the pipeline: only apply gemConfig to ruby variants
      configured = builtins.mapAttrs (
        name: gem: if gem.platform == "ruby" then filterHelpers.applyGemConfigs grpcConfig gem else gem
      ) resolved;
    in
    # grpc on aarch64-darwin resolves to arm64-darwin (precompiled), so no gemConfig
    assertEq "pipeline: precompiled grpc does NOT get postPatch" (configured.grpc ? postPatch) false
    # rake is ruby, it would get gemConfig if there was a rake entry, but there isn't
    && assertEq "pipeline: rake stays ruby and unchanged" configured.rake.platform "ruby";

  test_pipeline_ruby_only_gets_gemConfig =
    let
      # Use the ruby-only lockfile scenario: no platform-specific variants
      rubyOnlyGrpcLockfile = ''
        GEM
          remote: https://rubygems.org/
          specs:
            grpc (1.73.0)

        PLATFORMS
          ruby

        CHECKSUMS
          grpc (1.73.0) sha256=bbb0000000000000000000000000000000000000000000000000000000000001

        BUNDLED WITH
           2.5.22
      '';
      resolved = runPipeline {
        lockfileContent = rubyOnlyGrpcLockfile;
        system = "aarch64-darwin";
      };
      configured = builtins.mapAttrs (
        name: gem: if gem.platform == "ruby" then filterHelpers.applyGemConfigs grpcConfig gem else gem
      ) resolved;
    in
    assertEq "pipeline: ruby grpc gets postPatch" (configured.grpc ? postPatch) true
    && assertEq "pipeline: ruby grpc platform is ruby" configured.grpc.platform "ruby";

  # ── dependency expansion pipeline test ──────────────────────
  #
  # Exercises parseDependencies + expandTransitiveDeps in the pipeline.
  # mini_portile2 has groups=[] (build-only dep), gets filtered by groups,
  # but dep expansion recovers it because nokogiri depends on it.

  depExpansionLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        nokogiri (1.19.2)
          mini_portile2 (~> 2.8.2)
          racc (~> 1.4)
        mini_portile2 (2.8.9)
        racc (1.8.1)

    PLATFORMS
      ruby

    CHECKSUMS
      mini_portile2 (2.8.9) sha256=aaa0000000000000000000000000000000000000000000000000000000000001
      nokogiri (1.19.2) sha256=aaa0000000000000000000000000000000000000000000000000000000000002
      racc (1.8.1) sha256=aaa0000000000000000000000000000000000000000000000000000000000003

    DEPENDENCIES
      nokogiri (~> 1.19)

    BUNDLED WITH
       2.5.22
  '';

  test_pipeline_dep_expansion =
    let
      parsed = parseLockfile depExpansionLockfile;
      lines = lib.splitString "\n" depExpansionLockfile;
      depGraph = parseDependencies lines;
      gemRemotes = indexRemotes parsed.gemSections;
      # Only nokogiri is in the "default" group (it's in DEPENDENCIES).
      # mini_portile2 and racc are build deps with no group.
      gemGroups = {
        nokogiri = [ "default" ];
      };
      gems = mergeGemMetadata {
        inherit (parsed) checksumSection;
        inherit gemRemotes gemGroups;
      };
      platforms = platformsForSystem "aarch64-darwin";

      # Step 1: group filter removes mini_portile2 and racc (groups=[])
      afterGroup = builtins.filter (filterGroup [ "default" ]) gems;
      afterGroupNames = map (g: g.gemName) afterGroup;

      # Step 2: expand transitive deps — recovers mini_portile2 and racc
      survivingNames = map (g: g.gemName) afterGroup;
      expandedNames = expandTransitiveDeps depGraph survivingNames;
      # Re-include gems that were filtered out but are needed as deps
      allGemsByName = builtins.listToAttrs (
        map (g: {
          name = g.gemName;
          value = g;
        }) gems
      );
      afterExpansion = map (n: allGemsByName.${n}) (
        builtins.filter (n: allGemsByName ? ${n}) expandedNames
      );

      afterPlatform = builtins.filter (filterPlatform platforms) afterExpansion;
      resolved = resolvePlatforms platforms afterPlatform;
      names = builtins.attrNames resolved;
    in
    # mini_portile2 was NOT in any group, but dep expansion recovered it
    assertEq "dep expansion: mini_portile2 recovered after group filtering"
      (builtins.elem "mini_portile2" names)
      true
    && assertEq "dep expansion: racc recovered after group filtering" (builtins.elem "racc" names) true
    && assertEq "dep expansion: nokogiri present" (builtins.elem "nokogiri" names) true
    # Verify group filtering alone would have dropped them
    &&
      assertEq "dep expansion: group filter alone drops mini_portile2"
        (builtins.elem "mini_portile2" afterGroupNames)
        false;

  # ── all tests ────────────────────────────────────────────────

  allTests =
    # main lockfile: aarch64-darwin
    test_aarch64_darwin_nokogiri
    && test_aarch64_darwin_ffi
    && test_aarch64_darwin_grpc
    && test_aarch64_darwin_rake
    # main lockfile: aarch64-linux
    && test_aarch64_linux_nokogiri
    && test_aarch64_linux_ffi
    && test_aarch64_linux_grpc_old_style
    && test_aarch64_linux_rake
    # main lockfile: x86_64-darwin
    && test_x86_64_darwin_nokogiri
    && test_x86_64_darwin_ffi
    && test_x86_64_darwin_grpc
    && test_x86_64_darwin_rake
    # main lockfile: x86_64-linux
    && test_x86_64_linux_nokogiri
    && test_x86_64_linux_ffi
    && test_x86_64_linux_grpc_old_style
    && test_x86_64_linux_rake
    # grpc new-style (-gnu suffixed)
    && test_grpc_new_style_aarch64_linux
    && test_grpc_new_style_x86_64_linux
    && test_grpc_new_style_aarch64_darwin
    && test_grpc_new_style_x86_64_darwin
    # grpc preference: bare vs -gnu
    && test_grpc_both_aarch64_linux_prefers_bare
    && test_grpc_both_x86_64_linux_prefers_bare
    # ruby fallback
    && test_ruby_fallback_aarch64_darwin
    && test_ruby_fallback_aarch64_linux
    # ruby NOT selected when specific exists
    && test_ruby_not_selected_when_specific_exists_darwin
    && test_ruby_not_selected_when_specific_exists_linux
    # gemConfig pipeline
    && test_pipeline_precompiled_skips_gemConfig
    && test_pipeline_ruby_only_gets_gemConfig
    # dependency expansion pipeline
    && test_pipeline_dep_expansion;

in
allTests
