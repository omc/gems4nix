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
    credentialMode
    validateCredentials
    credentialsFor
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

  # A string, not a Nix path: the file is read at build time and never copied
  # into the store. This is the shape a secret manager produces.
  fileCreds = {
    "rubygems.pkg.github.com".netrcFile = "/run/secrets/gem-registry-netrc";
  };

  privateGem = {
    gemName = "private-gem";
    version = "1.6.0";
    platform = "ruby";
    groups = [ "default" ];
    source = {
      sha256 = "deadbeef";
      remotes = [ "https://rubygems.pkg.github.com/example-org/gems" ];
      type = "gem";
    };
  };

  # Two private registries on one GEM section. Bundler deprecates the Gemfile
  # that produces this, but it writes the lockfile, so it has to work.
  twoPrivateCreds = {
    "gems.example.com" = {
      usernameVar = "OTHER_USER";
      passwordVar = "OTHER_TOKEN";
    };
    "rubygems.pkg.github.com".netrcFile = "/run/secrets/gem-registry-netrc";
  };

  twoRemoteGem = privateGem // {
    source = privateGem.source // {
      remotes = [
        "https://gems.example.com/private"
        "https://rubygems.pkg.github.com/example-org/gems"
      ];
    };
  };

  mixedRemoteGem = privateGem // {
    source = privateGem.source // {
      remotes = [
        "https://gems.example.com/private"
        "https://rubygems.org"
      ];
    };
  };

  repeatedHostGem = privateGem // {
    source = privateGem.source // {
      remotes = [
        "https://rubygems.pkg.github.com/example-org/gems"
        "https://rubygems.pkg.github.com/another-org/gems"
      ];
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
    assertEq "hostOf strips scheme and path" (hostOf "https://rubygems.pkg.github.com/example-org/gems")
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
          tokenFile = "/etc/netrc";
        };
      });

  test_validateCredentials_empty_entry =
    assertThrows "an entry declaring nothing throws"
      (validateCredentials {
        "gems.example.com" = { };
      });

  # ── validateCredentials: netrcFile mode ────────────────────────

  test_validateCredentials_netrcFile_ok =
    assertEq "a netrcFile entry passes through" (validateCredentials fileCreds)
      fileCreds;

  # Error should say to pick one mode.
  test_validateCredentials_mixed_modes =
    assertThrows "mixing netrcFile with usernameVar throws"
      (validateCredentials {
        "gems.example.com" = {
          netrcFile = "/run/secrets/netrc";
          usernameVar = "USER";
        };
      });

  # A Nix path literal would be copied into the store; a string is not.
  test_validateCredentials_netrcFile_path_literal =
    assertThrows "a Nix path as netrcFile throws"
      (validateCredentials {
        "gems.example.com".netrcFile = ./test-credentials-logic.nix;
      });

  test_validateCredentials_netrcFile_relative =
    assertThrows "a relative netrcFile throws"
      (validateCredentials {
        "gems.example.com".netrcFile = "secrets/netrc";
      });

  # ── credentialMode ─────────────────────────────────────────────

  test_credentialMode_env = assertEq "usernameVar/passwordVar is env mode" (credentialMode
    githubCreds."rubygems.pkg.github.com"
  ) "env";

  test_credentialMode_file = assertEq "netrcFile is file mode" (credentialMode
    fileCreds."rubygems.pkg.github.com"
  ) "file";

  # ── netrcFetchAttrs: netrcFile mode ────────────────────────────

  test_netrcFile_no_impure_env_vars =
    let
      attrs = netrcFetchAttrs (credentialsFor fileCreds privateGem);
    in
    assertEq "file mode declares no impure environment variables" (attrs ? netrcImpureEnvVars) false;

  test_netrcFile_copies_the_file =
    let
      attrs = netrcFetchAttrs (credentialsFor fileCreds privateGem);
    in
    assertEq "file mode copies the netrc into the build directory"
      (lib.strings.hasInfix "cat \"/run/secrets/gem-registry-netrc\" >> netrc" attrs.netrcPhase)
      true;

  # The permission trap from the issue: an unreadable path is indistinguishable
  # from a missing one, so the error has to name both causes.
  test_netrcFile_error_names_traversal =
    let
      attrs = netrcFetchAttrs (credentialsFor fileCreds privateGem);
    in
    assertEq "the unreadable-netrc error explains the traversal trap"
      (lib.strings.hasInfix "traverse" attrs.netrcPhase)
      true;

  test_netrcFile_error_names_sandbox_paths =
    let
      attrs = netrcFetchAttrs (credentialsFor fileCreds privateGem);
    in
    assertEq "the unreadable-netrc error names extra-sandbox-paths"
      (lib.strings.hasInfix "extra-sandbox-paths = /run/secrets/gem-registry-netrc" attrs.netrcPhase)
      true;

  # ── validateCredentials: values that could forge a netrc entry ─

  # A netrc entry is one line, so a newline anywhere that reaches the file
  # writes a second `machine` line. The host and the variable names are known
  # while Nix evaluates, so they are refused here; the variables' values are
  # not, and are guarded in the phase itself.
  test_validate_rejects_a_newline_in_the_host =
    assertThrows "a newline in a credentials key is refused"
      (validateCredentials {
        "gems.example.com\nmachine evil.example login e password e" = {
          usernameVar = "U";
          passwordVar = "P";
        };
      });

  test_validate_rejects_a_newline_in_a_variable_name =
    assertThrows "a newline in usernameVar is refused" (validateCredentials {
      "gems.example.com" = {
        usernameVar = "U}\nmachine evil.example login e password e\n#{";
        passwordVar = "P";
      };
    })
    && assertThrows "a newline in passwordVar is refused" (validateCredentials {
      "gems.example.com" = {
        usernameVar = "U";
        passwordVar = "P}\nmachine evil.example login e password e\n#{";
      };
    });

  # An environment variable name that is not a shell identifier cannot be
  # exported, so it can only ever be a typo or an injection.
  test_validate_requires_identifier_variable_names =
    assertThrows "a variable name that is not a shell identifier is refused" (validateCredentials {
      "gems.example.com" = {
        usernameVar = "not-an-identifier";
        passwordVar = "P";
      };
    })
    && assertThrows "a variable name starting with a digit is refused" (validateCredentials {
      "gems.example.com" = {
        usernameVar = "1USER";
        passwordVar = "P";
      };
    });

  test_validate_accepts_ordinary_variable_names =
    assertEq "an ordinary SCREAMING_SNAKE variable name is accepted" (validateCredentials githubCreds)
      githubCreds;

  # The path is interpolated into a double-quoted shell word, so a character
  # the shell acts on either reads a different file or runs something.
  test_validate_rejects_shell_metacharacters_in_netrcFile =
    assertThrows "a newline in netrcFile is refused" (validateCredentials {
      "gems.example.com".netrcFile = "/run/secrets/a\nrm -rf /";
    })
    && assertThrows "a command substitution in netrcFile is refused" (validateCredentials {
      "gems.example.com".netrcFile = "/run/secrets/$(id)/netrc";
    })
    && assertThrows "a double quote in netrcFile is refused" (validateCredentials {
      "gems.example.com".netrcFile = "/run/secrets/\"; id; \"/netrc";
    });

  test_validate_accepts_an_ordinary_netrc_path =
    assertEq "an ordinary absolute path is accepted" (validateCredentials fileCreds)
      fileCreds;

  # ── credentialsFor ─────────────────────────────────────────────

  test_credentialsFor_match =
    let
      creds = credentialsFor githubCreds privateGem;
    in
    assertEq "a gem on a credentialed remote resolves its credential"
      (map (c: { inherit (c) host usernameVar passwordVar; }) creds)
      [
        {
          host = "rubygems.pkg.github.com";
          usernameVar = "GEM_REGISTRY_USER";
          passwordVar = "GEM_REGISTRY_TOKEN";
        }
      ];

  test_credentialsFor_no_match =
    assertEq "a gem on a public remote has no credential" (credentialsFor githubCreds publicGem)
      [ ];

  test_credentialsFor_empty_credentials = assertEq "no credentials declared means no credential" (
    credentialsFor
    { }
    privateGem
  ) [ ];

  # Every credentialed remote a gem may be fetched from needs its own netrc
  # entry: fetchurl falls through to the next url on failure, and a fallback
  # with no credential is a bare 401 rather than a diagnostic.
  test_credentialsFor_covers_every_remote =
    assertEq "each credentialed remote of a gem contributes a credential"
      (map (c: c.host) (credentialsFor twoPrivateCreds twoRemoteGem))
      [
        "gems.example.com"
        "rubygems.pkg.github.com"
      ];

  test_credentialsFor_skips_uncredentialed_remotes =
    assertEq "a public remote beside a private one contributes nothing"
      (map (c: c.host) (credentialsFor twoPrivateCreds mixedRemoteGem))
      [ "gems.example.com" ];

  # Two remotes can differ only in their path, which is one host and one
  # credential. A netrc with the machine line twice is not wrong, but it says
  # the entry was resolved twice, and the first match is the one curl uses.
  test_credentialsFor_dedupes_a_repeated_host =
    assertEq "two remotes on one host resolve to one credential"
      (map (c: c.host) (credentialsFor githubCreds repeatedHostGem))
      [ "rubygems.pkg.github.com" ];

  # ── gemSuffix (mirrors buildRubyGem) ───────────────────────────

  test_gemSuffix_ruby =
    assertEq "a ruby-platform gem's suffix is just the version" (gemSuffix privateGem)
      "1.6.0";

  test_gemSuffix_native = assertEq "a native gem's suffix carries the platform" (gemSuffix (
    privateGem // { platform = "arm64-darwin"; }
  )) "1.6.0-arm64-darwin";

  # ── gemUrls ────────────────────────────────────────────────────

  test_gemUrls = assertEq "gemUrls mirrors buildRubyGem's URL construction" (gemUrls privateGem) [
    "https://rubygems.pkg.github.com/example-org/gems/gems/private-gem-1.6.0.gem"
  ];

  # ── netrcFetchAttrs ────────────────────────────────────────────

  test_netrcFetchAttrs_impure_env_vars =
    let
      attrs = netrcFetchAttrs (credentialsFor githubCreds privateGem);
    in
    assertEq "both credential variables are declared impure" attrs.netrcImpureEnvVars [
      "GEM_REGISTRY_USER"
      "GEM_REGISTRY_TOKEN"
    ];

  test_netrcFetchAttrs_writes_machine_line =
    let
      attrs = netrcFetchAttrs (credentialsFor githubCreds privateGem);
    in
    assertEq "netrcPhase writes a machine line for the host"
      (lib.strings.hasInfix "machine rubygems.pkg.github.com login \${GEM_REGISTRY_USER} password \${GEM_REGISTRY_TOKEN}" attrs.netrcPhase)
      true;

  # The whole point of issue #6: the failure has to name the credential and
  # where it is read from, rather than a bare 401.
  test_netrcFetchAttrs_error_names_host =
    let
      attrs = netrcFetchAttrs (credentialsFor githubCreds privateGem);
    in
    assertEq "the missing-credential error names the host"
      (lib.strings.hasInfix "rubygems.pkg.github.com" attrs.netrcPhase)
      true;

  test_netrcFetchAttrs_covers_every_credentialed_remote =
    let
      attrs = netrcFetchAttrs (credentialsFor twoPrivateCreds twoRemoteGem);
    in
    assertEq "the netrc carries a machine line for the env-mode host"
      (lib.strings.hasInfix "machine gems.example.com login" attrs.netrcPhase)
      true
    &&
      assertEq "the netrc carries the file-mode host's own file"
        (lib.strings.hasInfix "\"/run/secrets/gem-registry-netrc\" >> netrc" attrs.netrcPhase)
        true;

  # Every contribution appends. One that overwrote would drop whichever host
  # was written before it, which is the bug this shape exists to prevent.
  test_netrcFetchAttrs_appends_rather_than_overwrites =
    let
      attrs = netrcFetchAttrs (credentialsFor twoPrivateCreds twoRemoteGem);
    in
    assertEq "the netrc is emptied once before anything is written to it"
      (lib.strings.hasInfix ": > netrc" attrs.netrcPhase)
      true
    && assertEq "nothing overwrites the netrc after that" (lib.strings.hasInfix "> netrc" (
      lib.strings.replaceStrings [ ">> netrc" ": > netrc" ] [ "" "" ] attrs.netrcPhase
    )) false;

  test_netrcFetchAttrs_impure_vars_cover_every_env_credential =
    let
      attrs = netrcFetchAttrs (credentialsFor twoPrivateCreds twoRemoteGem);
    in
    assertEq "only the env-mode host's variables are declared impure" attrs.netrcImpureEnvVars [
      "OTHER_USER"
      "OTHER_TOKEN"
    ];

  test_netrcFetchAttrs_error_names_daemon =
    let
      attrs = netrcFetchAttrs (credentialsFor githubCreds privateGem);
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
    && test_validateCredentials_empty_entry
    # validateCredentials: netrcFile mode
    && test_validateCredentials_netrcFile_ok
    && test_validateCredentials_mixed_modes
    && test_validateCredentials_netrcFile_path_literal
    && test_validateCredentials_netrcFile_relative
    # credentialMode
    && test_credentialMode_env
    && test_credentialMode_file
    # netrcFetchAttrs: netrcFile mode
    && test_netrcFile_no_impure_env_vars
    && test_netrcFile_copies_the_file
    && test_netrcFile_error_names_traversal
    && test_netrcFile_error_names_sandbox_paths
    # credentialsFor
    && test_validate_rejects_a_newline_in_the_host
    && test_validate_rejects_a_newline_in_a_variable_name
    && test_validate_requires_identifier_variable_names
    && test_validate_accepts_ordinary_variable_names
    && test_validate_rejects_shell_metacharacters_in_netrcFile
    && test_validate_accepts_an_ordinary_netrc_path
    && test_credentialsFor_match
    && test_credentialsFor_no_match
    && test_credentialsFor_empty_credentials
    && test_credentialsFor_covers_every_remote
    && test_credentialsFor_skips_uncredentialed_remotes
    && test_credentialsFor_dedupes_a_repeated_host
    # gemSuffix / gemUrls
    && test_gemSuffix_ruby
    && test_gemSuffix_native
    && test_gemUrls
    # netrcFetchAttrs
    && test_netrcFetchAttrs_impure_env_vars
    && test_netrcFetchAttrs_writes_machine_line
    && test_netrcFetchAttrs_error_names_host
    && test_netrcFetchAttrs_error_names_daemon
    && test_netrcFetchAttrs_covers_every_credentialed_remote
    && test_netrcFetchAttrs_appends_rather_than_overwrites
    && test_netrcFetchAttrs_impure_vars_cover_every_env_credential;

in
allTests
