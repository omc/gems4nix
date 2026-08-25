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
  # Two private registries on one GEM section. fetchurl falls through to the
  # second url when the first fails, so a netrc naming only one host turns that
  # fallback into a bare 401 with none of the diagnostics above.
  twoRegistries = gemfileEnv {
    name = "credentials-two-registries";
    gemfile = ./Gemfile;
    gemfileLock = ./two-registries.lock;
    groups = [ "default" ];
    platforms = [ "ruby" ];
    gemGroups = {
      rake = [ "default" ];
    };
    credentials = {
      "gems.example.invalid" = {
        usernameVar = "FIRST_USER";
        passwordVar = "FIRST_TOKEN";
      };
      "gems.private.invalid".netrcFile = "/run/secrets/second-netrc";
    };
  };

  twoRegistryPhase = (pkgs.lib.head twoRegistries.paths).src.drvAttrs.netrcPhase;

  test_every_credentialed_remote_reaches_the_netrc =
    assertEq "both registries are named in the one netrc"
      [
        (pkgs.lib.strings.hasInfix "machine gems.example.invalid login" twoRegistryPhase)
        (pkgs.lib.strings.hasInfix "cat \"/run/secrets/second-netrc\" >> netrc" twoRegistryPhase)
      ]
      [
        true
        true
      ];

  # fetchurl brings its own impure variables, so compare against an
  # uncredentialed gem rather than against a literal list.
  test_every_env_credential_is_impure =
    assertEq "the env-mode registry contributes exactly its two variables"
      (pkgs.lib.subtractLists (pkgs.lib.head plain.paths).src.drvAttrs.impureEnvVars (pkgs.lib.head twoRegistries.paths)
      .src.drvAttrs.impureEnvVars)
      [
        "FIRST_USER"
        "FIRST_TOKEN"
      ];

  # Both urls are on the fetch, so both had to be credentialed. Without this
  # the netrc assertion could pass on a gem that only ever tries one of them.
  test_both_registries_are_on_the_fetch =
    assertEq "the gem is fetched from both registries, highest priority first"
      (pkgs.lib.head twoRegistries.paths).src.urls
      [
        "https://gems.private.invalid/gems/rake-13.3.1.gem"
        "https://gems.example.invalid/gems/rake-13.3.1.gem"
      ];

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
&& test_every_credentialed_remote_reaches_the_netrc
&& test_every_env_credential_is_impure
&& test_both_registries_are_on_the_fetch
