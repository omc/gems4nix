# Complex integration test: Rails app with native gems, git source, and path source.
#
# This example exercises the full pipeline:
# - ~60 gems from rubygems.org (GEM section)
# - errgonomic from a git repo (GIT section)
# - hello_gem from a local path (PATH section)
# - Native gems with platform variants (nokogiri, ffi, puma)
# - Group filtering (default + development + test)
#
# Run: nix flake check --no-write-lock-file
#
# Note: the GIT gem is fetched by builtins.fetchGit at EVALUATION time, so this
# needs network access even when everything else is cached.
#
# `root` is deliberately not passed: PATH remotes default to dirOf ./Gemfile,
# and this example is the test that the default resolves correctly.
{
  description = "gems4nix example: complex Rails app with git and path sources";

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
            name = "complex-example";
            gemfile = ./Gemfile;
            gemfileLock = ./Gemfile.lock;
            groups = [
              "default"
              "development"
              "test"
            ];
          };
        }
      );

      checks = forAllSystems (
        { pkgs }:
        let
          gems = pkgs.gemfileEnv {
            name = "complex-example";
            gemfile = ./Gemfile;
            gemfileLock = ./Gemfile.lock;
            groups = [
              "default"
              "development"
              "test"
            ];
          };
        in
        {
          validate =
            pkgs.runCommand "complex-validate"
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
