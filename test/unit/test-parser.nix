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
    parseSpecLine
    parseSectionBody
    parseGitSection
    parsePathSection
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

  # ── parseSectionBody ─────────────────────────────────────────

  test_parseSectionBody_duplicate_key_throws =
    assertThrows "parseSectionBody: repeated option key throws rather than silently overwriting"
      (parseSectionBody [
        "  remote: https://a.example.com"
        "  remote: https://b.example.com"
        "  specs:"
      ]);

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

  test_parseLockfileContent_git_path_sections =
    let
      result = parseLockfileContent gitPathLockfile;
      git = builtins.elemAt result.gitSections 0;
      path = builtins.elemAt result.pathSections 0;
    in
    assertEq "parseLockfileContent: one GIT section" (builtins.length result.gitSections) 1
    && assertEq "parseLockfileContent: one PATH section" (builtins.length result.pathSections) 1
    && assertEq "parseLockfileContent: GIT remote" git.remote "https://github.com/omc/errgonomic.git"
    && assertEq "parseLockfileContent: GIT gems" (map (g: g.gemName) git.gems) [ "errgonomic" ]
    && assertEq "parseLockfileContent: PATH remote" path.remote "vendor/hello_gem"
    && assertEq "parseLockfileContent: PATH gems" (map (g: g.gemName) path.gems) [ "hello_gem" ];

  # A CHECKSUMS entry with no hash needs a GIT or PATH section to claim it.
  # Without one the gem leaves the environment and nothing reports it.
  test_parseLockfileContent_unexplained_hashless_throws = assertThrows "parseLockfileContent: hashless checksum with no GIT/PATH source throws" (parseLockfileContent ''
    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.6)

    CHECKSUMS
      rake (13.0.6) sha256=aaaa
      mystery_gem (1.0.0)
  '');

  test_parseLockfileContent_plugin_source_throws = assertThrows "parseLockfileContent: PLUGIN SOURCE throws" (parseLockfileContent ''
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

  # GIT and PATH sections must never reach buildGemRemotes. It keeps the first
  # remote it sees for a gem, and Bundler writes those sections before GEM
  # ones, so a leak replaces a gem's real rubygems.org remote.
  test_buildGemRemotes_excludes_git_path =
    let
      result = buildGemRemotes (parseLockfileContent gitPathLockfile).gemSections;
    in
    assertEq "buildGemRemotes: git gem absent" (result ? errgonomic) false
    && assertEq "buildGemRemotes: path gem absent" (result ? hello_gem) false
    && assertEq "buildGemRemotes: git dependency line absent" (result ? "concurrent-ruby") false
    && assertEq "buildGemRemotes: real GEM gem present" result.rake "https://rubygems.org";

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
          rake = "https://rubygems.org";
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
          errgonomic = "https://rubygems.org";
        };
        gemGroups = {
          errgonomic = [ "default" ];
        };
        gitSections = fixtureGitSections;
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

  # A lockfile with no GIT or PATH section must give the same result as
  # before. examples/simple, examples/medium and test/rails all rely on it.
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
          rake = "https://rubygems.org";
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
    # parseSpecLine
    && test_parseSpecLine_simple
    && test_parseSpecLine_platform
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
    # parseSectionBody
    && test_parseSectionBody_duplicate_key_throws
    # parseLockfileContent
    && test_parseLockfileContent
    && test_parseLockfileContent_missing_checksums
    && test_parseLockfileContent_multi_remote
    # parseLockfileContent: missing GEM section
    && test_parseLockfileContent_missing_gem_section
    && test_parseLockfileContent_empty_gem_specs
    # parseLockfileContent: git/path gems
    && test_parseLockfileContent_skips_hashless
    && test_parseLockfileContent_git_path_sections
    && test_parseLockfileContent_unexplained_hashless_throws
    && test_parseLockfileContent_plugin_source_throws
    # buildGemRemotes
    && test_buildGemRemotes
    && test_buildGemRemotes_first_writer_wins
    && test_buildGemRemotes_excludes_git_path
    # mergeGemMetadata
    && test_mergeGemMetadata
    && test_mergeGemMetadata_missing_group_defaults_empty
    # mergeGemMetadata: git and path sources
    && test_mergeGemMetadata_git_and_path
    && test_mergeGemMetadata_path_dot_remote
    && test_mergeGemMetadata_duplicate_name_throws
    && test_mergeGemMetadata_path_without_root_throws
    && test_mergeGemMetadata_no_git_path_unchanged;

in
allTests
