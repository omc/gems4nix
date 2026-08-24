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
# The sibling files hold the opposite kind of test. `test-filter.nix` has
# `test_ruby_only_nokogiri_drops_build_deps`, which asserts what the code does
# today, wrong as it is, so the suite stays green and gates CI. The two work as
# a pair: the sibling pins the current behaviour, and the test here describes
# the fix. A fix flips both at once.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
  lib = nixpkgs.lib;

  parserHelpers = import ../../lib/gemfile-env/parser-helpers.nix { inherit lib; };
  filterHelpers = import ../../lib/gemfile-env/filter-helpers.nix { inherit lib; };

  inherit (parserHelpers) parseGitSection;
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
    # THEORIZED FIX (TODO #12 and #14)
    # Read the dependency edges out of the lockfile `specs:` blocks and keep
    # any gem a wanted gem depends on, whatever groups it holds. nixpkgs does
    # this in bundled-common/functions.nix with a fixpoint it calls converge.
    # That also removes the need for gem-groups.rb.
    test_transitive_git_gem_survives_group_filter =
      let
        # rails wants errgonomic; errgonomic is in no group because
        # gem-groups.rb did not reach it.
        rails = {
          gemName = "rails";
          platform = "ruby";
          version = "8.1.2";
          groups = [ "default" ];
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
          source = gitSource;
        };

        platforms = platformsForSystem "aarch64-darwin";
        afterGroup = builtins.filter (filterGroup [ "default" ]) [
          rails
          errgonomic
        ];
        afterPlatform = builtins.filter (filterPlatform platforms) afterGroup;
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
    # buildGem in default.nix sets `src`, `preBuild` and `postInstall` on every
    # git and path gem. A gemConfig entry that sets the same keys either
    # replaces ours or gets replaced, and neither the user nor the build says
    # so. The result is a gem built from the wrong source, or one built with no
    # git index and therefore no files.
    #
    # THEORIZED FIX
    # Refuse the combination. A gemConfig entry may not set `src`,
    # `unpackPhase` or `buildPhase` on a gem whose source is git or path,
    # because the wrapper owns how such a gem is fetched and unpacked. Throw
    # and name both the gem and the key. Composition is the wrong answer here:
    # two definitions of `src` have no sensible merge, and quietly choosing one
    # is the failure we are trying to remove.
    #
    # `preBuild` and `postInstall` stay allowed. The wrapper already keeps a
    # user value for those and adds its own after it.
    test_gemconfig_cannot_replace_src_of_a_git_gem =
      let
        errgonomic = {
          gemName = "errgonomic";
          platform = "ruby";
          version = "0.5.1";
          groups = [ "default" ];
          source = gitSource;
        };
        hostileConfig = {
          errgonomic = attrs: {
            src = "/some/other/tree";
          };
        };
      in
      assertThrows "pending: a gemConfig entry must not replace the src of a git gem" (
        applyGemConfigs hostileConfig errgonomic
      );
  };

  # Limitations with no test. Each says why, and what a test would need.
  #
  # Read them:
  #   nix eval --file test/unit/test-pending.nix nonTests --json
  nonTests = {

    non_github_git_servers = ''
      LIMITATION
      We fetch a git gem by its locked revision alone. Some git servers refuse
      to send a revision that is not the tip of a branch, because
      uploadpack.allowAnySHA1InWant is off by default. Fetching every ref works
      around this, and it is what we do. Only GitHub has been tried.

      WHY NO TEST
      The answer depends on the server, not on our code. A test would need a
      real GitLab, Gitea and Forgejo host, each with a gem whose locked
      revision sits behind the branch tip, and the network to reach them. Pure
      evaluation cannot see any of that, and a fake would only test the fake.

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
