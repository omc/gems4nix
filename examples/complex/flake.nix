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
# Note: builtins.fetchGit gets the git gem while Nix evaluates this flake, so
# the check needs the network even when every gem is already built.
#
# `root` is left unset on purpose. PATH remotes then resolve against the
# directory holding the Gemfile, and this example tests that default.
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
          # What Bundler needs to read at runtime, and nothing else. The PATH
          # gem's remote is relative to the Gemfile, so vendor/ comes along;
          # without it Bundler resolves hello_gem against a directory that is
          # not there.
          gemfileDir = pkgs.runCommand "complex-gemfile-dir" { } ''
            mkdir -p $out
            cp ${./Gemfile} $out/Gemfile
            cp ${./Gemfile.lock} $out/Gemfile.lock
            cp -r ${./vendor} $out/vendor
          '';
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

          # GEM_HOME is what decides where Bundler looks for a git gem, and it
          # is read-only here on purpose: an environment that only works when
          # Bundler can write to it is not an environment. BUNDLE_FROZEN turns
          # a lockfile Bundler wants to rewrite into an error rather than a
          # rewrite nobody sees.
          bundler-setup =
            pkgs.runCommand "complex-bundler-setup"
              {
                buildInputs = [
                  pkgs.ruby
                  gems
                ];
              }
              ''
                export GEM_HOME="${gems}/${pkgs.ruby.gemPath}"
                export GEM_PATH="$GEM_HOME"
                export BUNDLE_GEMFILE="${gemfileDir}/Gemfile"
                export BUNDLE_FROZEN=1
                ruby ${./bundler-setup.rb}
                bundle exec rake --version
                touch $out
              '';
        }
      );
    };
}
