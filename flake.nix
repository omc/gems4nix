{
  description = "Bundle Ruby gems into an environment, using Bundler checksums";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=26.05";
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

      checks = forAllSystems (
        { pkgs, ... }:
        let
          # Helper: wire a { lib }: unit test into flake checks.
          # The -logic.nix file is imported with pkgs.lib, fully evaluated via
          # builtins.deepSeq (which forces assertEq throws to surface), and
          # wrapped in writeText to produce a derivation for the checks contract.
          # Test failures abort nix flake check at eval time with the assertEq
          # error message visible in the trace.
          nixEvalCheck =
            name: testFile:
            let
              result = import testFile { lib = pkgs.lib; };
            in
            pkgs.writeText "unit-${name}" (builtins.deepSeq result "PASS");

          gemfileEnv = pkgs.callPackage ./lib/gemfile-env { };

          gems = gemfileEnv {
            name = "platform-gems-test";
            gemfile = ./test/integration/platform-gems/Gemfile;
            gemfileLock = ./test/integration/platform-gems/Gemfile.lock;
            groups = [ "default" ];
          };

          gemspecDirectiveGems = gemfileEnv {
            name = "gemspec-directive-test";
            gemfile = ./test/integration/gemspec-directive/Gemfile;
            gemfileLock = ./test/integration/gemspec-directive/Gemfile.lock;
            gemspec = ./test/integration/gemspec-directive/foo.gemspec;
            extraFiles = {
              "lib/foo/version.rb" = ./test/integration/gemspec-directive/lib/foo/version.rb;
            };
            groups = [ "default" ];
          };
        in
        {
          unit-resolve = nixEvalCheck "resolve" ./test/unit/test-resolve-logic.nix;
          unit-parse = nixEvalCheck "parse" ./test/unit/test-parse-logic.nix;
          unit-pipeline = nixEvalCheck "pipeline" ./test/unit/test-pipeline-logic.nix;

          integration-platform-gems =
            pkgs.runCommand "integration-platform-gems"
              {
                buildInputs = [
                  pkgs.ruby
                  gems
                ];
              }
              ''
                ruby ${./test/integration/platform-gems/validate.rb}
                touch $out
              '';

          integration-gemspec-directive =
            pkgs.runCommand "integration-gemspec-directive"
              {
                buildInputs = [
                  pkgs.ruby
                  gemspecDirectiveGems
                ];
              }
              ''
                ruby ${./test/integration/gemspec-directive/validate.rb}
                touch $out
              '';
        }
      );

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
