# Pending tests: known limitations, written as the behaviour we want.
#
# Every test under `pending` fails today. That is the point. Each one names a
# limitation, asserts what the code should do instead, and says what a fix
# would have to change. When someone makes one pass, they move it into the
# `allTests` conjunction of the file it belongs to and delete it from here.
#
# The `ledger` this file returns asserts that each one still fails. It runs in
# `nix flake check` like any other suite, so a limitation that quietly stops
# being one turns the build red and names itself, rather than sitting here
# unread. A ledger nothing evaluates rots.
#
# Accepts { lib }: so it can be imported by both the standalone wrapper
# (test-pending.nix) and the root flake.nix checks.
#
# Run one:
#   nix eval --file test/unit/test-pending.nix pending.test_NAME
#
# List them:
#   nix eval --file test/unit/test-pending.nix --apply 'x: builtins.attrNames x.pending'
#
# Read the limitations that have no test:
#   nix eval --file test/unit/test-pending.nix nonTests --json

{ lib }:

let
  parserHelpers = import ../../lib/gemfile-env/parse.nix { inherit lib; };
  filterHelpers = import ../../lib/gemfile-env/resolve.nix { inherit lib; };

  inherit (parserHelpers) parseLockfile;
  inherit (filterHelpers) applyGemConfigs;
  inherit (import ../helpers.nix) assertEq assertThrows expectedFailure;

  gitSource = {
    type = "git";
    url = "https://github.com/omc/errgonomic.git";
    rev = "f06314af89209f855019219fd198513855be0fd5";
    fetchSubmodules = false;
    ref = null;
    branch = "main";
    tag = null;
  };

  pending = {

    # LIMITATION
    # The git/path wrapper in default.nix sets `src` on every git and path gem,
    # and sets the phases that unpack and build it. A gemConfig entry that sets
    # `src`, `unpackPhase` or `buildPhase` either replaces the wrapper's value
    # or gets replaced by it, and neither the user nor the build says so. The
    # result is a gem built from the wrong source, or one built with no git
    # index and therefore no files.
    #
    # `preBuild` and `postInstall` are composed rather than replaced, so a
    # caller keeps both. The ordering is not symmetric and cannot be: the
    # wrapper's git-init runs after a caller's `preBuild`, so it indexes
    # whatever that produced, while the empty-gem check runs before a caller's
    # `postInstall`, so an `exit` there cannot skip it.
    #
    # A gemConfig entry whose `preBuild` exits ends the build before the gem
    # is ever built, and the empty-gem check does not catch that: no
    # installPhase runs, so no postInstall runs either. Nix rejects it instead,
    # because the builder returned without creating $out. The message names the
    # missing output path and nothing else, so it says which gem failed but not
    # why.
    #
    # Running the empty-gem check first also forecloses one thing the old
    # ordering allowed: backfilling files into an otherwise-empty gem from a
    # caller's `postInstall`. Nothing in lib/gemfile-env does that, and an
    # unskippable check is worth more than the pattern, but it is a tradeoff
    # rather than a free win.
    #
    # THEORIZED FIX
    # Refuse the combination. A gemConfig entry may not set `src`,
    # `unpackPhase` or `buildPhase` on a gem whose source is git or path,
    # because the wrapper owns how such a gem is fetched and unpacked. Throw
    # and name both the gem and the key. Do not merge the two: two definitions
    # of `src` have no sensible middle, and quietly picking one is the failure
    # being removed.
    #
    # Put the guard in `applyGemConfigs`. It is the one pure function that sees
    # both the gem's `source` and the config entry's output, so a test can
    # reach it without nixpkgs. A guard inside the wrapper would fix the bug
    # too, but this test would stay red, and the next reader would think it
    # broken.
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

    # LIMITATION
    # A Gemfile.lock ends with a RUBY VERSION section naming the Ruby it was
    # resolved against. gems4nix never reads it, and gemfileEnv never checks it
    # against the ruby it builds with. The two drift in silence: a lockfile
    # saying 3.4.9 built against a nixpkgs whose default is 3.3.5 gives a whole
    # environment compiled for the wrong Ruby. What breaks after that has not
    # been measured.
    #
    # THEORIZED FIX
    # Read the section here and return it from parseLockfile, then compare it
    # to `ruby.version` in default.nix. This test asks for the parser half
    # only; the comparison has no pure test.
    #
    # Note the three-space indent on the value. Bundler writes RUBY VERSION and
    # BUNDLED WITH that way, unlike the two-space option lines elsewhere. A
    # helper that assumes two spaces reads the version as " ruby 3.4.9".
    #
    # Return null when the section is absent. It is optional, and a lockfile
    # without it is not an error.
    #
    # The value sometimes carries a patchlevel: examples/complex records
    # `ruby 3.3.10p183`. This test pins the bare form only. Whoever writes the
    # parser decides whether the patchlevel stays in the returned string, and
    # should add the case here once decided.
    test_parseLockfile_reads_the_ruby_version =
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
        result = parseLockfile lockfile;
      in
      assertEq "pending: parseLockfile must report the locked ruby version" (result.rubyVersion or null
      ) "3.4.9";
  };

  # Limitations with no test. Each says why, and what a test would need.
  nonTests = {

    git_gems_with_native_extensions_are_unusable_under_bundler = ''
      LIMITATION
      A git gem gets the bundler/gems/<repo>-<shortrev> checkout Bundler reads
      it from, so `require "bundler/setup"` resolves it. A compiled extension
      inside such a gem does not follow.

      RubyGems installs one to extensions/<arch>/<api>/<gem>-<version>;
      measured against examples/complex, which holds bootsnap-1.23.0,
      msgpack-1.8.0 and nio4r-2.7.5 named exactly that way. Bundler asks a
      git-sourced spec for a different directory: rubygems_ext.rb defines
      extension_dir as extensions_dir joined with
      [source.extension_dir_name, File.basename(full_gem_path)].uniq.join("-"),
      and both of those are the git scope, so it collapses to
      extensions/<arch>/<api>/<repo>-<shortrev>. The two names never meet and
      the .so is absent from the load path.

      This is separate from the gemPath limitation below, which is about a
      build-time header rather than a runtime load path.

      WHY NO TEST
      Both halves are measured, but nothing here has been run end to end: no
      example or fixture has a git gem with a C extension, and inventing one
      means a real repository, since a hand-written lockfile cannot fake a GIT
      section Bundler will accept.

      WHAT A TEST WOULD LOOK LIKE
      A git gem with a trivial C extension in examples/complex, required from
      the bundler-setup check. The fix it would drive is a second symlink
      beside the checkout, from extensions/<arch>/<api>/<repo>-<shortrev> to
      the directory RubyGems wrote. The <arch>/<api> pair is not knowable
      during evaluation, so it has to be globbed in the build.
    '';

    native_extensions_cannot_see_their_siblings = ''
      LIMITATION
      A gem with a C extension that reads another gem's headers at build time
      compiles against nothing. buildRubyGem takes those siblings through
      `gemPath`, and default.nix never sets it. nokogiri wanting mini_portile2
      is the standard case. This is not specific to git gems; a git gem with a
      native extension hits it like any other.

      The dependency edges a fix needs are already parsed. parseDependencies
      reads every `specs:` block, GIT and PATH ones included, into a
      { gemName = [ deps ]; } graph, and default.nix already holds it as
      `depGraph` for the group-filter expansion. What is missing is the second
      use: mapping a gem's dependency names to the derivations already built
      for them and passing that list as `gemPath`.

      WHY NO TEST
      `gemPath` is an argument to buildRubyGem, so an assertion about it needs
      a real nixpkgs and a real derivation, not pure evaluation. The failure it
      prevents is a compiler error inside a build, which only a build shows.

      WHAT A TEST WOULD LOOK LIKE
      An integration check building a lockfile that pins ruby-platform nokogiri
      with no precompiled variant, and asserting the build succeeds. It needs a
      lockfile fixture whose nokogiri genuinely compiles from source, and it is
      slow, so it belongs beside the examples rather than in the unit suite.
    '';

    no_end_to_end_groupless_git_gem = ''
      COVERAGE GAP
      Nothing builds a git or path gem that is reachable only through another
      gem's dependency list. Both sources in examples/complex are named in the
      Gemfile's default group, so the group filter would keep them with or
      without expandTransitiveDeps. The property is covered at unit level, in
      test-resolve-logic.nix, and never end to end through the real IFD.

      WHY IT IS HARD, NOT JUST MISSING
      Bundler writes a GIT or PATH section only for a source the Gemfile
      declares, and a declared source is a top-level dependency, which
      gem-groups.rb always gives a group. Measured against examples/complex:
      errgonomic (git) and hello_gem (path) both come back ["default"], while
      mini_portile2 comes back [] — and mini_portile2 is an ordinary GEM gem.
      So the gem the expansion actually rescues is not a git gem at all.

      The remaining way to reach the case is a GIT section providing several
      gems where the Gemfile names a subset and a named one depends on an
      unnamed sibling. A gem in no group that nothing depends on is correctly
      dropped, so that is the whole scenario.

      WHAT A FIXTURE WOULD NEED
      A real git repository holding two gems, one depending on the other, with
      a Gemfile naming only the first. Hand-editing a lockfile to fake the edge
      does not work: `bundle lock` regenerates it and the fixture stops being
      reproducible. That is a new repository, not a change to an example.

      A GIT section supplying two gems is no longer the hard part.
      test/integration/bundler-layout has one, offline, with gemSrcOverrides
      standing in for the fetch, and measured against it the two gems share a
      single bundler/gems/<repo>-<shortrev> directory: each contributes its own
      gemspec and its own files, and buildEnv merges them, which is what a real
      checkout of such a repository looks like. Two gems shipping the same file
      path is the exception, and it fails the environment build with
      `pkgs.buildEnv error: two given paths contain a conflicting subpath`.
      What is still missing is the group edge, and that needs the real IFD
      rather than the gemGroups override the fixture uses.
    '';

    non_github_git_servers = ''
      LIMITATION
      gems4nix fetches a git gem by its locked revision alone. Some git servers
      refuse to send a revision that is not the tip of a branch, because
      uploadpack.allowAnySHA1InWant is off by default. Fetching every ref works
      around this, and it is what mkGemSrc does. Only GitHub has been tried.

      WHY NO TEST
      Whether a given server serves such a revision is the server's behaviour,
      not gems4nix's. A test would need a real GitLab, Gitea and Forgejo host,
      each with a gem whose locked revision sits behind the branch tip, and the
      network to reach them. Pure evaluation cannot see any of that, and a fake
      would only test the fake.

      gems4nix's own part is one line: `allRefs = true` in mkGemSrc. A pure
      test could pin it if mkGemSrc took its fetcher as an argument. That would
      prove it asks for every ref, not that asking is enough.

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
      branch in gems4nix's code. A test that fetched would prove only that the
      network was up.

      WHAT A TEST WOULD LOOK LIKE
      Evaluate a gemfileEnv with a git gem inside a sandbox with no network and
      confirm the failure, then evaluate the same one with gemSrcOverrides set
      and confirm it succeeds. That needs control over the evaluator's network
      access, which a Nix expression does not have. It belongs in CI as two
      shell steps, one of them expected to fail.
    '';

    private_git_remotes_depend_on_the_invoking_user = ''
      LIMITATION
      A private GIT remote is fetched by builtins.fetchGit, which shells out to
      the user's own git. It therefore reads that user's git configuration and
      credentials, and nothing gems4nix declares reaches it. A
      url.<ssh>.insteadOf rewrite works. A bare https remote fails with
      `could not read Username for 'https://github.com'`. Nix's own
      access-tokens and netrc-file settings configure Nix's downloader, not
      this git, so neither applies.

      This is a different axis from gemfileEnv's `credentials` argument, which
      covers private gem *registries* fetched over fetchurl. A private git
      remote and a private registry share no machinery.

      WHY NO TEST
      The behaviour under test is the evaluating user's git configuration. A
      Nix expression cannot read it, cannot vary it, and a test that fetched
      would assert against whatever the machine running it happens to have.

      WHAT A TEST WOULD LOOK LIKE
      Two CI steps against a private repository: one with the ssh rewrite in
      place, expected to succeed, and one with a bare https remote and no
      credentials, expected to fail with `could not read Username`. Both need a
      private repository and a machine whose git configuration the test owns.
    '';
  };

  # Each pending test must still fail. When one starts passing, expectedFailure
  # throws and names it, which is the reminder to promote it.
  ledger = lib.all (name: expectedFailure name pending.${name}) (builtins.attrNames pending);

in
{
  inherit ledger pending nonTests;
}
