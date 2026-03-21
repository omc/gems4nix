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
  inherit (helpers) findIndices takeLines parseChecksumLine parseGemSection;

  # helper: assert with message
  assertEq = name: actual: expected:
    if actual == expected then true
    else throw "FAIL: ${name}\n  expected: ${builtins.toJSON expected}\n  actual:   ${builtins.toJSON actual}";

  # helper: assert that evaluating an expression throws
  assertThrows = name: expr:
    let
      result = builtins.tryEval (builtins.deepSeq expr expr);
    in
    if result.success then
      throw "FAIL: ${name}\n  expected an error but got: ${builtins.toJSON result.value}"
    else
      true;

  # helper: assert that evaluating an expression throws, and the error contains a substring
  # NOTE: builtins.tryEval does not expose the error message, so we can only
  # check that it throws. To verify the message is helpful, we test it manually
  # during RED and confirm the fix in GREEN.
  assertThrowsWithMessage = assertThrows;

  # ── findIndices ──────────────────────────────────────────────

  test_findIndices_multiple = assertEq
    "findIndices: multiple matches"
    (findIndices (x: x == "GEM") [ "GEM" "foo" "bar" "GEM" "baz" ])
    [ 0 3 ];

  test_findIndices_none = assertEq
    "findIndices: no matches"
    (findIndices (x: x == "NOPE") [ "GEM" "foo" "bar" ])
    [ ];

  test_findIndices_single = assertEq
    "findIndices: single match"
    (findIndices (x: x == "bar") [ "foo" "bar" "baz" ])
    [ 1 ];

  # ── takeLines ────────────────────────────────────────────────

  test_takeLines_basic = assertEq
    "takeLines: lines until blank"
    (takeLines 0 [ "HEADER" "  line1" "  line2" "" "  line3" ])
    [ "  line1" "  line2" ];

  test_takeLines_no_blank = assertEq
    "takeLines: no blank line (runs to end)"
    (takeLines 0 [ "HEADER" "a" "b" "c" ])
    [ "a" "b" "c" ];

  test_takeLines_immediate_blank = assertEq
    "takeLines: blank immediately after header"
    (takeLines 0 [ "HEADER" "" "stuff" ])
    [ ];

  test_takeLines_offset = assertEq
    "takeLines: with offset"
    (takeLines 2 [ "skip" "skip" "HEADER" "  a" "  b" "" "  c" ])
    [ "  a" "  b" ];

  # ── parseChecksumLine: happy path ────────────────────────────

  test_parseChecksum_simple =
    let
      result = parseChecksumLine "  zeitwerk (2.7.2) sha256=842e067cb11eb923d747249badfb5fcdc9652d6f20a1f06453317920fdcd4673";
    in
    assertEq "parseChecksumLine: simple gem - gemName" result.gemName "zeitwerk"
    && assertEq "parseChecksumLine: simple gem - version" result.version "2.7.2"
    && assertEq "parseChecksumLine: simple gem - platform" result.platform "ruby"
    && assertEq "parseChecksumLine: simple gem - sha256" result.source.sha256 "842e067cb11eb923d747249badfb5fcdc9652d6f20a1f06453317920fdcd4673";

  test_parseChecksum_platform =
    let
      result = parseChecksumLine "  nokogiri (1.18.8-arm64-darwin) sha256=483b5b9fb33653f6f05cbe00d09ea315f268f0e707cfc809aa39b62993008212";
    in
    assertEq "parseChecksumLine: platform gem - gemName" result.gemName "nokogiri"
    && assertEq "parseChecksumLine: platform gem - version" result.version "1.18.8"
    && assertEq "parseChecksumLine: platform gem - platform" result.platform "arm64-darwin"
    && assertEq "parseChecksumLine: platform gem - sha256" result.source.sha256 "483b5b9fb33653f6f05cbe00d09ea315f268f0e707cfc809aa39b62993008212";

  test_parseChecksum_multi_segment_platform =
    let
      result = parseChecksumLine "  ffi (1.17.2-aarch64-linux-gnu) sha256=c910bd3cae70b76690418cce4572b7f6c208d271f323d692a067d59116211a1a";
    in
    assertEq "parseChecksumLine: multi-segment platform - gemName" result.gemName "ffi"
    && assertEq "parseChecksumLine: multi-segment platform - version" result.version "1.17.2"
    && assertEq "parseChecksumLine: multi-segment platform - platform" result.platform "aarch64-linux-gnu"
    && assertEq "parseChecksumLine: multi-segment platform - sha256" result.source.sha256 "c910bd3cae70b76690418cce4572b7f6c208d271f323d692a067d59116211a1a";

  # ── parseChecksumLine: malformed input (recommendation #1) ──

  test_parseChecksum_missing_hash = assertThrowsWithMessage
    "parseChecksumLine: missing hash should throw a helpful error"
    (parseChecksumLine "  zeitwerk (2.6.18)");

  test_parseChecksum_extra_leading_spaces = assertThrowsWithMessage
    "parseChecksumLine: extra leading spaces should throw a helpful error"
    (parseChecksumLine "    zeitwerk (2.6.18) sha256=abc123");

  test_parseChecksum_empty_line = assertThrowsWithMessage
    "parseChecksumLine: empty line should throw a helpful error"
    (parseChecksumLine "");

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
    && assertEq "parseGemSection: gems list" result.gems [ "abbrev" "zeitwerk" ];

  test_parseGemSection_no_trailing_slash =
    let
      result = parseGemSection [
        "  remote: https://rubygems.pkg.github.com/omc"
        "  specs:"
        "    depot (1.4.0)"
      ];
    in
    assertEq "parseGemSection: remote without trailing slash" result.remote "https://rubygems.pkg.github.com/omc"
    && assertEq "parseGemSection: gems from private remote" result.gems [ "depot" ];

  test_parseGemSection_deps_ignored =
    let
      # dependency lines are indented further (6 spaces) and appear after the gem line (4 spaces).
      # parseGemSection extracts all non-empty parts; the gem name is elemAt 0.
      result = parseGemSection [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    actioncable (8.0.2)"
        "      actionpack (= 8.0.2)"
        "      activesupport (= 8.0.2)"
        "    zeitwerk (2.7.2)"
      ];
    in
    # dependency lines are included in the gem list. parseGemSection does not
    # distinguish indent levels. This documents current behavior.
    assertEq "parseGemSection: dependency lines included (current behavior)"
      result.gems
      [ "actioncable" "actionpack" "activesupport" "zeitwerk" ];

  # ── all tests ────────────────────────────────────────────────

  allTests =
    test_findIndices_multiple
    && test_findIndices_none
    && test_findIndices_single
    && test_takeLines_basic
    && test_takeLines_no_blank
    && test_takeLines_immediate_blank
    && test_takeLines_offset
    && test_parseChecksum_simple
    && test_parseChecksum_platform
    && test_parseChecksum_multi_segment_platform
    && test_parseChecksum_missing_hash
    && test_parseChecksum_extra_leading_spaces
    && test_parseChecksum_empty_line
    && test_parseGemSection_basic
    && test_parseGemSection_no_trailing_slash
    && test_parseGemSection_deps_ignored;

in
allTests
