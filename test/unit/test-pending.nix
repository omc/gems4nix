# Pending tests: known limitations, written as the behaviour we want.
#
# Every test here fails today. That is the point. Each one names a limitation,
# asserts what the code should do instead, and says what a fix would have to
# change. When someone makes one pass, they move it into the `allTests`
# conjunction of the file it belongs to and delete it from here.
#
# These are not part of any gating suite. `nix flake check` and CI never run
# them, so they cannot turn the build red.
#
# Run one:
#   nix eval --file test/unit/test-pending.nix pending.test_NAME
#
# List them:
#   nix eval --file test/unit/test-pending.nix --apply 'x: builtins.attrNames x.pending'
#
# Some of these have a twin in a gating file that pins the current, wrong
# behaviour so CI has something to run. `test-filter.nix` holds
# `test_ruby_only_nokogiri_drops_build_deps`, the twin of the group-filter test
# below. Where a twin exists, the comment here names it, and a fix flips both
# at once. Not every limitation has one.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
  lib = nixpkgs.lib;

  parserHelpers = import ../../lib/gemfile-env/parser-helpers.nix { inherit lib; };
  filterHelpers = import ../../lib/gemfile-env/filter-helpers.nix { inherit lib; };

  inherit (parserHelpers) parseGitSection parseLockfileContent;
  inherit (filterHelpers)
    filterGroup
    filterPlatform
    resolvePlatforms
    applyGemConfigs
    platformsForSystem
    ;
  inherit (import ../test-helpers.nix) assertEq assertThrows;

  gitSource = {
    type = "git";
    url = "https://github.com/omc/errgonomic.git";
    rev = "f06314af89209f855019219fd198513855be0fd5";
    fetchSubmodules = false;
    ref = null;
    branch = "main";
    tag = null;
  };

in
{
  pending = {

    # LIMITATION (TODO #5)
    # A gem that belongs to no group never reaches the environment. The group
    # filter drops it, and nothing reports the loss. gem-groups.rb gives the
    # "default" group to every gem the Gemfile names, so a git gem written in
    # the Gemfile is safe. A git gem reached only through another gem's
    # dependency list can miss out, and then `require` fails at runtime.
    #
    # TWIN: test-filter.nix, test_ruby_only_nokogiri_drops_build_deps, which
    # pins the drop this test wants removed.
    #
    # THEORIZED FIX (TODO #12 and #14)
    # Add a step after the group filter that pulls back every gem a kept gem
    # depends on, whatever groups it holds. nixpkgs does this in
    # bundled-common/functions.nix with a fixpoint it calls converge. It needs
    # dependency edges, which #12 and #14 add to the parsed gems. Parsing the
    # DEPENDENCIES section as well (#14) is what then makes gem-groups.rb
    # unnecessary.
    #
    # This test names that step `expandDependencies` and fails today because no
    # such function exists. Do not make it pass by loosening `filterGroup` to
    # keep every gem with no groups: that keeps orphans nothing depends on, and
    # the point is to follow the edges.
    test_transitive_git_gem_survives_group_filter =
      let
        # rails is wanted and depends on errgonomic. errgonomic belongs to no
        # group, because gem-groups.rb never reached it.
        rails = {
          gemName = "rails";
          platform = "ruby";
          version = "8.1.2";
          groups = [ "default" ];
          dependencies = [ "errgonomic" ];
          source = {
            type = "gem";
            sha256 = "aaaa";
            remotes = [ "https://rubygems.org" ];
          };
        };
        errgonomic = {
          gemName = "errgonomic";
          platform = "ruby";
          version = "0.5.1";
          groups = [ ];
          dependencies = [ ];
          source = gitSource;
        };

        allGems = [
          rails
          errgonomic
        ];
        platforms = platformsForSystem "aarch64-darwin";
        afterGroup = builtins.filter (filterGroup [ "default" ]) allGems;

        # The missing step. It takes every gem and the ones the group filter
        # kept, and returns those plus everything they depend on.
        expanded = filterHelpers.expandDependencies allGems afterGroup;

        afterPlatform = builtins.filter (filterPlatform platforms) expanded;
        kept = builtins.attrNames (resolvePlatforms platforms afterPlatform);
      in
      assertEq "pending: a git gem reached through a dependency must survive the group filter"
        (builtins.elem "errgonomic" kept)
        true;

    # LIMITATION (TODO #9)
    # A git gem with a C extension cannot compile against a sibling gem's
    # headers. buildRubyGem takes those through `gemPath`, and we never set it.
    # nokogiri needs mini_portile2 this way. No example covers it.
    #
    # `gemPath` needs a list of each gem's dependencies, and we hold none. The
    # lockfile carries them: under every gem in a `specs:` block, the 6-space
    # lines name what that gem needs. parseGitSection reads those lines and
    # throws them away.
    #
    # THEORIZED FIX (TODO #12 and #14, then #9)
    # Keep the 6-space lines instead of dropping them, and give each gem a
    # `dependencies` list. default.nix can then map those names to the
    # derivations it already built and pass them as `gemPath`. This test asks
    # for the first half, which the second half needs.
    #
    # Adding the field changes the shape of a parsed gem, so two tests in
    # test-parser.nix must change with it: `test_parseGitSection_basic` and
    # `test_parsePathSection_basic` both compare `gems` for exact equality.
    test_git_section_records_dependencies =
      let
        result = parseGitSection [
          "  remote: https://github.com/omc/errgonomic.git"
          "  revision: f06314af89209f855019219fd198513855be0fd5"
          "  branch: main"
          "  specs:"
          "    errgonomic (0.5.1)"
          "      concurrent-ruby (~> 1.0)"
        ];
        gem = builtins.elemAt result.gems 0;
      in
      assertEq "pending: a git gem must record the dependencies listed under it" (gem.dependencies or null
      ) [ "concurrent-ruby" ];

    # LIMITATION
    # buildGem in default.nix sets `src` on every git and path gem, and sets
    # the phases that unpack and build it. A gemConfig entry that sets `src`,
    # `unpackPhase` or `buildPhase` either replaces ours or gets replaced, and
    # neither the user nor the build says so. The result is a gem built from
    # the wrong source, or one built with no git index and therefore no files.
    #
    # `preBuild` and `postInstall` are not affected. The wrapper keeps a user
    # value for those and adds its own after it.
    #
    # THEORIZED FIX
    # Refuse the combination. A gemConfig entry may not set `src`,
    # `unpackPhase` or `buildPhase` on a gem whose source is git or path,
    # because the wrapper owns how such a gem is fetched and unpacked. Throw
    # and name both the gem and the key. Do not merge the two: two definitions
    # of `src` have no sensible middle, and quietly picking one is the failure
    # we are removing.
    #
    # Put the guard in `applyGemConfigs`. It is the one pure function that sees
    # both the gem's `source` and the config entry's output, so a test can
    # reach it without nixpkgs. A guard inside buildGem would fix the bug too,
    # but this test would stay red, and the next reader would think it broken.
    test_gemconfig_cannot_take_over_a_git_gem_build =
      let
        errgonomic = {
          gemName = "errgonomic";
          platform = "ruby";
          version = "0.5.1";
          groups = [ "default" ];
          source = gitSource;
        };
        configSetting = key: value: {
          errgonomic = attrs: { ${key} = value; };
        };
      in
      assertThrows "pending: a gemConfig entry must not replace the src of a git gem" (
        applyGemConfigs (configSetting "src" "/some/other/tree") errgonomic
      )
      && assertThrows "pending: a gemConfig entry must not replace the unpackPhase of a git gem" (
        applyGemConfigs (configSetting "unpackPhase" "true") errgonomic
      )
      && assertThrows "pending: a gemConfig entry must not replace the buildPhase of a git gem" (
        applyGemConfigs (configSetting "buildPhase" "true") errgonomic
      )
      # ...and the keys the wrapper composes must keep working.
      &&
        assertEq "pending: a gemConfig entry may still set preBuild on a git gem"
          (applyGemConfigs (configSetting "preBuild" "echo hi") errgonomic).preBuild
          "echo hi";

    # LIMITATION (TODO #16)
    # A Gemfile.lock ends with a RUBY VERSION section naming the Ruby it was
    # resolved against. We never read it, and gemfileEnv never checks it
    # against the ruby it builds with. The two drift in silence: a lockfile
    # saying 3.4.9 built against nixpkgs 24.11 gives a whole environment
    # compiled for 3.3.5, and the first sign of trouble is a runtime error in
    # a gem that expected the newer stdlib.
    #
    # THEORIZED FIX
    # Read the section here and return it from parseLockfileContent, then
    # compare it to `ruby.version` in default.nix. This test asks for the
    # parser half only; the comparison has no pure test.
    #
    # Note the three-space indent on the value. Bundler writes RUBY VERSION
    # and BUNDLED WITH that way, unlike the two-space option lines elsewhere.
    # A helper that assumes two spaces reads the version as " ruby 3.4.9".
    #
    # Return null when the section is absent. It is optional, and a lockfile
    # without it is not an error.
    test_parseLockfileContent_reads_the_ruby_version =
      let
        lockfile = ''
          GEM
            remote: https://rubygems.org/
            specs:
              rake (13.0.6)

          CHECKSUMS
            rake (13.0.6) sha256=aaaa

          RUBY VERSION
             ruby 3.4.9

          BUNDLED WITH
             2.7.2
        '';
        result = parseLockfileContent lockfile;
      in
      assertEq "pending: parseLockfileContent must report the locked ruby version" (result.rubyVersion
        or null
      ) "3.4.9";
  };

  # Limitations with no test. Each says why, and what a test would need.
  #
  # Read them:
  #   nix eval --file test/unit/test-pending.nix nonTests --json
  nonTests = {

    git_gems_are_invisible_to_bundler_setup = ''
      LIMITATION (TODO #10, detail in TODO #13)
      We install a git gem as an ordinary gem, so plain `require` finds it
      through the GEM_PATH. Bundler does not. Bundler::Source::Git#load_spec_files
      looks in GEM_HOME/bundler/gems/<name>-<shortrev> and nowhere else, and we
      never write that directory. So an app booting with `require "bundler/setup"`
      cannot use a git gem from us. That is every stock Rails app.

      Gems from GEM and PATH sections are unaffected. Bundler resolves a
      rubygems gem through Gem::Specification, which reads the GEM_PATH, and it
      reads a path gem's gemspec out of its source directory. Only GIT sources
      break. Vendoring the gem as a PATH source is the workaround until #10.

      REPRO
      Against examples/complex, whose errgonomic comes from a GIT section.
      Build the environment, then with GEM_PATH pointing into it:

        ruby -e 'require "errgonomic"'
        => loads

        BUNDLE_GEMFILE=examples/complex/Gemfile ruby -e 'require "bundler/setup"'
        => bundler/source/git.rb:236:in `rescue in load_spec_files':
           https://github.com/omc/errgonomic.git (at main@f06314a) is not yet
           checked out. Run `bundle install` first. (Bundler::GitError)

      The same command with only the PATH gem in the Gemfile succeeds, with no
      `bundle install` first. That asymmetry is the whole finding.

      WHY NO TEST
      Nothing here is a branch in our code, and no assertion in a Nix
      expression can reach it. Showing it needs a built environment, a ruby,
      and Bundler reading a Gemfile. Pure evaluation has none of those.

      WHAT A TEST WOULD LOOK LIKE
      A second check in examples/complex beside `validate`, running
      `require "bundler/setup"` against the built environment with BUNDLE_GEMFILE
      set. It fails today. Write it when #10 lands, as the thing that proves #10
      worked, and promote it out of this file then.
    '';

    non_github_git_servers = ''
      LIMITATION
      We fetch a git gem by its locked revision alone. Some git servers refuse
      to send a revision that is not the tip of a branch, because
      uploadpack.allowAnySHA1InWant is off by default. Fetching every ref works
      around this, and it is what we do. Only GitHub has been tried.

      WHY NO TEST
      Whether a given server serves such a revision is the server's behaviour,
      not ours. A test would need a real GitLab, Gitea and Forgejo host, each
      with a gem whose locked revision sits behind the branch tip, and the
      network to reach them. Pure evaluation cannot see any of that, and a fake
      would only test the fake.

      Our own part is one line: `allRefs = true` in mkGemSrc. A pure test could
      pin it if mkGemSrc took its fetcher as an argument. That would prove we
      ask for every ref, not that asking is enough.

      WHAT A TEST WOULD LOOK LIKE
      A NixOS VM test for each server: start the server, push a gem repository,
      commit twice so the locked revision is not the tip, then build a
      gemfileEnv against a lockfile pinning the older revision. Runs on Linux
      only, and needs the servers packaged in nixpkgs.
    '';

    eval_time_git_fetch = ''
      LIMITATION
      builtins.fetchGit runs while Nix evaluates the flake. Any command that
      evaluates an output holding a git gem needs the network, and needs
      credentials for a private repository. Its result is not a fixed-output
      derivation, so no binary cache can serve it and every new machine fetches
      again. gemSrcOverrides exists to replace it.

      WHY NO TEST
      There is nothing to assert. This is how builtins.fetchGit behaves, not a
      branch in our code. A test that fetched would prove only that the network
      was up.

      WHAT A TEST WOULD LOOK LIKE
      Evaluate a gemfileEnv with a git gem inside a sandbox with no network and
      confirm the failure, then evaluate the same one with gemSrcOverrides set
      and confirm it succeeds. That needs control over the evaluator's network
      access, which a Nix expression does not have. It belongs in CI as two
      shell steps, one of them expected to fail.
    '';
  };
}
