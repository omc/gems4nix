# Does an overridden `ruby` reach the gems, or only the setup hook?
#
# The environment's GEM_PATH is derived from the caller's ruby while the gems
# are built by buildRubyGem, which has a ruby of its own. If the two disagree
# the environment still builds and still evaluates — it just puts the gems in a
# directory GEM_PATH does not name, and every require fails at runtime.
#
# All assertions are on derivation attributes; nothing here builds a gem.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq;

  # A Ruby that is deliberately not nixpkgs' default, so a passthrough failure
  # shows up as a difference rather than a coincidence.
  otherRuby = pkgs.ruby_3_3;

  mkEnv =
    ruby:
    gemfileEnv {
      name = "ruby-override";
      gemfile = ../platform-gems/Gemfile;
      gemfileLock = ../platform-gems/Gemfile.lock;
      groups = [ "default" ];
      platforms = [ "ruby" ];
      inherit ruby;
    };

  overridden = mkEnv otherRuby;
  default = mkEnv pkgs.ruby;

  test_the_fixture_rubies_differ = assertEq "the override is a different Ruby from the default" (
    otherRuby.version.libDir == pkgs.ruby.version.libDir
  ) false;

  test_gems_build_against_the_requested_ruby =
    assertEq "every gem is built against the Ruby the caller asked for"
      (pkgs.lib.unique (map (gem: gem.ruby.version.libDir) overridden.paths))
      [ otherRuby.version.libDir ];

  test_default_still_uses_the_default_ruby =
    assertEq "without an override the gems use nixpkgs' Ruby"
      (pkgs.lib.unique (map (gem: gem.ruby.version.libDir) default.paths))
      [ pkgs.ruby.version.libDir ];

  # The invariant that actually matters: GEM_PATH names the directory the gems
  # install into.
  test_gem_path_matches_the_gems = assertEq "GEM_PATH names the directory the gems install into" (
    pkgs.lib.all
    (gem: pkgs.lib.hasInfix "$out/${gem.ruby.gemPath}" overridden.drvAttrs.postBuild)
    overridden.paths
  ) true;

in
test_the_fixture_rubies_differ
&& test_gems_build_against_the_requested_ruby
&& test_default_still_uses_the_default_ruby
&& test_gem_path_matches_the_gems
