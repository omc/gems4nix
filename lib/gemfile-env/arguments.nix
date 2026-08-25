# Argument-surface strictness.
#
# A function whose pattern ends in `...` accepts anything and ignores what it
# does not declare. For gemfileEnv that turns "repinned to a version without
# this feature" into a successful evaluation followed by a failure two layers
# down — a 401 at fetch time for a `credentials` nobody read. These helpers
# make the unrecognised argument the error instead.

{ lib }:

rec {
  # Argument names `args` supplies that `f` does not declare, sorted.
  #
  #   unknownArgs ({ a, b ? 1 }: a) { a = 1; z = 2; }
  #   => [ "z" ]
  unknownArgs =
    f: args:
    builtins.attrNames (builtins.removeAttrs args (builtins.attrNames (builtins.functionArgs f)));

  # `value`, unless `args` carries a name `f` does not declare, in which case a
  # throw naming the offenders and the accepted set.
  #
  # `f` is passed separately from `value` so a function can gate its own body:
  # bind it in a `let` and hand `checkArgs` its own name.
  checkArgs =
    fname: f: args: value:
    let
      unknown = unknownArgs f args;
      quoted = names: lib.concatMapStringsSep ", " (n: "'${n}'") names;
      accepted = builtins.attrNames (builtins.functionArgs f);
    in
    if unknown == [ ] then
      value
    else
      throw ''
        ${fname}: unknown argument${lib.optionalString (builtins.length unknown > 1) "s"} ${quoted unknown}.
        Accepted arguments: ${lib.concatStringsSep ", " accepted}.
      '';
}
