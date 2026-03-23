# Medium integration test: native gems with platform variants (nokogiri, puma).
# Tests that platform resolution picks precompiled native gems correctly.
# Run: nix build .#check
{
  description = "gems4nix example: native gems with platform variants";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=24.11";
    gems4nix = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, gems4nix, ... }:
    let
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs allSystems (
          system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ gems4nix.overlays.default ];
            };
          }
        );
    in
    {
      packages = forAllSystems (
        { pkgs }:
        {
          gems = pkgs.gemfileEnv {
            name = "medium-example";
            gemfile = ./Gemfile;
            gemfileLock = ./Gemfile.lock;
            groups = [
              "default"
              "test"
            ];
          };
        }
      );

      checks = forAllSystems (
        { pkgs }:
        let
          gems = pkgs.gemfileEnv {
            name = "medium-example";
            gemfile = ./Gemfile;
            gemfileLock = ./Gemfile.lock;
            groups = [
              "default"
              "test"
            ];
          };
        in
        {
          validate =
            pkgs.runCommand "medium-validate"
              {
                buildInputs = [
                  pkgs.ruby
                  gems
                ];
              }
              ''
                export GEM_PATH="${gems}/${pkgs.ruby.gemPath}"
                ruby ${./validate.rb}
                touch $out
              '';
        }
      );
    };
}
