{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=24.11";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      overlays = [
      ];
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
            pkgs = import nixpkgs { inherit system overlays; };
          }
        );

    in
    {
      packages = forAllSystems ({ ... }: { });

      overlays = {
        default = final: prev: {
          inherit (self.packages.${final.system}) gems4nix;
          lib = prev.lib.extend (
            final: prev: {
              gemEnv = final.callPackage ./lib/gemfile-env { };
            }
          );
        };
      };

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.ruby
              pkgs.bundler
              pkgs.rubyPackages.solargraph
              pkgs.rubyPackages.rubocop
            ];
          };
        }
      );

    };
}
