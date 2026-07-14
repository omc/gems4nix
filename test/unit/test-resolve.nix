# Unit tests for resolve.nix (standalone wrapper)
#
# Run: nix eval --file test/unit/test-resolve.nix --json
# Returns: true (all assertions pass) or throws with a descriptive message.
#
# This is a thin wrapper around test-resolve-logic.nix that bootstraps nixpkgs
# via fetchTarball. The logic file accepts { lib }: and is also imported
# directly by the root flake.nix checks.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
in
import ./test-resolve-logic.nix { lib = nixpkgs.lib; }
