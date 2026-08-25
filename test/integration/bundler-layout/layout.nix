# Does a git gem get what Bundler needs to resolve it?
#
# Bundler reads a GIT-sourced gem only from bundler/gems/<repo>-<shortrev>
# under its install path, and that path is Gem.dir. Both halves have to be
# right, and neither is visible from the RubyGems layout: an environment that
# raises Bundler::GitError looks exactly like one that does not.
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
      sprocket = [ "default" ];
      gadget = [ "default" ];
    };
    # The lockfile's git remote is fictional, so every git gem's source is
    # supplied here and nothing reaches the network.
    gemSrcOverrides = {
      widget = ./vendor/widget;
      sprocket = ./vendor/sprocket;
    };
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

  # An environment that leaves GEM_HOME alone sends Bundler looking for the
  # checkout under whatever GEM_HOME the caller happened to inherit.
  test_setup_hook_sets_gem_home =
    assertEq "the environment's setup hook exports GEM_HOME" (hasInfix "export GEM_HOME=" env.postBuild)
      true;

  allTests =
    test_git_gem_gets_a_bundler_checkout
    && test_path_gem_gets_no_bundler_checkout
    && test_setup_hook_sets_gem_home;

in
allTests
