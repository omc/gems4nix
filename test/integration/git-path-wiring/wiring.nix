# Does the build wrapper for a git or path gem wire up the way it claims?
#
# Two properties, both about a caller's gemConfig meeting the wrapper:
#
#   gemSrcOverrides reaches the build, and a name it cannot match throws. The
#   point of the argument is to avoid builtins.fetchGit, which needs the
#   network at evaluation time and produces a path no binary cache can serve.
#   An override that is quietly ignored leaves the caller with the fetch they
#   were replacing.
#
#   The empty-gem check runs before any caller-supplied postInstall. runHook
#   evals a hook in the builder's own shell, so an `exit` in a gemConfig entry
#   ends the build there reporting success, and nothing appended after it runs
#   — not a later line, not a later phase. Ordering is the whole guarantee.
#
# A path gem stands in for a git gem. The two take the same route through the
# wrapper, and a path source needs no network. `gemGroups` is supplied so the
# check evaluates purely, with no Bundler IFD.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq assertThrows;
  inherit (pkgs.lib) hasInfix splitString;

  envWith =
    args:
    gemfileEnv (
      {
        name = "git-path-wiring";
        gemfile = ./Gemfile;
        gemfileLock = ./Gemfile.lock;
        groups = [ "default" ];
        platforms = [ "ruby" ];
        gemGroups = {
          tiny_gem = [ "default" ];
        };
      }
      // args
    );

  drvPathWith = overrides: (envWith { gemSrcOverrides = overrides; }).drvPath;

  # Any directory in the store will do: the assertion is that the src changed,
  # not that this particular tree builds.
  replacement = ./vendor;

  # ── gemSrcOverrides ──────────────────────────────────────────

  test_override_changes_the_environment =
    assertEq "an override for a path gem changes the environment it produces"
      (drvPathWith { } != drvPathWith { tiny_gem = replacement; })
      true;

  test_function_override_matches_a_value =
    assertEq "an override given as a function matches the same value passed directly"
      (drvPathWith { tiny_gem = replacement; })
      (drvPathWith {
        tiny_gem = _source: replacement;
      });

  test_unmatched_override_throws =
    assertThrows "an override naming a gem with no GIT or PATH source is an evaluation error"
      (drvPathWith {
        rake = replacement;
      });

  # ── the empty-gem check cannot be skipped ────────────────────

  userMarker = "gems4nixUserPostInstallRan";
  guardMarker = "installed an empty";

  gemPostInstall =
    (builtins.head
      (envWith {
        gemConfig = {
          tiny_gem = _attrs: {
            postInstall = "echo ${userMarker}";
          };
        };
      }).paths
    ).postInstall;

  test_guard_precedes_a_caller_postInstall =
    assertEq "the empty-gem check runs before a gemConfig postInstall, which could exit"
      (hasInfix guardMarker (builtins.head (splitString userMarker gemPostInstall)))
      true;

  test_caller_postInstall_still_runs =
    assertEq "a gemConfig postInstall is still composed in, not dropped"
      (hasInfix userMarker gemPostInstall)
      true;

in
test_override_changes_the_environment
&& test_function_override_matches_a_value
&& test_unmatched_override_throws
&& test_guard_precedes_a_caller_postInstall
&& test_caller_postInstall_still_runs
