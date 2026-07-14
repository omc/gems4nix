# Shared test helpers for gems4nix unit tests.
#
# Usage:
#   inherit (import ../helpers.nix) assertEq assertThrows expectedFailure mkGem;

{
  # Assert two values are equal, with a descriptive name on failure.
  assertEq =
    name: actual: expected:
    if actual == expected then
      true
    else
      throw "FAIL: ${name}\n  expected: ${builtins.toJSON expected}\n  actual:   ${builtins.toJSON actual}";

  # Assert that evaluating an expression throws (any error).
  # Uses builtins.tryEval + deepSeq so it catches `throw` but NOT `abort`
  # (e.g., raw builtins.elemAt out-of-bounds). If you need to test that an
  # abort becomes a throw, fix the code first (that's the point).
  assertThrows =
    name: expr:
    let
      result = builtins.tryEval (builtins.deepSeq expr expr);
    in
    if result.success then
      throw "FAIL: ${name}\n  expected an error but got: ${builtins.toJSON result.value}"
    else
      true;

  # Document a known bug. Returns true when the bug still exists (assertion
  # fails as expected). When the bug is fixed, this will throw, reminding you
  # to move the test to allTests as a positive assertion.
  expectedFailure =
    name: expr:
    let
      result = builtins.tryEval (builtins.deepSeq expr expr);
    in
    if !result.success then
      true # bug still present, expected
    else
      throw "expectedFailure: ${name} -- this bug appears to be FIXED! Move this test to allTests.";

  # Minimal gem fixture for testing. Produces a gem attrset with sensible
  # defaults that can be overridden per-test.
  mkGem =
    {
      gemName,
      platform ? "ruby",
      groups ? [ "default" ],
      version ? "1.0.0",
    }:
    {
      inherit
        gemName
        platform
        groups
        version
        ;
      source = {
        sha256 = "fake";
        remotes = [ "https://rubygems.org" ];
        type = "gem";
      };
    };
}
