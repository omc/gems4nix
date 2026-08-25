# Does gemSrcOverrides reach the build, and does a name it cannot match throw?
#
# The point of the argument is to avoid builtins.fetchGit, which needs the
# network at evaluation time and produces a path no binary cache can serve. An
# override that is quietly ignored leaves the user with the fetch they were
# replacing, so an unmatched name has to be an error.
#
# A path gem stands in for a git gem here. The two take the same route through
# the build wrapper, and a path source needs no network. `gemGroups` is
# supplied so the check evaluates purely, with no Bundler IFD.
#
# Every assertion goes through `drvPath`: a single shallow attribute, and the
# one that forces the source. deepSeq on a derivation recurses forever, and the
# stack overflow that produces is not catchable.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq assertThrows;

  drvPathWith =
    overrides:
    (gemfileEnv {
      name = "gem-src-overrides";
      gemfile = ./Gemfile;
      gemfileLock = ./Gemfile.lock;
      groups = [ "default" ];
      platforms = [ "ruby" ];
      gemGroups = {
        tiny_gem = [ "default" ];
      };
      gemSrcOverrides = overrides;
    }).drvPath;

  # Any directory in the store will do: the assertion is that the src changed,
  # not that this particular tree builds.
  replacement = ./vendor;

in
assertEq "an override for a path gem changes the environment it produces" (
  drvPathWith { } != drvPathWith { tiny_gem = replacement; }
) true
&&
  assertEq "an override given as a function matches the same value passed directly"
    (drvPathWith { tiny_gem = replacement; })
    (drvPathWith {
      tiny_gem = _source: replacement;
    })
&&
  assertThrows "an override naming a gem with no GIT or PATH source is an evaluation error"
    (drvPathWith {
      rake = replacement;
    })
