# Does gemfileEnv actually reject an argument it does not understand?
#
# This needs a real nixpkgs so the accepted call is a genuine positive control:
# it evaluates to a real environment. Without that control a rejection test
# proves nothing, because any throw anywhere in the body would satisfy it.
#
# Every assertion goes through a single shallow attribute. deepSeq on a
# derivation recurses forever, and the stack overflow that produces is not
# catchable, so tryEval-based helpers cannot see past it.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq assertThrows;

  args = {
    name = "argument-strictness";
    gemfile = ../platform-gems/Gemfile;
    gemfileLock = ../platform-gems/Gemfile.lock;
    groups = [ "default" ];
    platforms = [ "ruby" ];
  };

  test_accepted_call_evaluates =
    assertEq "a call using only declared arguments builds an environment"
      (pkgs.lib.hasPrefix "argument-strictness" (gemfileEnv args).name)
      true;

  test_unknown_argument_rejected =
    assertThrows "an unknown argument is an evaluation error"
      (gemfileEnv (args // { credentialz = { }; })).name;

  # Every argument a pinned consumer passes today must survive.
  test_consumer_arguments_accepted =
    assertEq "the pinned consumers' arguments are all still understood"
      (pkgs.lib.hasPrefix "argument-strictness"
        (gemfileEnv (
          args
          // {
            credentials = { };
            gemspec = null;
            extraFiles = { };
            gemGroups = null;
            inherit (pkgs) ruby;
          }
        )).name
      )
      true;

in
test_accepted_call_evaluates && test_unknown_argument_rejected && test_consumer_arguments_accepted
