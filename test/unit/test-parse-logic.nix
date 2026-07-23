# Unit tests for parse.nix (logic only, no fetchTarball)
#
# Accepts { lib }: so it can be imported by both:
#   - The standalone wrapper (test-parse.nix) for `nix eval --file` usage
#   - The root flake.nix checks via `import ./test-parse-logic.nix { lib = pkgs.lib; }`
#
# Returns: true (all assertions pass) or throws with a descriptive message.

{ lib }:

let
  helpers = import ../../lib/gemfile-env/parse.nix { inherit lib; };
  inherit (helpers)
    findIndices
    takeLines
    knownPlatforms
    splitVersionPlatform
    parseChecksumLine
    parseGemSection
    parseDependencies
    parseDependenciesSection
    takeDependenciesSection
    parseLockfile
    indexRemotes
    mergeGemMetadata
    ;
  inherit (import ../helpers.nix) assertEq assertThrows;

  # ── findIndices ──────────────────────────────────────────────

  test_findIndices_multiple =
    assertEq "findIndices: multiple matches"
      (findIndices (x: x == "GEM") [
        "GEM"
        "foo"
        "bar"
        "GEM"
        "baz"
      ])
      [
        0
        3
      ];

  test_findIndices_none = assertEq "findIndices: no matches" (findIndices (x: x == "NOPE") [
    "GEM"
    "foo"
    "bar"
  ]) [ ];

  test_findIndices_single = assertEq "findIndices: single match" (findIndices (x: x == "bar") [
    "foo"
    "bar"
    "baz"
  ]) [ 1 ];

  # ── takeLines ────────────────────────────────────────────────

  test_takeLines_basic =
    assertEq "takeLines: lines until blank"
      (takeLines 0 [
        "HEADER"
        "  line1"
        "  line2"
        ""
        "  line3"
      ])
      [
        "  line1"
        "  line2"
      ];

  test_takeLines_no_blank =
    assertEq "takeLines: no blank line (runs to end)"
      (takeLines 0 [
        "HEADER"
        "a"
        "b"
        "c"
      ])
      [
        "a"
        "b"
        "c"
      ];

  test_takeLines_immediate_blank = assertEq "takeLines: blank immediately after header" (takeLines 0 [
    "HEADER"
    ""
    "stuff"
  ]) [ ];

  test_takeLines_offset =
    assertEq "takeLines: with offset"
      (takeLines 2 [
        "skip"
        "skip"
        "HEADER"
        "  a"
        "  b"
        ""
        "  c"
      ])
      [
        "  a"
        "  b"
      ];

  # ── parseChecksumLine: happy path ────────────────────────────

  test_parseChecksum_simple =
    let
      result = parseChecksumLine "  zeitwerk (2.7.2) sha256=842e067cb11eb923d747249badfb5fcdc9652d6f20a1f06453317920fdcd4673";
    in
    assertEq "parseChecksumLine: simple gem - gemName" result.gemName "zeitwerk"
    && assertEq "parseChecksumLine: simple gem - version" result.version "2.7.2"
    && assertEq "parseChecksumLine: simple gem - platform" result.platform "ruby"
    &&
      assertEq "parseChecksumLine: simple gem - sha256" result.source.sha256
        "842e067cb11eb923d747249badfb5fcdc9652d6f20a1f06453317920fdcd4673";

  test_parseChecksum_platform =
    let
      result = parseChecksumLine "  nokogiri (1.18.8-arm64-darwin) sha256=483b5b9fb33653f6f05cbe00d09ea315f268f0e707cfc809aa39b62993008212";
    in
    assertEq "parseChecksumLine: platform gem - gemName" result.gemName "nokogiri"
    && assertEq "parseChecksumLine: platform gem - version" result.version "1.18.8"
    && assertEq "parseChecksumLine: platform gem - platform" result.platform "arm64-darwin"
    &&
      assertEq "parseChecksumLine: platform gem - sha256" result.source.sha256
        "483b5b9fb33653f6f05cbe00d09ea315f268f0e707cfc809aa39b62993008212";

  test_parseChecksum_multi_segment_platform =
    let
      result = parseChecksumLine "  ffi (1.17.2-aarch64-linux-gnu) sha256=c910bd3cae70b76690418cce4572b7f6c208d271f323d692a067d59116211a1a";
    in
    assertEq "parseChecksumLine: multi-segment platform - gemName" result.gemName "ffi"
    && assertEq "parseChecksumLine: multi-segment platform - version" result.version "1.17.2"
    &&
      assertEq "parseChecksumLine: multi-segment platform - platform" result.platform
        "aarch64-linux-gnu"
    &&
      assertEq "parseChecksumLine: multi-segment platform - sha256" result.source.sha256
        "c910bd3cae70b76690418cce4572b7f6c208d271f323d692a067d59116211a1a";

  # ── parseChecksumLine: malformed input (recommendation #1) ──

  # Git/path gems appear in CHECKSUMS without a hash; parseChecksumLine
  # returns null for these so the caller can filter them out.
  test_parseChecksum_missing_hash_returns_null =
    assertEq "parseChecksumLine: missing hash returns null (git/path gem)"
      (parseChecksumLine "  errgonomic (0.5.1)")
      null;

  test_parseChecksum_extra_leading_spaces = assertThrows "parseChecksumLine: extra leading spaces should throw a helpful error" (
    parseChecksumLine "    zeitwerk (2.6.18) sha256=abc123"
  );

  test_parseChecksum_empty_line_returns_null =
    assertEq "parseChecksumLine: empty line returns null" (parseChecksumLine "")
      null;

  # ── parseGemSection ──────────────────────────────────────────

  test_parseGemSection_basic =
    let
      result = parseGemSection [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    abbrev (0.1.2)"
        "    zeitwerk (2.7.2)"
      ];
    in
    assertEq "parseGemSection: remote (trailing slash stripped)" result.remote "https://rubygems.org"
    && assertEq "parseGemSection: gems list" result.gems [
      "abbrev"
      "zeitwerk"
    ];

  test_parseGemSection_no_trailing_slash =
    let
      result = parseGemSection [
        "  remote: https://rubygems.pkg.github.com/omc"
        "  specs:"
        "    depot (1.4.0)"
      ];
    in
    assertEq "parseGemSection: remote without trailing slash" result.remote
      "https://rubygems.pkg.github.com/omc"
    && assertEq "parseGemSection: gems from private remote" result.gems [ "depot" ];

  test_parseGemSection_deps_included =
    let
      result = parseGemSection [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    actioncable (8.0.2)"
        "      actionpack (= 8.0.2)"
        "      activesupport (= 8.0.2)"
        "    zeitwerk (2.7.2)"
      ];
    in
    # dependency lines are included; parseGemSection does not distinguish indent levels.
    assertEq "parseGemSection: dependency lines included (current behavior)" result.gems [
      "actioncable"
      "actionpack"
      "activesupport"
      "zeitwerk"
    ];

  # ── parseLockfile ─────────────────────────────────────

  minimalLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)
        zeitwerk (2.7.2)

    PLATFORMS
      ruby

    CHECKSUMS
      rake (13.0.6) sha256=aaaa
      zeitwerk (2.7.2) sha256=bbbb

    BUNDLED WITH
       2.5.22
  '';

  test_parseLockfile =
    let
      result = parseLockfile minimalLockfile;
    in
    assertEq "parseLockfile: checksumSection length" (builtins.length result.checksumSection) 2
    &&
      assertEq "parseLockfile: first checksum gemName" (builtins.elemAt result.checksumSection 0).gemName
        "rake"
    && assertEq "parseLockfile: gemSections length" (builtins.length result.gemSections) 1
    &&
      assertEq "parseLockfile: first section remote" (builtins.elemAt result.gemSections 0).remote
        "https://rubygems.org";

  test_parseLockfile_missing_checksums = assertThrows "parseLockfile: missing CHECKSUMS throws" (parseLockfile ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    PLATFORMS
      ruby
  '');

  multiRemoteLockfile = ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    GEM
      remote: https://private.example.com/
      specs:
        mygem (1.0.0)

    CHECKSUMS
      rake (13.0.6) sha256=aaaa
      mygem (1.0.0) sha256=bbbb
  '';

  test_parseLockfile_multi_remote =
    let
      result = parseLockfile multiRemoteLockfile;
    in
    assertEq "parseLockfile: multi-remote gemSections count" (builtins.length result.gemSections) 2;

  # ── parseLockfile: missing GEM section (critique #5) ──

  test_parseLockfile_missing_gem_section = assertThrows "parseLockfile: missing GEM section throws" (parseLockfile ''
    CHECKSUMS
      rake (13.0.6) sha256=aaaa

    BUNDLED WITH
       2.5.22
  '');

  # A lockfile with CHECKSUMS but a completely empty GEM section (no specs)
  test_parseLockfile_empty_gem_specs =
    let
      result = parseLockfile ''
        GEM
          remote: https://rubygems.org/
          specs:

        CHECKSUMS

        BUNDLED WITH
           2.5.22
      '';
    in
    # empty CHECKSUMS = no gems parsed, and an empty GEM section is valid
    assertEq "parseLockfile: empty gem specs returns empty checksumSection"
      (builtins.length result.checksumSection)
      0
    &&
      assertEq "parseLockfile: empty gem specs still has one gemSection"
        (builtins.length result.gemSections)
        1;

  # ── parseLockfile: git/path gems skipped ─────────────

  gitPathLockfile = ''
    GIT
      remote: https://github.com/omc/errgonomic.git
      revision: abc123
      branch: main
      specs:
        errgonomic (0.5.1)

    PATH
      remote: vendor/hello_gem
      specs:
        hello_gem (0.1.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    CHECKSUMS
      errgonomic (0.5.1)
      hello_gem (0.1.0)
      rake (13.0.6) sha256=aaaa
  '';

  test_parseLockfile_skips_hashless =
    let
      result = parseLockfile gitPathLockfile;
    in
    # Only rake (with a hash) survives; errgonomic and hello_gem are filtered out
    assertEq "parseLockfile: git/path gems filtered from checksumSection"
      (builtins.length result.checksumSection)
      1
    &&
      assertEq "parseLockfile: surviving gem is rake" (builtins.elemAt result.checksumSection 0).gemName
        "rake";

  # ── indexRemotes ──────────────────────────────────────────

  test_indexRemotes =
    let
      sections = [
        {
          remote = "https://rubygems.org";
          gems = [
            "rake"
            "zeitwerk"
          ];
        }
        {
          remote = "https://private.example.com";
          gems = [ "mygem" ];
        }
      ];
      result = indexRemotes sections;
    in
    assertEq "indexRemotes: rake" result.rake "https://rubygems.org"
    && assertEq "indexRemotes: zeitwerk" result.zeitwerk "https://rubygems.org"
    && assertEq "indexRemotes: mygem" result.mygem "https://private.example.com";

  test_indexRemotes_first_writer_wins =
    let
      sections = [
        {
          remote = "https://rubygems.org";
          gems = [ "faraday" ];
        }
        {
          remote = "https://private.example.com";
          gems = [ "faraday" ];
        }
      ];
      result = indexRemotes sections;
    in
    # builtins.listToAttrs keeps the first occurrence when names collide
    assertEq "indexRemotes: duplicate gem uses first remote" result.faraday "https://rubygems.org";

  # ── mergeGemMetadata ─────────────────────────────────────────

  test_mergeGemMetadata =
    let
      result = mergeGemMetadata {
        checksumSection = [
          {
            gemName = "rake";
            version = "13.0.6";
            platform = "ruby";
            source = {
              sha256 = "aaaa";
            };
          }
          {
            gemName = "ffi";
            version = "1.17.2";
            platform = "arm64-darwin";
            source = {
              sha256 = "bbbb";
            };
          }
        ];
        gemRemotes = {
          rake = "https://rubygems.org";
          ffi = "https://rubygems.org";
        };
        gemGroups = {
          rake = [ "default" ];
          ffi = [
            "default"
            "development"
          ];
        };
      };
      rake = builtins.elemAt result 0;
      ffi = builtins.elemAt result 1;
    in
    assertEq "mergeGemMetadata: rake groups" rake.groups [ "default" ]
    && assertEq "mergeGemMetadata: rake remote" rake.source.remotes [ "https://rubygems.org" ]
    && assertEq "mergeGemMetadata: rake type" rake.source.type "gem"
    && assertEq "mergeGemMetadata: ffi platform" ffi.platform "arm64-darwin"
    && assertEq "mergeGemMetadata: ffi groups" ffi.groups [
      "default"
      "development"
    ];

  test_mergeGemMetadata_missing_group_defaults_empty =
    let
      result = mergeGemMetadata {
        checksumSection = [
          {
            gemName = "mini_portile2";
            version = "2.8.0";
            platform = "ruby";
            source = {
              sha256 = "cccc";
            };
          }
        ];
        gemRemotes = {
          mini_portile2 = "https://rubygems.org";
        };
        gemGroups = { }; # mini_portile2 not in groups (build-time dep)
      };
      gem = builtins.elemAt result 0;
    in
    assertEq "mergeGemMetadata: missing group defaults to []" gem.groups [ ];

  # ── parseChecksumLine: right-to-left platform parsing ────────

  # Beta version with platform: version contains `-`, must not be confused
  # with the platform separator.
  test_parseChecksum_beta_version_with_platform =
    let
      result = parseChecksumLine "  nokogiri (1.16.0.beta.1-arm64-darwin) sha256=deadbeef";
    in
    assertEq "parseChecksumLine: beta version with platform - gemName" result.gemName "nokogiri"
    && assertEq "parseChecksumLine: beta version with platform - version" result.version "1.16.0.beta.1"
    &&
      assertEq "parseChecksumLine: beta version with platform - platform" result.platform
        "arm64-darwin";

  # Beta version without platform: entire string is the version, platform = ruby.
  test_parseChecksum_beta_version_no_platform =
    let
      result = parseChecksumLine "  mygem (2.0.0-rc1) sha256=abcd1234";
    in
    assertEq "parseChecksumLine: beta version no platform - gemName" result.gemName "mygem"
    && assertEq "parseChecksumLine: beta version no platform - version" result.version "2.0.0-rc1"
    && assertEq "parseChecksumLine: beta version no platform - platform" result.platform "ruby";

  # Pre-release with multi-segment platform
  test_parseChecksum_prerelease_multi_segment_platform =
    let
      result = parseChecksumLine "  ffi (2.0.0-beta.2-aarch64-linux-gnu) sha256=face0000";
    in
    assertEq "parseChecksumLine: prerelease multi-segment platform - version" result.version
      "2.0.0-beta.2"
    &&
      assertEq "parseChecksumLine: prerelease multi-segment platform - platform" result.platform
        "aarch64-linux-gnu";

  # splitVersionPlatform: known platform
  test_splitVersionPlatform_known =
    let
      result = splitVersionPlatform "1.18.8-arm64-darwin";
    in
    assertEq "splitVersionPlatform: known platform - version" result.version "1.18.8"
    && assertEq "splitVersionPlatform: known platform - platform" result.platform "arm64-darwin";

  # splitVersionPlatform: no platform (pure version)
  test_splitVersionPlatform_ruby =
    let
      result = splitVersionPlatform "2.7.2";
    in
    assertEq "splitVersionPlatform: no platform - version" result.version "2.7.2"
    && assertEq "splitVersionPlatform: no platform - platform" result.platform "ruby";

  # splitVersionPlatform: unknown suffix treated as version
  test_splitVersionPlatform_unknown =
    let
      result = splitVersionPlatform "1.0.0-beta.1";
    in
    assertEq "splitVersionPlatform: unknown suffix is version" result.version "1.0.0-beta.1"
    && assertEq "splitVersionPlatform: unknown suffix platform is ruby" result.platform "ruby";

  # ── parseDependencies ───────────────────────────────────────

  test_parseDependencies_nokogiri =
    let
      result = parseDependencies [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    nokogiri (1.19.2)"
        "      mini_portile2 (~> 2.8.2)"
        "      racc (~> 1.4)"
        "    racc (1.8.1)"
      ];
    in
    assertEq "parseDependencies: nokogiri deps" result.nokogiri [
      "mini_portile2"
      "racc"
    ]
    && assertEq "parseDependencies: racc has no deps" result.racc [ ];

  test_parseDependencies_multiple_gems =
    let
      result = parseDependencies [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    ethon (0.18.0)"
        "      ffi (>= 1.15.0)"
        "      logger"
        "    ffi (1.17.3)"
        "    logger (1.7.0)"
        "    puma (6.6.1)"
        "      nio4r (~> 2.0)"
        "    nio4r (2.7.5)"
      ];
    in
    assertEq "parseDependencies: ethon deps" result.ethon [
      "ffi"
      "logger"
    ]
    && assertEq "parseDependencies: ffi no deps" result.ffi [ ]
    && assertEq "parseDependencies: logger no deps" result.logger [ ]
    && assertEq "parseDependencies: puma deps" result.puma [ "nio4r" ]
    && assertEq "parseDependencies: nio4r no deps" result.nio4r [ ];

  # Platform variants of the same gem should merge dependencies (union)
  test_parseDependencies_platform_variants_merge =
    let
      result = parseDependencies [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    nokogiri (1.19.2)"
        "      mini_portile2 (~> 2.8.2)"
        "      racc (~> 1.4)"
        "    nokogiri (1.19.2-arm64-darwin)"
        "      racc (~> 1.4)"
      ];
    in
    # Both variants share the name "nokogiri"; the ruby variant has
    # mini_portile2 + racc, the native variant only has racc.
    # Since they share a key, deps get merged.
    assertEq "parseDependencies: platform variants merge deps" result.nokogiri [
      "mini_portile2"
      "racc"
    ];

  # Gems with no dependencies at all
  test_parseDependencies_no_deps =
    let
      result = parseDependencies [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    rack (3.2.5)"
        "    minitest (5.27.0)"
      ];
    in
    assertEq "parseDependencies: rack no deps" result.rack [ ]
    && assertEq "parseDependencies: minitest no deps" result.minitest [ ];

  # Multi-segment platform gems in specs (e.g., ffi with aarch64-linux-gnu)
  test_parseDependencies_multi_segment_platform =
    let
      result = parseDependencies [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    ffi (1.17.3)"
        "    ffi (1.17.3-aarch64-linux-gnu)"
        "    ffi (1.17.3-x86_64-linux-musl)"
      ];
    in
    # All ffi variants should parse as "ffi" with empty deps
    assertEq "parseDependencies: multi-segment platform ffi" result.ffi [ ];

  # ── parseDependenciesSection ────────────────────────────────

  test_parseDependenciesSection_basic =
    let
      result = parseDependenciesSection [
        "  ethon"
        "  minitest (~> 5.0)"
        "  nokogiri (~> 1.18)"
        "  puma (~> 6.0)"
        "  rack (~> 3.0)"
      ];
    in
    assertEq "parseDependenciesSection: extracts gem names" result [
      "ethon"
      "minitest"
      "nokogiri"
      "puma"
      "rack"
    ];

  # DEPENDENCIES section with no version constraints
  test_parseDependenciesSection_no_constraints =
    let
      result = parseDependenciesSection [
        "  rake"
        "  bundler"
      ];
    in
    assertEq "parseDependenciesSection: no constraints" result [
      "rake"
      "bundler"
    ];

  # ── takeDependenciesSection ─────────────────────────────────

  test_takeDependenciesSection =
    let
      lines = [
        "GEM"
        "  remote: https://rubygems.org/"
        "  specs:"
        "    rake (13.0.6)"
        ""
        "PLATFORMS"
        "  ruby"
        ""
        "DEPENDENCIES"
        "  rake"
        "  bundler (~> 2.0)"
        ""
        "BUNDLED WITH"
        "   2.5.22"
      ];
      result = takeDependenciesSection lines;
    in
    assertEq "takeDependenciesSection: extracts DEPENDENCIES lines" result [
      "  rake"
      "  bundler (~> 2.0)"
    ];

  test_takeDependenciesSection_missing =
    let
      lines = [
        "GEM"
        "  remote: https://rubygems.org/"
        "  specs:"
        "    rake (13.0.6)"
        ""
        "CHECKSUMS"
        "  rake (13.0.6) sha256=aaaa"
      ];
      result = takeDependenciesSection lines;
    in
    assertEq "takeDependenciesSection: missing section returns []" result [ ];

  # ── error message prefixes (Phase 4) ─────────────────────────

  test_parseLockfile_missing_checksums_prefix = assertThrows "parseLockfile: missing CHECKSUMS throws with gems4nix prefix" (parseLockfile ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    PLATFORMS
      ruby
  '');

  test_parseLockfile_missing_gem_section_prefix = assertThrows "parseLockfile: missing GEM section throws with gems4nix prefix" (parseLockfile ''
    CHECKSUMS
      rake (13.0.6) sha256=aaaa

    BUNDLED WITH
       2.5.22
  '');

  test_parseChecksum_bad_version_format = assertThrows "parseChecksumLine: bad version format throws with gems4nix (internal) prefix" (
    parseChecksumLine "  zeitwerk 2.6.18 sha256=abc123"
  );

  test_parseChecksum_bad_hash_format = assertThrows "parseChecksumLine: bad hash format throws with gems4nix (internal) prefix" (
    parseChecksumLine "  zeitwerk (2.6.18) nohash"
  );

  # ── all tests ────────────────────────────────────────────────

  allTests =
    # findIndices
    test_findIndices_multiple
    && test_findIndices_none
    && test_findIndices_single
    # takeLines
    && test_takeLines_basic
    && test_takeLines_no_blank
    && test_takeLines_immediate_blank
    && test_takeLines_offset
    # parseChecksumLine
    && test_parseChecksum_simple
    && test_parseChecksum_platform
    && test_parseChecksum_multi_segment_platform
    && test_parseChecksum_missing_hash_returns_null
    && test_parseChecksum_extra_leading_spaces
    && test_parseChecksum_empty_line_returns_null
    # parseGemSection
    && test_parseGemSection_basic
    && test_parseGemSection_no_trailing_slash
    && test_parseGemSection_deps_included
    # parseLockfile
    && test_parseLockfile
    && test_parseLockfile_missing_checksums
    && test_parseLockfile_multi_remote
    # parseLockfile: missing GEM section
    && test_parseLockfile_missing_gem_section
    && test_parseLockfile_empty_gem_specs
    # parseLockfile: git/path gems
    && test_parseLockfile_skips_hashless
    # indexRemotes
    && test_indexRemotes
    && test_indexRemotes_first_writer_wins
    # mergeGemMetadata
    && test_mergeGemMetadata
    && test_mergeGemMetadata_missing_group_defaults_empty
    # parseChecksumLine: right-to-left platform parsing
    && test_parseChecksum_beta_version_with_platform
    && test_parseChecksum_beta_version_no_platform
    && test_parseChecksum_prerelease_multi_segment_platform
    && test_splitVersionPlatform_known
    && test_splitVersionPlatform_ruby
    && test_splitVersionPlatform_unknown
    # parseDependencies
    && test_parseDependencies_nokogiri
    && test_parseDependencies_multiple_gems
    && test_parseDependencies_platform_variants_merge
    && test_parseDependencies_no_deps
    && test_parseDependencies_multi_segment_platform
    # parseDependenciesSection
    && test_parseDependenciesSection_basic
    && test_parseDependenciesSection_no_constraints
    # takeDependenciesSection
    && test_takeDependenciesSection
    && test_takeDependenciesSection_missing
    # error message prefixes (Phase 4)
    && test_parseLockfile_missing_checksums_prefix
    && test_parseLockfile_missing_gem_section_prefix
    && test_parseChecksum_bad_version_format
    && test_parseChecksum_bad_hash_format;

in
allTests
