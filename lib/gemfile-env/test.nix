# TODO: wild how much nix one can write with just eval; formal unit tests pls?
# TODO: gemfile with git source
# TODO: gemfile with private git source
# TODO: gem with multiple remotes
let
  nixpkgs = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.11.tar.gz";
  }) { };
  gemEnv = nixpkgs.callPackage ./default.nix { };
  test = gemEnv {
    name = "test-gem-env";
    gemfile = ./test/rails/Gemfile;
    gemfileLock = ./test/rails/Gemfile.lock;
    groups = [
      "default"
      "development"
      "test"
    ];
    platforms = [
      "ruby"
      "arm64-darwin"
      "universal-darwin"
    ];
  };
in
test
