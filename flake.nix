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

          # A git gem whose source is supplied rather than fetched, so this
          # builds with no network. Two gems come from the one git remote,
          # which is what a repository holding several gems looks like.
          bundlerLayoutGems = gemfileEnv {
            name = "bundler-layout-test";
            gemfile = ./test/integration/bundler-layout/Gemfile;
            gemfileLock = ./test/integration/bundler-layout/Gemfile.lock;
            groups = [ "default" ];
            platforms = [ "ruby" ];
            gemGroups = {
              widget = [ "default" ];
              sprocket = [ "default" ];
              gadget = [ "default" ];
            };
            gemSrcOverrides = {
              widget = ./test/integration/bundler-layout/vendor/widget;
              sprocket = ./test/integration/bundler-layout/vendor/sprocket;
            };
          };

          bundlerLayoutGemPath = "${bundlerLayoutGems}/${pkgs.ruby.gemPath}";
        in
        {
          unit-resolve = nixEvalCheck "resolve" ./test/unit/test-resolve-logic.nix;
          unit-parse = nixEvalCheck "parse" ./test/unit/test-parse-logic.nix;
          unit-pipeline = nixEvalCheck "pipeline" ./test/unit/test-pipeline-logic.nix;
          unit-credentials = nixEvalCheck "credentials" ./test/unit/test-credentials-logic.nix;
          unit-arguments = nixEvalCheck "arguments" ./test/unit/test-arguments-logic.nix;
          unit-bundler = nixEvalCheck "bundler" ./test/unit/test-bundler-logic.nix;

          # The pending ledger asserts that each known limitation is still a
          # limitation. It takes `.ledger` rather than the whole file, because
          # the pending tests themselves are expected to throw.
          unit-pending = pkgs.writeText "unit-pending" (
            builtins.deepSeq (import ./test/unit/test-pending-logic.nix { lib = pkgs.lib; }).ledger "PASS"
          );

          # Asserts credential plumbing on derivation attributes only; no fetch.
          credentials-wiring = pkgs.writeText "credentials-wiring" (
            builtins.deepSeq (import ./test/integration/credentials/wiring.nix {
              inherit pkgs gemfileEnv;
            }) "PASS"
          );

          # Asserts that gemfileEnv rejects an argument it does not declare.
          arguments-strictness = pkgs.writeText "arguments-strictness" (
            builtins.deepSeq (import ./test/integration/arguments/strictness.nix {
              inherit pkgs gemfileEnv;
            }) "PASS"
          );

          # Asserts a lockfile gems4nix cannot honour throws rather than
          # dropping the gem it cannot build.
          lockfile-guards = pkgs.writeText "lockfile-guards" (
            builtins.deepSeq (import ./test/integration/lockfile-guards/guards.nix {
              inherit pkgs gemfileEnv;
            }) "PASS"
          );

          # Asserts the git/path build wrapper's contract with a caller's
          # gemConfig: gemSrcOverrides reaches the build, and the empty-gem
          # check runs where a gemConfig postInstall cannot skip it.
          git-path-wiring = pkgs.writeText "git-path-wiring" (
            builtins.deepSeq (import ./test/integration/git-path-wiring/wiring.nix {
              inherit pkgs gemfileEnv;
            }) "PASS"
          );

          # Asserts a git gem gets the bundler/gems checkout Bundler resolves
          # it out of, and that a path gem does not.
          bundler-layout = pkgs.writeText "bundler-layout" (
            builtins.deepSeq (import ./test/integration/bundler-layout/layout.nix {
              inherit pkgs gemfileEnv;
            }) "PASS"
          );

          # Asserts an overridden `ruby` reaches the gems, not just GEM_PATH.
          ruby-override-wiring = pkgs.writeText "ruby-override-wiring" (
            builtins.deepSeq (import ./test/integration/ruby-override/wiring.nix {
              inherit pkgs gemfileEnv;
            }) "PASS"
          );

          # Asserts the setup hook refuses to be the second gems4nix
          # environment in one shell, rather than quietly winning GEM_HOME and
          # taking another environment's git gems out of Bundler's reach.
          bundler-gem-home-guard =
            pkgs.runCommand "bundler-gem-home-guard" { }
              ''
                hook="${bundlerLayoutGems}/nix-support/setup-hook"

                actual=$(unset GEM_HOME GEMS4NIX_GEM_HOME; . "$hook"; echo "$GEM_HOME")
                if [ "$actual" != "${bundlerLayoutGemPath}" ]; then
                  echo "hook set GEM_HOME to $actual, expected ${bundlerLayoutGemPath}" >&2
                  exit 1
                fi

                # A GEM_HOME the user brought is overridden without comment.
                # Only another gems4nix environment is ambiguous, and only
                # GEMS4NIX_GEM_HOME can tell the two apart.
                actual=$(unset GEMS4NIX_GEM_HOME; export GEM_HOME=/home/someone/.local/share/gem; . "$hook"; echo "$GEM_HOME")
                if [ "$actual" != "${bundlerLayoutGemPath}" ]; then
                  echo "hook deferred to a user's own GEM_HOME: $actual" >&2
                  exit 1
                fi

                decoy=/nix/store/00000000000000000000000000000000-other-env/lib/ruby/gems/3.3.0
                if (
                  export GEM_HOME="$decoy" GEMS4NIX_GEM_HOME="$decoy"
                  . "$hook"
                ) 2>stderr.txt; then
                  echo "a second gems4nix environment was accepted in silence" >&2
                  exit 1
                fi

                for needle in "$decoy" "${bundlerLayoutGemPath}" "bundler/setup"; do
                  if ! grep -qF "$needle" stderr.txt; then
                    echo "the refusal does not mention $needle:" >&2
                    cat stderr.txt >&2
                    exit 1
                  fi
                done

                touch $out
              '';

          # Measures what one git repository supplying two gems produces. Both
          # gems write the same bundler/gems scope, which is what a real
          # checkout of such a repository looks like.
          bundler-git-repo-with-two-gems =
            pkgs.runCommand "bundler-git-repo-with-two-gems" { }
              ''
                scope="${bundlerLayoutGemPath}/bundler/gems/widget-ruby-4f2e1c8a9b3d"
                for entry in widget.gemspec sprocket.gemspec lib/widget.rb lib/sprocket.rb; do
                  if [ ! -e "$scope/$entry" ]; then
                    echo "the shared checkout is missing $entry:" >&2
                    ls -R "$scope" >&2
                    exit 1
                  fi
                done
                touch $out
              '';

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
