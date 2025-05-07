# TODO: wild how much nix one can write with just eval; formal unit tests pls?
let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
  gemEnv = nixpkgs.callPackage ./default.nix { };
  test = gemEnv { gemfileLock = ./test/rails/Gemfile.lock; };
in
test
