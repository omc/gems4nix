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
    parseSpecLine
    parseGemSection
    parseSectionBody
    parseGitSection
    parsePathSection
    parseDependencies
    parseDependenciesSection
    takeDependenciesSection
    parseRubyVersion
    rubyAbi
    rubyVersionVerdict
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

  # A doubled space is malformed and Bundler never writes one, but the
  # complaint has to name the real problem: the version, not the hash.
  test_parseChecksum_double_space =
    let
      result = parseChecksumLine "  zeitwerk  (2.6.18) sha256=deadbeef";
    in
    assertEq "parseChecksumLine: a doubled space does not shift the hash" result.source.sha256
      "deadbeef"
    && assertEq "parseChecksumLine: a doubled space does not shift the version" result.version "2.6.18"
    && assertEq "parseChecksumLine: a doubled space does not shift the name" result.gemName "zeitwerk";

  # A hashless line is still subject to the indent rule. Four spaces is a gem
  # line from a specs: block, not a CHECKSUMS entry, and returning null for one
  # would let it pass for a git or path gem.
  test_parseChecksum_over_indented_hashless_throws = assertThrows "parseChecksumLine: an over-indented hashless line throws rather than returning null" (
    parseChecksumLine "    concurrent-ruby (1.3.6)"
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
    assertEq "parseGemSection: remote (trailing slash stripped)" result.remotes [
      "https://rubygems.org"
    ]
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
    assertEq "parseGemSection: remote without trailing slash" result.remotes [
      "https://rubygems.pkg.github.com/omc"
    ]
    && assertEq "parseGemSection: gems from private remote" result.gems [ "depot" ];

  # Bundler writes one `remote:` line per remote of a single source, and it
  # writes them last-declared-first, which is its own priority order.
  test_parseGemSection_multiple_remotes =
    let
      result = parseGemSection [
        "  remote: https://private.example.com/"
        "  remote: https://rubygems.org/"
        "  specs:"
        "    rake (13.0.6)"
      ];
    in
    assertEq "parseGemSection: every remote survives, in lockfile order" result.remotes [
      "https://private.example.com"
      "https://rubygems.org"
    ]
    && assertEq "parseGemSection: a second remote line is not a gem" result.gems [ "rake" ];

  test_parseGemSection_deps_excluded =
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
    # A 6-space line names a dependency of the gem above it. Counting it as a
    # gem of this section claims a remote for a gem another section provides.
    assertEq "parseGemSection: a dependency line is not a gem of this section" result.gems [
      "actioncable"
      "zeitwerk"
    ];

  # One gem, one remote, however many platform variants it was locked for.
  test_parseGemSection_platform_variants_collapse =
    let
      result = parseGemSection [
        "  remote: https://rubygems.org/"
        "  specs:"
        "    nokogiri (1.18.0)"
        "    nokogiri (1.18.0-arm64-darwin)"
        "    nokogiri (1.18.0-x86_64-linux-gnu)"
      ];
    in
    assertEq "parseGemSection: platform variants are one gem" result.gems [ "nokogiri" ];

  test_parseGemSection_missing_remote_throws =
    assertThrows "parseGemSection: a GEM section with no remote throws"
      (parseGemSection [
        "  specs:"
        "    rake (13.0.6)"
      ]);

  test_parseGemSection_missing_specs_throws =
    assertThrows "parseGemSection: a GEM section with no specs line throws"
      (parseGemSection [
        "  remote: https://rubygems.org/"
      ]);

  test_parseGemSection_unknown_key_throws =
    assertThrows "parseGemSection: an unrecognised option on a GEM section throws"
      (parseGemSection [
        "  remote: https://rubygems.org/"
        "  revision: f06314af89209f855019219fd198513855be0fd5"
        "  specs:"
        "    rake (13.0.6)"
      ]);

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
    && assertEq "parseLockfile: first section remote" (builtins.elemAt result.gemSections 0).remotes [
      "https://rubygems.org"
    ];

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

  # concurrent-ruby appears only as a 6-space dependency line in the GIT
  # section. If it turns up in the remote table, GIT lines leaked into it.
  gitPathLockfile = ''
    GIT
      remote: https://github.com/omc/errgonomic.git
      revision: abc123
      branch: main
      specs:
        errgonomic (0.5.1)
          concurrent-ruby (~> 1.0)

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

  # ── RUBY VERSION ─────────────────────────────────────────────

  rubyVersionLockfile = version: ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    CHECKSUMS
      rake (13.0.6) sha256=aaaa

    RUBY VERSION
    ${version}

    BUNDLED WITH
       2.7.2
  '';

  test_parseLockfile_reads_the_ruby_version =
    assertEq "parseLockfile: the locked ruby version, past its three-space indent"
      (parseLockfile (rubyVersionLockfile "   ruby 3.4.9")).rubyVersion
      "3.4.9";

  # examples/complex records this shape.
  test_parseRubyVersion_drops_the_patchlevel =
    assertEq "parseRubyVersion: a patchlevel is not part of the version"
      (parseRubyVersion [
        "RUBY VERSION"
        "   ruby 3.3.10p183"
        ""
      ])
      "3.3.10";

  test_parseRubyVersion_absent_is_null =
    assertEq "parseRubyVersion: a lockfile with no RUBY VERSION section is not an error"
      (parseRubyVersion [
        "GEM"
        "  remote: https://rubygems.org/"
        ""
      ])
      null;

  # JRuby writes `ruby 3.1.4 (jruby 9.4.5.0)`. Reading the 3.1.4 out of it
  # would claim a match gems4nix cannot deliver.
  test_parseRubyVersion_unreadable_throws =
    assertThrows "parseRubyVersion: a value in an unrecognised shape throws"
      (parseRubyVersion [
        "RUBY VERSION"
        "   ruby 3.1.4 (jruby 9.4.5.0)"
        ""
      ]);

  test_rubyAbi =
    assertEq "rubyAbi: major and minor only" (rubyAbi "3.3.10") "3.3"
    && assertEq "rubyAbi: a two-part version is its own abi" (rubyAbi "3.4") "3.4";

  test_rubyVersionVerdict_agreement =
    assertEq "rubyVersionVerdict: the same version is no verdict" (rubyVersionVerdict {
      locked = "3.4.9";
      actual = "3.4.9";
    }) null
    && assertEq "rubyVersionVerdict: a lockfile naming no ruby is no verdict" (rubyVersionVerdict {
      locked = null;
      actual = "3.4.9";
    }) null;

  test_rubyVersionVerdict_abi_difference_is_an_error =
    let
      verdict = rubyVersionVerdict {
        locked = "3.4.9";
        actual = "3.3.5";
      };
    in
    assertEq "rubyVersionVerdict: a different abi is an error" verdict.level "error"
    &&
      assertEq "rubyVersionVerdict: the error names the locked version"
        (lib.strings.hasInfix "Ruby 3.4.9" verdict.message)
        true
    &&
      assertEq "rubyVersionVerdict: the error names the version built with"
        (lib.strings.hasInfix "Ruby 3.3.5" verdict.message)
        true;

  # examples/complex locks 3.3.10 and builds against nixpkgs 24.11's 3.3.5.
  # Bundler enforces the Gemfile's `ruby '~> 3.3'`, which both satisfy.
  test_rubyVersionVerdict_teeny_difference_is_a_warning =
    let
      verdict = rubyVersionVerdict {
        locked = "3.3.10";
        actual = "3.3.5";
      };
    in
    assertEq "rubyVersionVerdict: a shared abi is a warning" verdict.level "warning"
    &&
      assertEq "rubyVersionVerdict: the warning names the locked version"
        (lib.strings.hasInfix "Ruby 3.3.10" verdict.message)
        true
    &&
      assertEq "rubyVersionVerdict: the warning names the version built with"
        (lib.strings.hasInfix "Ruby 3.3.5" verdict.message)
        true;

  # ── indexRemotes ──────────────────────────────────────────

  test_indexRemotes =
    let
      sections = [
        {
          remotes = [ "https://rubygems.org" ];
          gems = [
            "rake"
            "zeitwerk"
          ];
        }
        {
          remotes = [ "https://private.example.com" ];
          gems = [ "mygem" ];
        }
      ];
      result = indexRemotes sections;
    in
    assertEq "indexRemotes: rake" result.rake [ "https://rubygems.org" ]
    && assertEq "indexRemotes: zeitwerk" result.zeitwerk [ "https://rubygems.org" ]
    && assertEq "indexRemotes: mygem" result.mygem [ "https://private.example.com" ];

  # A section's whole remote list belongs to each of its gems: any of them may
  # serve it, and fetchurl tries them in order.
  test_indexRemotes_carries_every_remote =
    let
      result = indexRemotes [
        {
          remotes = [
            "https://private.example.com"
            "https://rubygems.org"
          ];
          gems = [ "rake" ];
        }
      ];
    in
    assertEq "indexRemotes: a multi-remote section gives its gems both remotes" result.rake [
      "https://private.example.com"
      "https://rubygems.org"
    ];

  test_indexRemotes_duplicate_gem_throws =
    assertThrows "indexRemotes: one gem claimed by two GEM sections throws"
      (indexRemotes [
        {
          remotes = [ "https://rubygems.org" ];
          gems = [ "faraday" ];
        }
        {
          remotes = [ "https://private.example.com" ];
          gems = [ "faraday" ];
        }
      ]);

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
          rake = [ "https://rubygems.org" ];
          ffi = [ "https://rubygems.org" ];
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

  # A checksum names a gem that must have come from somewhere. If no GEM
  # section provides it and no GIT or PATH section claims it either, we have
  # nowhere to fetch it from, and `attribute missing` says none of that.
  test_mergeGemMetadata_unsourced_checksum_throws =
    assertThrows "mergeGemMetadata: a checksum no GEM section provides throws"
      (mergeGemMetadata {
        checksumSection = [
          {
            gemName = "rake";
            version = "13.0.6";
            platform = "ruby";
            source = {
              sha256 = "aaaa";
            };
          }
        ];
        gemRemotes = { };
        gemGroups = { };
      });

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
          mini_portile2 = [ "https://rubygems.org" ];
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

  # ── parseSpecLine ────────────────────────────────────────────

  test_parseSpecLine_simple =
    let
      result = parseSpecLine "    errgonomic (0.5.1)";
    in
    assertEq "parseSpecLine: gemName" result.gemName "errgonomic"
    && assertEq "parseSpecLine: version" result.version "0.5.1"
    && assertEq "parseSpecLine: platform defaults to ruby" result.platform "ruby";

  test_parseSpecLine_platform =
    let
      result = parseSpecLine "    ffi (1.17.3-aarch64-linux-gnu)";
    in
    assertEq "parseSpecLine: platform gem gemName" result.gemName "ffi"
    && assertEq "parseSpecLine: platform gem version" result.version "1.17.3"
    && assertEq "parseSpecLine: multi-segment platform" result.platform "aarch64-linux-gnu";

  # A hyphen in a version is not a platform. The known-platform table is what
  # tells the two apart.
  test_parseSpecLine_prerelease_version =
    let
      result = parseSpecLine "    errgonomic (0.5.1-beta.1)";
    in
    assertEq "parseSpecLine: pre-release version kept whole" result.version "0.5.1-beta.1"
    && assertEq "parseSpecLine: pre-release version is not a platform" result.platform "ruby";

  test_parseSpecLine_bad_version_throws = assertThrows "parseSpecLine: version without parens throws" (
    parseSpecLine "    errgonomic 0.5.1"
  );

  test_parseSpecLine_missing_version_throws = assertThrows "parseSpecLine: name with no version throws" (
    parseSpecLine "    errgonomic"
  );

  # ── parseGitSection ──────────────────────────────────────────

  gitSectionLines = [
    "  remote: https://github.com/omc/errgonomic.git"
    "  revision: f06314af89209f855019219fd198513855be0fd5"
    "  branch: main"
    "  specs:"
    "    errgonomic (0.5.1)"
    "      concurrent-ruby (~> 1.0)"
  ];

  test_parseGitSection_basic =
    let
      result = parseGitSection gitSectionLines;
    in
    assertEq "parseGitSection: remote" result.remote "https://github.com/omc/errgonomic.git"
    && assertEq "parseGitSection: revision" result.revision "f06314af89209f855019219fd198513855be0fd5"
    && assertEq "parseGitSection: branch" result.branch "main"
    && assertEq "parseGitSection: tag defaults null" result.tag null
    && assertEq "parseGitSection: ref defaults null" result.ref null
    && assertEq "parseGitSection: submodules defaults false" result.submodules false
    # The 6-space line names a dependency, not a gem this source provides.
    # parseGemSection counts it as a gem; a GIT section must not.
    && assertEq "parseGitSection: only the 4-space spec line is a gem" result.gems [
      {
        gemName = "errgonomic";
        version = "0.5.1";
        platform = "ruby";
      }
    ];

  test_parseGitSection_multiple_gems =
    let
      result = parseGitSection [
        "  remote: https://github.com/example/monorepo.git"
        "  revision: abc123"
        "  specs:"
        "    first_gem (1.0.0)"
        "      rake (>= 12)"
        "    second_gem (2.0.0)"
        "      first_gem (= 1.0.0)"
      ];
    in
    assertEq "parseGitSection: multi-gem block yields both gems" (map (g: g.gemName) result.gems) [
      "first_gem"
      "second_gem"
    ];

  test_parseGitSection_tag =
    let
      result = parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  revision: abc123"
        "  tag: v1.2.3"
        "  specs:"
        "    repo (1.2.3)"
      ];
    in
    assertEq "parseGitSection: tag captured" result.tag "v1.2.3"
    && assertEq "parseGitSection: branch null when only tag" result.branch null;

  test_parseGitSection_ref =
    let
      result = parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  revision: abc1234deadbeef"
        "  ref: abc1234"
        "  specs:"
        "    repo (1.0.0)"
      ];
    in
    assertEq "parseGitSection: ref captured" result.ref "abc1234";

  test_parseGitSection_submodules =
    let
      result = parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  revision: abc123"
        "  submodules: true"
        "  specs:"
        "    repo (1.0.0)"
      ];
    in
    assertEq "parseGitSection: submodules coerced to boolean true" result.submodules true;

  # The value is a string, and the string "false" must stay false.
  test_parseGitSection_submodules_false =
    let
      result = parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  revision: abc123"
        "  submodules: false"
        "  specs:"
        "    repo (1.0.0)"
      ];
    in
    assertEq "parseGitSection: submodules: false stays false" result.submodules false;

  test_parseGitSection_missing_revision =
    assertThrows "parseGitSection: missing revision throws"
      (parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  specs:"
        "    repo (1.0.0)"
      ]);

  test_parseGitSection_missing_remote =
    assertThrows "parseGitSection: missing remote throws"
      (parseGitSection [
        "  revision: abc123"
        "  specs:"
        "    repo (1.0.0)"
      ]);

  test_parseGitSection_glob_throws =
    assertThrows "parseGitSection: glob: is unsupported and throws"
      (parseGitSection [
        "  remote: https://github.com/example/monorepo.git"
        "  revision: abc123"
        "  glob: \"{,*,*/*}.gemspec\""
        "  specs:"
        "    repo (1.0.0)"
      ]);

  test_parseGitSection_unknown_key_throws =
    assertThrows "parseGitSection: unknown key throws"
      (parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  revision: abc123"
        "  frobnicate: yes"
        "  specs:"
        "    repo (1.0.0)"
      ]);

  test_parseGitSection_missing_specs_throws =
    assertThrows "parseGitSection: missing specs: throws"
      (parseGitSection [
        "  remote: https://github.com/example/repo.git"
        "  revision: abc123"
      ]);

  # ── parsePathSection ─────────────────────────────────────────

  test_parsePathSection_basic =
    let
      result = parsePathSection [
        "  remote: vendor/hello_gem"
        "  specs:"
        "    hello_gem (0.1.0)"
      ];
    in
    assertEq "parsePathSection: remote" result.remote "vendor/hello_gem"
    && assertEq "parsePathSection: gems" result.gems [
      {
        gemName = "hello_gem";
        version = "0.1.0";
        platform = "ruby";
      }
    ];

  # A Gemfile with a `gemspec` directive locks the app's own gem at ".".
  test_parsePathSection_dot_remote =
    let
      result = parsePathSection [
        "  remote: ."
        "  specs:"
        "    mygem (0.1.0)"
      ];
    in
    assertEq "parsePathSection: '.' remote" result.remote "."
    && assertEq "parsePathSection: '.' remote gem name" (builtins.elemAt result.gems 0).gemName "mygem";

  test_parsePathSection_glob_throws =
    assertThrows "parsePathSection: glob: is unsupported and throws"
      (parsePathSection [
        "  remote: vendor"
        "  glob: \"*/*.gemspec\""
        "  specs:"
        "    hello_gem (0.1.0)"
      ]);

  # A PATH section has no revision to pin, so a GIT-only key is meaningless
  # there and must not be accepted just because GIT accepts it.
  test_parsePathSection_git_key_throws =
    assertThrows "parsePathSection: a GIT-only key throws in a PATH section"
      (parsePathSection [
        "  remote: vendor/hello_gem"
        "  revision: abc123"
        "  specs:"
        "    hello_gem (0.1.0)"
      ]);

  # ── parseSectionBody ─────────────────────────────────────────

  test_parseSectionBody_duplicate_key_throws =
    assertThrows "parseSectionBody: repeated option key throws rather than silently overwriting"
      (parseSectionBody {
        lines = [
          "  remote: https://a.example.com"
          "  remote: https://b.example.com"
          "  specs:"
        ];
      });

  test_parseSectionBody_unparseable_option_throws =
    assertThrows "parseSectionBody: a line that is not '  key: value' throws"
      (parseSectionBody {
        lines = [
          "  remote: https://a.example.com"
          "not-indented"
          "  specs:"
        ];
      });

  # ── parseLockfile: GIT and PATH sections ─────────────────────

  test_parseLockfile_git_path_sections =
    let
      result = parseLockfile gitPathLockfile;
      git = builtins.elemAt result.gitSections 0;
      path = builtins.elemAt result.pathSections 0;
    in
    assertEq "parseLockfile: one GIT section" (builtins.length result.gitSections) 1
    && assertEq "parseLockfile: one PATH section" (builtins.length result.pathSections) 1
    && assertEq "parseLockfile: GIT remote" git.remote "https://github.com/omc/errgonomic.git"
    && assertEq "parseLockfile: GIT gems" (map (g: g.gemName) git.gems) [ "errgonomic" ]
    && assertEq "parseLockfile: PATH remote" path.remote "vendor/hello_gem"
    && assertEq "parseLockfile: PATH gems" (map (g: g.gemName) path.gems) [ "hello_gem" ];

  # A CHECKSUMS entry with no hash needs a GIT or PATH section to claim it.
  # Without one the gem leaves the environment and nothing reports it.
  test_parseLockfile_unexplained_hashless_throws = assertThrows "parseLockfile: hashless checksum with no GIT/PATH source throws" (parseLockfile ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    CHECKSUMS
      rake (13.0.6) sha256=aaaa
      mystery_gem (1.0.0)
  '');

  test_parseLockfile_plugin_source_throws = assertThrows "parseLockfile: PLUGIN SOURCE throws" (parseLockfile ''
    PLUGIN SOURCE
      remote: https://github.com/example/plugin.git
      type: example
      specs:
        plugged (1.0.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    CHECKSUMS
      rake (13.0.6) sha256=aaaa
  '');

  # GIT and PATH sections must never reach indexRemotes. A gem two sections
  # both claim is refused, and a git gem leaking in would collide with the GEM
  # section that really provides it.
  test_indexRemotes_excludes_git_path =
    let
      result = indexRemotes (parseLockfile gitPathLockfile).gemSections;
    in
    assertEq "indexRemotes: git gem absent" (result ? errgonomic) false
    && assertEq "indexRemotes: path gem absent" (result ? hello_gem) false
    && assertEq "indexRemotes: git dependency line absent" (result ? "concurrent-ruby") false
    && assertEq "indexRemotes: real GEM gem present" result.rake [ "https://rubygems.org" ];

  # ── mergeGemMetadata: git and path sources ───────────────────

  fixtureGitSections = [
    {
      remote = "https://github.com/omc/errgonomic.git";
      revision = "f06314af89209f855019219fd198513855be0fd5";
      branch = "main";
      tag = null;
      ref = null;
      submodules = false;
      gems = [
        {
          gemName = "errgonomic";
          version = "0.5.1";
          platform = "ruby";
        }
      ];
    }
  ];

  fixturePathSections = [
    {
      remote = "vendor/hello_gem";
      gems = [
        {
          gemName = "hello_gem";
          version = "0.1.0";
          platform = "ruby";
        }
      ];
    }
  ];

  test_mergeGemMetadata_git_and_path =
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
        ];
        gemRemotes = {
          rake = [ "https://rubygems.org" ];
        };
        gemGroups = {
          rake = [ "default" ];
          errgonomic = [ "default" ];
          hello_gem = [ "default" ];
        };
        gitSections = fixtureGitSections;
        pathSections = fixturePathSections;
        pathRoot = /tmp/fixture;
      };
      byName = builtins.listToAttrs (
        map (g: {
          name = g.gemName;
          value = g;
        }) result
      );
    in
    assertEq "mergeGemMetadata: git+path yields all three gems" (builtins.length result) 3
    && assertEq "mergeGemMetadata: git source type" byName.errgonomic.source.type "git"
    &&
      assertEq "mergeGemMetadata: git url" byName.errgonomic.source.url
        "https://github.com/omc/errgonomic.git"
    &&
      assertEq "mergeGemMetadata: git rev" byName.errgonomic.source.rev
        "f06314af89209f855019219fd198513855be0fd5"
    && assertEq "mergeGemMetadata: git fetchSubmodules" byName.errgonomic.source.fetchSubmodules false
    && assertEq "mergeGemMetadata: git branch recorded" byName.errgonomic.source.branch "main"
    && assertEq "mergeGemMetadata: git groups" byName.errgonomic.groups [ "default" ]
    && assertEq "mergeGemMetadata: git platform" byName.errgonomic.platform "ruby"
    && assertEq "mergeGemMetadata: git version" byName.errgonomic.version "0.5.1"
    && assertEq "mergeGemMetadata: path source type" byName.hello_gem.source.type "path"
    &&
      assertEq "mergeGemMetadata: path resolved against pathRoot" (toString byName.hello_gem.source.path)
        "/tmp/fixture/vendor/hello_gem"
    && assertEq "mergeGemMetadata: gem source still built from checksums" byName.rake.source.type "gem";

  # A remote of "." must resolve to the root, not to "/tmp/fixture/.".
  test_mergeGemMetadata_path_dot_remote =
    let
      result = mergeGemMetadata {
        checksumSection = [ ];
        gemRemotes = { };
        gemGroups = {
          mygem = [ "default" ];
        };
        pathSections = [
          {
            remote = ".";
            gems = [
              {
                gemName = "mygem";
                version = "0.1.0";
                platform = "ruby";
              }
            ];
          }
        ];
        pathRoot = /tmp/fixture;
      };
    in
    assertEq "mergeGemMetadata: '.' remote resolves to the root itself"
      (toString (builtins.elemAt result 0).source.path)
      "/tmp/fixture";

  test_mergeGemMetadata_duplicate_name_throws =
    assertThrows "mergeGemMetadata: gem in both CHECKSUMS and a GIT section throws"
      (mergeGemMetadata {
        checksumSection = [
          {
            gemName = "errgonomic";
            version = "0.5.1";
            platform = "ruby";
            source = {
              sha256 = "aaaa";
            };
          }
        ];
        gemRemotes = {
          errgonomic = [ "https://rubygems.org" ];
        };
        gemGroups = {
          errgonomic = [ "default" ];
        };
        gitSections = fixtureGitSections;
      });

  test_mergeGemMetadata_two_sources_one_name_throws =
    assertThrows "mergeGemMetadata: same gem in a GIT and a PATH section throws"
      (mergeGemMetadata {
        checksumSection = [ ];
        gemRemotes = { };
        gemGroups = { };
        gitSections = fixtureGitSections;
        pathSections = [
          {
            remote = "vendor/errgonomic";
            gems = [
              {
                gemName = "errgonomic";
                version = "0.5.1";
                platform = "ruby";
              }
            ];
          }
        ];
        pathRoot = /tmp/fixture;
      });

  test_mergeGemMetadata_path_without_root_throws =
    assertThrows "mergeGemMetadata: pathSections with a null pathRoot throws"
      (mergeGemMetadata {
        checksumSection = [ ];
        gemRemotes = { };
        gemGroups = { };
        pathSections = fixturePathSections;
        pathRoot = null;
      });

  # A lockfile with no GIT or PATH section must give the same result as it did
  # before git and path support existed. examples/simple, examples/medium and
  # test/rails all rely on that.
  test_mergeGemMetadata_no_git_path_unchanged =
    let
      args = {
        checksumSection = [
          {
            gemName = "rake";
            version = "13.0.6";
            platform = "ruby";
            source = {
              sha256 = "aaaa";
            };
          }
        ];
        gemRemotes = {
          rake = [ "https://rubygems.org" ];
        };
        gemGroups = {
          rake = [ "default" ];
        };
      };
    in
    assertEq "mergeGemMetadata: no git/path sections yields the pre-existing shape"
      (mergeGemMetadata args)
      [
        {
          gemName = "rake";
          version = "13.0.6";
          platform = "ruby";
          groups = [ "default" ];
          source = {
            sha256 = "aaaa";
            remotes = [ "https://rubygems.org" ];
            type = "gem";
          };
        }
      ];

  # parseDependencies reads a `specs:` block by indent alone, so a GIT section
  # yields edges the same way a GEM section does. Without those edges a git
  # gem's own dependencies can be dropped by the group filter.
  test_parseDependencies_git_section =
    assertEq "parseDependencies: GIT section yields the same edge shape as GEM"
      (parseDependencies gitSectionLines)
      {
        errgonomic = [ "concurrent-ruby" ];
      };

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
    && test_parseChecksum_double_space
    && test_parseChecksum_over_indented_hashless_throws
    && test_parseChecksum_empty_line_returns_null
    # parseGemSection
    && test_parseGemSection_basic
    && test_parseGemSection_no_trailing_slash
    && test_parseGemSection_multiple_remotes
    && test_parseGemSection_deps_excluded
    && test_parseGemSection_platform_variants_collapse
    && test_parseGemSection_missing_remote_throws
    && test_parseGemSection_missing_specs_throws
    && test_parseGemSection_unknown_key_throws
    # parseLockfile
    && test_parseLockfile
    && test_parseLockfile_missing_checksums
    && test_parseLockfile_multi_remote
    # parseLockfile: missing GEM section
    && test_parseLockfile_missing_gem_section
    && test_parseLockfile_empty_gem_specs
    # parseLockfile: git/path gems
    && test_parseLockfile_skips_hashless
    && test_parseLockfile_git_path_sections
    && test_parseLockfile_unexplained_hashless_throws
    && test_parseLockfile_plugin_source_throws
    # indexRemotes
    # RUBY VERSION
    && test_parseLockfile_reads_the_ruby_version
    && test_parseRubyVersion_drops_the_patchlevel
    && test_parseRubyVersion_absent_is_null
    && test_parseRubyVersion_unreadable_throws
    && test_rubyAbi
    && test_rubyVersionVerdict_agreement
    && test_rubyVersionVerdict_abi_difference_is_an_error
    && test_rubyVersionVerdict_teeny_difference_is_a_warning
    && test_indexRemotes
    && test_indexRemotes_carries_every_remote
    && test_indexRemotes_duplicate_gem_throws
    && test_indexRemotes_excludes_git_path
    # mergeGemMetadata
    && test_mergeGemMetadata
    && test_mergeGemMetadata_unsourced_checksum_throws
    && test_mergeGemMetadata_missing_group_defaults_empty
    # mergeGemMetadata: git and path sources
    && test_mergeGemMetadata_git_and_path
    && test_mergeGemMetadata_path_dot_remote
    && test_mergeGemMetadata_duplicate_name_throws
    && test_mergeGemMetadata_two_sources_one_name_throws
    && test_mergeGemMetadata_path_without_root_throws
    && test_mergeGemMetadata_no_git_path_unchanged
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
    && test_parseDependencies_git_section
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
    && test_parseChecksum_bad_hash_format
    # parseSpecLine
    && test_parseSpecLine_simple
    && test_parseSpecLine_platform
    && test_parseSpecLine_prerelease_version
    && test_parseSpecLine_bad_version_throws
    && test_parseSpecLine_missing_version_throws
    # parseGitSection
    && test_parseGitSection_basic
    && test_parseGitSection_multiple_gems
    && test_parseGitSection_tag
    && test_parseGitSection_ref
    && test_parseGitSection_submodules
    && test_parseGitSection_submodules_false
    && test_parseGitSection_missing_revision
    && test_parseGitSection_missing_remote
    && test_parseGitSection_glob_throws
    && test_parseGitSection_unknown_key_throws
    && test_parseGitSection_missing_specs_throws
    # parsePathSection
    && test_parsePathSection_basic
    && test_parsePathSection_dot_remote
    && test_parsePathSection_glob_throws
    && test_parsePathSection_git_key_throws
    # parseSectionBody
    && test_parseSectionBody_duplicate_key_throws
    && test_parseSectionBody_unparseable_option_throws;

in
allTests
