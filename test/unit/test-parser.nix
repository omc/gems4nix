# Unit tests for parser-helpers.nix
#
# Run: nix eval --file test/unit/test-parser.nix --json
# Returns: true (all assertions pass) or throws with a descriptive message.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
  lib = nixpkgs.lib;
  helpers = import ../../lib/gemfile-env/parser-helpers.nix { inherit lib; };
  inherit (helpers)
    findIndices
    takeLines
    parseChecksumLine
    parseGemSection
    parseLockfileContent
    buildGemRemotes
    mergeGemMetadata
    ;
  inherit (import ../test-helpers.nix) assertEq assertThrows;

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

  # ── parseLockfileContent ─────────────────────────────────────

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

  test_parseLockfileContent =
    let
      result = parseLockfileContent minimalLockfile;
    in
    assertEq "parseLockfileContent: checksumSection length" (builtins.length result.checksumSection) 2
    &&
      assertEq "parseLockfileContent: first checksum gemName"
        (builtins.elemAt result.checksumSection 0).gemName
        "rake"
    && assertEq "parseLockfileContent: gemSections length" (builtins.length result.gemSections) 1
    &&
      assertEq "parseLockfileContent: first section remote" (builtins.elemAt result.gemSections 0).remote
        "https://rubygems.org";

  test_parseLockfileContent_missing_checksums = assertThrows "parseLockfileContent: missing CHECKSUMS throws" (parseLockfileContent ''
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

  test_parseLockfileContent_multi_remote =
    let
      result = parseLockfileContent multiRemoteLockfile;
    in
    assertEq "parseLockfileContent: multi-remote gemSections count" (builtins.length result.gemSections)
      2;

  # ── parseLockfileContent: missing GEM section (critique #5) ──

  test_parseLockfileContent_missing_gem_section = assertThrows "parseLockfileContent: missing GEM section throws" (parseLockfileContent ''
    CHECKSUMS
      rake (13.0.6) sha256=aaaa

    BUNDLED WITH
       2.5.22
  '');

  # A lockfile with CHECKSUMS but a completely empty GEM section (no specs)
  test_parseLockfileContent_empty_gem_specs =
    let
      result = parseLockfileContent ''
        GEM
          remote: https://rubygems.org/
          specs:

        CHECKSUMS

        BUNDLED WITH
           2.5.22
      '';
    in
    # empty CHECKSUMS = no gems parsed, and an empty GEM section is valid
    assertEq "parseLockfileContent: empty gem specs returns empty checksumSection"
      (builtins.length result.checksumSection)
      0
    &&
      assertEq "parseLockfileContent: empty gem specs still has one gemSection"
        (builtins.length result.gemSections)
        1;

  # ── parseLockfileContent: git/path gems skipped ─────────────

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

  test_parseLockfileContent_skips_hashless =
    let
      result = parseLockfileContent gitPathLockfile;
    in
    # Only rake (with a hash) survives; errgonomic and hello_gem are filtered out
    assertEq "parseLockfileContent: git/path gems filtered from checksumSection"
      (builtins.length result.checksumSection)
      1
    &&
      assertEq "parseLockfileContent: surviving gem is rake"
        (builtins.elemAt result.checksumSection 0).gemName
        "rake";

  # ── buildGemRemotes ──────────────────────────────────────────

  test_buildGemRemotes =
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
      result = buildGemRemotes sections;
    in
    assertEq "buildGemRemotes: rake" result.rake "https://rubygems.org"
    && assertEq "buildGemRemotes: zeitwerk" result.zeitwerk "https://rubygems.org"
    && assertEq "buildGemRemotes: mygem" result.mygem "https://private.example.com";

  test_buildGemRemotes_first_writer_wins =
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
      result = buildGemRemotes sections;
    in
    # builtins.listToAttrs keeps the first occurrence when names collide
    assertEq "buildGemRemotes: duplicate gem uses first remote" result.faraday "https://rubygems.org";

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
    # parseLockfileContent
    && test_parseLockfileContent
    && test_parseLockfileContent_missing_checksums
    && test_parseLockfileContent_multi_remote
    # parseLockfileContent: missing GEM section
    && test_parseLockfileContent_missing_gem_section
    && test_parseLockfileContent_empty_gem_specs
    # parseLockfileContent: git/path gems
    && test_parseLockfileContent_skips_hashless
    # buildGemRemotes
    && test_buildGemRemotes
    && test_buildGemRemotes_first_writer_wins
    # mergeGemMetadata
    && test_mergeGemMetadata
    && test_mergeGemMetadata_missing_group_defaults_empty;

in
allTests
