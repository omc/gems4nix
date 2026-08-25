# Unit tests for arguments.nix and gemfileEnv's public argument surface
#
# Accepts { lib }: so it can be imported by both:
#   - The standalone wrapper (test-arguments.nix) for `nix eval --file` usage
#   - The root flake.nix checks via `import ./test-arguments-logic.nix { lib = pkgs.lib; }`
#
# Returns: true (all assertions pass) or throws with a descriptive message.

{ lib }:

let
  arguments = import ../../lib/gemfile-env/arguments.nix { inherit lib; };
  inherit (arguments) unknownArgs checkArgs;
  inherit (import ../helpers.nix) assertEq assertThrows;

  toy =
    {
      alpha,
      beta ? 2,
    }:
    alpha + beta;

  # ── unknownArgs ───────────────────────────────────────────────

  test_unknownArgs_none = assertEq "a call using only declared arguments has none unknown" (
    unknownArgs
    toy
    {
      alpha = 1;
    }
  ) [ ];

  test_unknownArgs_names_the_argument = assertEq "the offending argument is named" (unknownArgs toy {
    alpha = 1;
    gamma = 3;
  }) [ "gamma" ];

  test_unknownArgs_names_all_of_them =
    assertEq "every offending argument is named"
      (unknownArgs toy {
        alpha = 1;
        delta = 4;
        gamma = 3;
      })
      [
        "delta"
        "gamma"
      ];

  test_unknownArgs_defaulted_arg_is_known = assertEq "an argument with a default is still declared" (
    unknownArgs
    toy
    {
      alpha = 1;
      beta = 9;
    }
  ) [ ];

  # ── checkArgs ─────────────────────────────────────────────────

  test_checkArgs_passes_value_through = assertEq "a clean call gets its value" (checkArgs "toy" toy {
    alpha = 1;
  } "the body") "the body";

  test_checkArgs_throws_on_unknown = assertThrows "an unknown argument is rejected" (
    checkArgs "toy" toy {
      alpha = 1;
      gamma = 3;
    } "the body"
  );

  # The guard must not force the body it guards, or a caller with a bad
  # argument gets whatever the body fails on first instead of the real error.
  test_checkArgs_does_not_force_the_body = assertThrows "the guarded body is never forced" (
    checkArgs "toy" toy {
      alpha = 1;
      gamma = 3;
    } (throw "the body must not be forced")
  );

  # ── gemfileEnv's public surface ───────────────────────────────
  #
  # The nixpkgs arguments are never forced: nothing below applies the function.

  gemfileEnv = import ../../lib/gemfile-env/default.nix {
    inherit lib;
    stdenv = throw "test: stdenv must not be forced";
    ruby = throw "test: ruby must not be forced";
    callPackage = throw "test: callPackage must not be forced";
    fetchurl = throw "test: fetchurl must not be forced";
    buildRubyGem = throw "test: buildRubyGem must not be forced";
    defaultGemConfig = throw "test: defaultGemConfig must not be forced";
    buildEnv = throw "test: buildEnv must not be forced";
    gitMinimal = throw "test: gitMinimal must not be forced";
  };

  acceptedArgs = builtins.attrNames (builtins.functionArgs gemfileEnv);

  # Changing this list changes what a pinned consumer may pass.
  test_accepted_args = assertEq "gemfileEnv's accepted arguments" acceptedArgs [
    "credentials"
    "debug"
    "extraFiles"
    "gemConfig"
    "gemGroups"
    "gemSrcOverrides"
    "gemfile"
    "gemfileLock"
    "gemspec"
    "groups"
    "name"
    "platforms"
    "root"
    "ruby"
  ];

  # Every argument name a pinned consumer repository passes today.
  consumerCallSites = {
    sprout = [
      "name"
      "gemfile"
      "gemfileLock"
      "credentials"
    ];
    errgonomic = [
      "name"
      "gemfile"
      "gemfileLock"
      "gemspec"
      "extraFiles"
      "gemGroups"
    ];
    intrinsic-rails = [
      "name"
      "gemfile"
      "gemfileLock"
      "gemspec"
      "extraFiles"
      "gemGroups"
    ];
    cio = [
      "name"
      "gemfile"
      "gemfileLock"
      "ruby"
    ];
  };

  test_consumer_call_sites_accepted = lib.all (
    repo:
    assertEq "${repo}'s call site has no argument gemfileEnv would reject" (unknownArgs gemfileEnv (
      lib.genAttrs consumerCallSites.${repo} (_: null)
    )) [ ]
  ) (builtins.attrNames consumerCallSites);

  # A consumer repinned to a version predating a feature must be told which
  # argument went unread, rather than evaluating and failing at fetch time.
  test_gemfileEnv_names_the_unknown_argument =
    assertEq "gemfileEnv names the argument it does not accept"
      (unknownArgs gemfileEnv {
        name = "app";
        gemfile = "Gemfile";
        gemfileLock = "Gemfile.lock";
        credential = { };
      })
      [ "credential" ];

  allTests =
    test_unknownArgs_none
    && test_unknownArgs_names_the_argument
    && test_unknownArgs_names_all_of_them
    && test_unknownArgs_defaulted_arg_is_known
    && test_checkArgs_passes_value_through
    && test_checkArgs_throws_on_unknown
    && test_checkArgs_does_not_force_the_body
    && test_accepted_args
    && test_consumer_call_sites_accepted
    && test_gemfileEnv_names_the_unknown_argument;

in
allTests
