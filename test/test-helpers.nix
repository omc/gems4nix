# Shared test assertion helpers for gems4nix unit tests.
#
# Usage:
#   inherit (import ../test-helpers.nix) assertEq assertThrows;

{
  # Assert two values are equal, with a descriptive name on failure.
  assertEq = name: actual: expected:
    if actual == expected then true
    else throw "FAIL: ${name}\n  expected: ${builtins.toJSON expected}\n  actual:   ${builtins.toJSON actual}";

  # Assert that evaluating an expression throws (any error).
  # Uses builtins.tryEval + deepSeq so it catches `throw` but NOT `abort`
  # (e.g., raw builtins.elemAt out-of-bounds). If you need to test that an
  # abort becomes a throw, fix the code first (that's the point).
  assertThrows = name: expr:
    let
      result = builtins.tryEval (builtins.deepSeq expr expr);
    in
    if result.success then
      throw "FAIL: ${name}\n  expected an error but got: ${builtins.toJSON result.value}"
    else
      true;
}
