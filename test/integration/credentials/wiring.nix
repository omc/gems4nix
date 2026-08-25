# Credential wiring test: does a declared credential actually reach fetchurl?
#
# This needs a real nixpkgs (not just lib), because it inspects the derivations
# gemfileEnv produces. It never fetches anything — the assertions are all on
# derivation attributes.
#
# The URL assertion is the important one. credentials.nix reconstructs the gem
# URL because buildRubyGem gives no hook for extra fetchurl arguments; if
# buildRubyGem ever changes how it builds that URL, this test fails rather than
# silently fetching the wrong path under authentication.

{ pkgs, gemfileEnv }:

let
  inherit (import ../../helpers.nix) assertEq;

  mkEnv =
    credentials:
    gemfileEnv {
      name = "credentials-wiring";
      gemfile = ../platform-gems/Gemfile;
      gemfileLock = ../platform-gems/Gemfile.lock;
      groups = [ "default" ];
      platforms = [ "ruby" ];
      inherit credentials;
    };

  plain = mkEnv { };
  authenticated = mkEnv {
    "rubygems.org" = {
      usernameVar = "GEM_REGISTRY_USER";
      passwordVar = "GEM_REGISTRY_TOKEN";
    };
  };

  fileAuthenticated = mkEnv {
    "rubygems.org".netrcFile = "/run/secrets/gem-registry-netrc";
  };

  urlsOf = env: pkgs.lib.concatMap (gem: gem.src.urls) env.paths;

  test_urls_match_buildRubyGem =
    assertEq "credentialed gems fetch the same URLs buildRubyGem would" (urlsOf authenticated)
      (urlsOf plain);

  test_credential_vars_are_impure = assertEq "every credentialed gem declares both variables impure" (
    pkgs.lib.all
    (
      gem:
      let
        impure = gem.src.drvAttrs.impureEnvVars;
      in
      builtins.elem "GEM_REGISTRY_USER" impure && builtins.elem "GEM_REGISTRY_TOKEN" impure
    )
    authenticated.paths
  ) true;

  test_no_credentials_no_netrc =
    assertEq "without credentials no gem gets an impure credential variable"
      (pkgs.lib.any (gem: builtins.elem "GEM_REGISTRY_TOKEN" gem.src.drvAttrs.impureEnvVars) plain.paths)
      false;

  # The secret must reach curl through the netrc, never through the store.
  test_secret_not_in_derivation =
    assertEq "the netrc phase references variables, not literal secrets"
      (pkgs.lib.all (
        gem: pkgs.lib.strings.hasInfix "\${GEM_REGISTRY_TOKEN}" gem.src.drvAttrs.netrcPhase
      ) authenticated.paths)
      true;

  test_file_mode_urls_match_buildRubyGem =
    assertEq "netrcFile gems fetch the same URLs buildRubyGem would" (urlsOf fileAuthenticated)
      (urlsOf plain);

  # The path is a string, so nothing about it is copied into the store. If it
  # were a Nix path literal the netrcPhase would name a /nix/store entry.
  test_file_mode_path_not_in_store =
    assertEq "netrcFile reaches the builder as a path, not a store copy"
      (pkgs.lib.all (
        gem:
        pkgs.lib.strings.hasInfix "/run/secrets/gem-registry-netrc" gem.src.drvAttrs.netrcPhase
        && !(pkgs.lib.strings.hasInfix "/nix/store" gem.src.drvAttrs.netrcPhase)
      ) fileAuthenticated.paths)
      true;

  # File mode needs no impure environment variable, which is the whole reason
  # it exists: it works without touching the daemon's environment.
  test_file_mode_adds_no_impure_vars = assertEq "netrcFile adds no impure environment variables" (
    pkgs.lib.concatMap
    (gem: gem.src.drvAttrs.impureEnvVars)
    fileAuthenticated.paths
  ) (pkgs.lib.concatMap (gem: gem.src.drvAttrs.impureEnvVars) plain.paths);

in
test_urls_match_buildRubyGem
&& test_credential_vars_are_impure
&& test_no_credentials_no_netrc
&& test_secret_not_in_derivation
&& test_file_mode_urls_match_buildRubyGem
&& test_file_mode_path_not_in_store
&& test_file_mode_adds_no_impure_vars
