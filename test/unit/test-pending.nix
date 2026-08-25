# Pending tests: known limitations (standalone wrapper)
#
# Run the ledger: nix eval --file test/unit/test-pending.nix ledger
# Returns: true (every pending test still fails) or throws naming the one that
# started passing.
#
# This is a thin wrapper around test-pending-logic.nix that bootstraps nixpkgs
# via fetchTarball. The logic file accepts { lib }: and is also imported
# directly by the root flake.nix checks.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
in
import ./test-pending-logic.nix { lib = nixpkgs.lib; }
