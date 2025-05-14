{
  description = "Bundle Ruby gems into an environment, using Bundler checksums";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=24.11";
  };

  outputs =
    { nixpkgs, ... }:
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
            pkgs = import nixpkgs { inherit system; };
          }
        );

    in
    {
      packages = forAllSystems ({ ... }: { });

      overlays = {
        # provide gemfileEnv in pkgs
        default = final: prev: {
          gemfileEnv = final.callPackage ./lib/gemfile-env { };
        };
      };

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              ruby
              bundler
              rubyPackages.solargraph
              rubyPackages.rubocop
            ];
          };
        }
      );

    };
}
