# Unit tests for gemfileEnv's public argument surface (standalone wrapper)
#
# Run: nix eval --file test/unit/test-arguments.nix --json
# Returns: true (all assertions pass) or throws with a descriptive message.
#
# This is a thin wrapper around test-arguments-logic.nix that bootstraps
# nixpkgs via fetchTarball. The logic file accepts { lib }: and is also
# imported directly by the root flake.nix checks.

let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
in
import ./test-arguments-logic.nix { lib = nixpkgs.lib; }
