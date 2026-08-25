# Does a lockfile gems4nix cannot honour fail at evaluation, or does the gem
# quietly leave the environment?
#
# A dropped gem is the failure shape worth guarding: the Nix build goes green,
# and the missing gem surfaces much later as a LoadError, or as a Bundler error
# naming a layer that is not at fault.
#
# The valid lockfile is the positive control. Without it a throw test proves
# nothing, because any error anywhere in the body would satisfy it.
#
# Every assertion goes through `drvPath`: a single shallow attribute, and the
# one that forces the parsed lockfile. `name` does not. deepSeq on a derivation
# recurses forever, and the stack overflow that produces is not catchable, so
# tryEval-based helpers cannot see past it.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq assertThrows;

  drvPathFor =
    lockfile:
    (gemfileEnv {
      name = "lockfile-guards";
      gemfile = ./Gemfile;
      gemfileLock = lockfile;
      groups = [ "default" ];
      platforms = [ "ruby" ];
    }).drvPath;

  test_valid_lockfile_evaluates =
    assertEq "a lockfile with a hash for every gem builds an environment"
      (pkgs.lib.hasSuffix ".drv" (drvPathFor ./Gemfile.lock))
      true;

  test_unexplained_hashless_rejected = assertThrows "a hashless CHECKSUMS line with no GIT or PATH source is an evaluation error" (
    drvPathFor ./unexplained-hashless.lock
  );

  test_plugin_source_rejected = assertThrows "a PLUGIN SOURCE section is an evaluation error" (
    drvPathFor ./plugin-source.lock
  );

  test_duplicate_gem_across_sections_rejected = assertThrows "a gem two GEM sections both provide is an evaluation error" (
    drvPathFor ./duplicate-gem-remotes.lock
  );

  # A section with several remotes: every one of them has to reach the fetch,
  # in the order the lockfile lists them, or a gem only the other remote
  # carries fails to download with nothing saying a remote was dropped.
  test_two_remotes_reach_the_fetch =
    let
      env = gemfileEnv {
        name = "lockfile-guards-two-remotes";
        gemfile = ./Gemfile;
        gemfileLock = ./two-remotes.lock;
        groups = [ "default" ];
        platforms = [ "ruby" ];
      };
    in
    assertEq "both of a section's remotes are fetched from, in lockfile order"
      (pkgs.lib.concatMap (gem: gem.src.urls) env.paths)
      [
        "https://gems.example.invalid/gems/rake-13.3.1.gem"
        "https://rubygems.org/gems/rake-13.3.1.gem"
      ];

  # The Ruby version is written against pkgs.ruby rather than fixed in a
  # fixture, so a nixpkgs that moves to another Ruby cannot turn the
  # same-ABI case into a cross-ABI one and quietly invert both tests.
  rubyAbi = pkgs.lib.concatStringsSep "." (
    pkgs.lib.lists.take 2 (pkgs.lib.splitString "." pkgs.ruby.version)
  );

  lockfileWithRubyVersion =
    version:
    pkgs.writeText "ruby-version-${version}.lock" ''
      ${builtins.readFile ./Gemfile.lock}
      RUBY VERSION
         ruby ${version}
    '';

  test_ruby_version_across_the_abi_rejected = assertThrows "a lockfile resolved against another Ruby ABI is an evaluation error" (
    drvPathFor (lockfileWithRubyVersion "2.7.8")
  );

  # Below the ABI nothing moves, and the requirement Bundler enforces is the
  # Gemfile's rather than this value, so the environment still builds.
  test_ruby_version_below_the_abi_still_builds =
    assertEq "a lockfile resolved against another teeny of the same Ruby still builds"
      (pkgs.lib.hasSuffix ".drv" (drvPathFor (lockfileWithRubyVersion "${rubyAbi}.999")))
      true;

in
test_valid_lockfile_evaluates
&& test_unexplained_hashless_rejected
&& test_plugin_source_rejected
&& test_duplicate_gem_across_sections_rejected
&& test_two_remotes_reach_the_fetch
&& test_ruby_version_across_the_abi_rejected
&& test_ruby_version_below_the_abi_still_builds
