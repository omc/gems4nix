# Simple integration test: pure-ruby gems only (rack, rake).
# Run: nix build .#check
{
  description = "gems4nix example: simple pure-ruby gems";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=24.11";
    gems4nix = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, gems4nix, ... }:
    let
      allSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f {
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ gems4nix.overlays.default ];
        };
      });
    in
    {
      packages = forAllSystems ({ pkgs }: {
        gems = pkgs.gemfileEnv {
          name = "simple-example";
          gemfile = ./Gemfile;
          gemfileLock = ./Gemfile.lock;
          groups = [ "default" ];
        };
      });

      checks = forAllSystems ({ pkgs }:
        let
          gems = pkgs.gemfileEnv {
            name = "simple-example";
            gemfile = ./Gemfile;
            gemfileLock = ./Gemfile.lock;
            groups = [ "default" ];
          };
        in
        {
          validate = pkgs.runCommand "simple-validate" {
            buildInputs = [ pkgs.ruby gems ];
          } ''
            export GEM_PATH="${gems}/${pkgs.ruby.gemPath}"
            ruby ${./validate.rb}
            touch $out
          '';
        });
    };
}
