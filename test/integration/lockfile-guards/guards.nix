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

in
test_valid_lockfile_evaluates && test_unexplained_hashless_rejected && test_plugin_source_rejected
