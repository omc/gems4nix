# Unit tests for credentials.nix (logic only, no fetchTarball)
#
# Accepts { lib }: so it can be imported by both:
#   - The standalone wrapper (test-credentials.nix) for `nix eval --file` usage
#   - The root flake.nix checks via `import ./test-credentials-logic.nix { lib = pkgs.lib; }`
#
# Returns: true (all assertions pass) or throws with a descriptive message.

{ lib }:

let
  credentials = import ../../lib/gemfile-env/credentials.nix { inherit lib; };
  inherit (credentials)
    hostOf
    validateCredentials
    credentialFor
    gemSuffix
    gemUrls
    netrcFetchAttrs
    ;
  inherit (import ../helpers.nix) assertEq assertThrows;

  githubCreds = {
    "rubygems.pkg.github.com" = {
      usernameVar = "GEM_REGISTRY_USER";
      passwordVar = "GEM_REGISTRY_TOKEN";
    };
  };

  privateGem = {
    gemName = "depot";
    version = "1.6.0";
    platform = "ruby";
    groups = [ "default" ];
    source = {
      sha256 = "deadbeef";
      remotes = [ "https://rubygems.pkg.github.com/omc/gems" ];
      type = "gem";
    };
  };

  publicGem = {
    gemName = "rake";
    version = "13.2.1";
    platform = "ruby";
    groups = [ "default" ];
    source = {
      sha256 = "cafebabe";
      remotes = [ "https://rubygems.org" ];
      type = "gem";
    };
  };

  # ── hostOf ─────────────────────────────────────────────────────

  test_hostOf_https =
    assertEq "hostOf strips scheme and path" (hostOf "https://rubygems.pkg.github.com/omc/gems")
      "rubygems.pkg.github.com";

  test_hostOf_bare =
    assertEq "hostOf handles a bare host" (hostOf "https://rubygems.org")
      "rubygems.org";

  test_hostOf_trailing_slash =
    assertEq "hostOf handles a trailing slash" (hostOf "https://rubygems.org/")
      "rubygems.org";

  test_hostOf_userinfo =
    assertEq "hostOf drops userinfo" (hostOf "https://user:pw@gems.example.com/private")
      "gems.example.com";

  test_hostOf_port =
    assertEq "hostOf drops the port" (hostOf "https://gems.example.com:8443/private")
      "gems.example.com";

  # ── validateCredentials ────────────────────────────────────────

  test_validateCredentials_ok =
    assertEq "a well-formed credentials attrset passes through" (validateCredentials githubCreds)
      githubCreds;

  test_validateCredentials_empty = assertEq "an empty credentials attrset is valid" (
    validateCredentials
    { }
  ) { };

  # Error should name the host and the missing attribute.
  test_validateCredentials_missing_password =
    assertThrows "an entry without passwordVar throws"
      (validateCredentials {
        "gems.example.com".usernameVar = "USER";
      });

  # Error should name the host and the missing attribute.
  test_validateCredentials_missing_username =
    assertThrows "an entry without usernameVar throws"
      (validateCredentials {
        "gems.example.com".passwordVar = "TOKEN";
      });

  # Error should say the key must be a bare host, not a URL.
  test_validateCredentials_url_key = assertThrows "a URL used as a key throws" (validateCredentials {
    "https://gems.example.com" = {
      usernameVar = "USER";
      passwordVar = "TOKEN";
    };
  });

  test_validateCredentials_unknown_attr =
    assertThrows "an unrecognized attribute throws"
      (validateCredentials {
        "gems.example.com" = {
          usernameVar = "USER";
          passwordVar = "TOKEN";
          netrcFile = "/etc/netrc";
        };
      });

  # ── credentialFor ──────────────────────────────────────────────

  test_credentialFor_match =
    let
      cred = credentialFor githubCreds privateGem;
    in
    assertEq "a gem on a credentialed remote resolves its credential"
      {
        inherit (cred) host usernameVar passwordVar;
      }
      {
        host = "rubygems.pkg.github.com";
        usernameVar = "GEM_REGISTRY_USER";
        passwordVar = "GEM_REGISTRY_TOKEN";
      };

  test_credentialFor_no_match =
    assertEq "a gem on a public remote has no credential" (credentialFor githubCreds publicGem)
      null;

  test_credentialFor_empty_credentials = assertEq "no credentials declared means no credential" (
    credentialFor
    { }
    privateGem
  ) null;

  # ── gemSuffix (mirrors buildRubyGem) ───────────────────────────

  test_gemSuffix_ruby =
    assertEq "a ruby-platform gem's suffix is just the version" (gemSuffix privateGem)
      "1.6.0";

  test_gemSuffix_native = assertEq "a native gem's suffix carries the platform" (gemSuffix (
    privateGem // { platform = "arm64-darwin"; }
  )) "1.6.0-arm64-darwin";

  # ── gemUrls ────────────────────────────────────────────────────

  test_gemUrls = assertEq "gemUrls mirrors buildRubyGem's URL construction" (gemUrls privateGem) [
    "https://rubygems.pkg.github.com/omc/gems/gems/depot-1.6.0.gem"
  ];

  # ── netrcFetchAttrs ────────────────────────────────────────────

  test_netrcFetchAttrs_impure_env_vars =
    let
      attrs = netrcFetchAttrs (credentialFor githubCreds privateGem);
    in
    assertEq "both credential variables are declared impure" attrs.netrcImpureEnvVars [
      "GEM_REGISTRY_USER"
      "GEM_REGISTRY_TOKEN"
    ];

  test_netrcFetchAttrs_writes_machine_line =
    let
      attrs = netrcFetchAttrs (credentialFor githubCreds privateGem);
    in
    assertEq "netrcPhase writes a machine line for the host"
      (lib.strings.hasInfix "machine rubygems.pkg.github.com login \${GEM_REGISTRY_USER} password \${GEM_REGISTRY_TOKEN}" attrs.netrcPhase)
      true;

  # The whole point of issue #6: the failure has to name the credential and
  # where it is read from, rather than a bare 401.
  test_netrcFetchAttrs_error_names_host =
    let
      attrs = netrcFetchAttrs (credentialFor githubCreds privateGem);
    in
    assertEq "the missing-credential error names the host"
      (lib.strings.hasInfix "rubygems.pkg.github.com" attrs.netrcPhase)
      true;

  test_netrcFetchAttrs_error_names_daemon =
    let
      attrs = netrcFetchAttrs (credentialFor githubCreds privateGem);
    in
    assertEq "the missing-credential error points at the daemon environment"
      (lib.strings.hasInfix "nix-daemon" attrs.netrcPhase)
      true;

  allTests =
    # hostOf
    test_hostOf_https
    && test_hostOf_bare
    && test_hostOf_trailing_slash
    && test_hostOf_userinfo
    && test_hostOf_port
    # validateCredentials
    && test_validateCredentials_ok
    && test_validateCredentials_empty
    && test_validateCredentials_missing_password
    && test_validateCredentials_missing_username
    && test_validateCredentials_url_key
    && test_validateCredentials_unknown_attr
    # credentialFor
    && test_credentialFor_match
    && test_credentialFor_no_match
    && test_credentialFor_empty_credentials
    # gemSuffix / gemUrls
    && test_gemSuffix_ruby
    && test_gemSuffix_native
    && test_gemUrls
    # netrcFetchAttrs
    && test_netrcFetchAttrs_impure_env_vars
    && test_netrcFetchAttrs_writes_machine_line
    && test_netrcFetchAttrs_error_names_host
    && test_netrcFetchAttrs_error_names_daemon;

in
allTests
