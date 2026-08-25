# Does a git gem get the directory Bundler resolves it out of?
#
# Bundler reads a GIT-sourced gem only from bundler/gems/<repo>-<shortrev>
# under its install path. Writing that directory is what separates an
# environment a stock Rails app can boot against from one that raises
# Bundler::GitError, and nothing about the RubyGems layout reveals which one
# you have.
#
# The lockfile's git remote is never fetched: gemSrcOverrides supplies the
# source, so this evaluates with no network. The gem's name and its
# repository's name differ on purpose, because Bundler names the directory
# after the repository.
#
# The end-to-end proof is examples/complex's `bundler-setup` check, which boots
# a real Bundler against a real environment. This pins the wiring where no
# network is available.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq;
  inherit (pkgs.lib) hasInfix;

  env = gemfileEnv {
    name = "bundler-layout";
    gemfile = ./Gemfile;
    gemfileLock = ./Gemfile.lock;
    groups = [ "default" ];
    platforms = [ "ruby" ];
    gemGroups = {
      widget = [ "default" ];
      gadget = [ "default" ];
    };
    # Any directory in the store will do: nothing is built here.
    gemSrcOverrides.widget = ./vendor;
  };

  postInstallOf =
    gemName:
    let
      matches = builtins.filter (d: d.pname == gemName) env.paths;
    in
    if matches == [ ] then
      throw "no derivation named ${gemName} in the environment"
    else
      (builtins.head matches).postInstall or "";

  scope = "bundler/gems/widget-ruby-4f2e1c8a9b3d";

  test_git_gem_gets_a_bundler_checkout =
    assertEq "a git gem writes the directory Bundler looks in" (hasInfix scope (postInstallOf "widget"))
      true;

  # Bundler reads a path gem out of its source directory, so a checkout for
  # one would be a directory nothing resolves through.
  test_path_gem_gets_no_bundler_checkout =
    assertEq "a path gem writes no Bundler checkout" (hasInfix "bundler/gems" (postInstallOf "gadget"))
      false;

  allTests = test_git_gem_gets_a_bundler_checkout && test_path_gem_gets_no_bundler_checkout;

in
allTests
