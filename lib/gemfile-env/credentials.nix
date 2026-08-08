# Credentials for gems hosted on private registries.
#
# Pure logic: no IO, no nixpkgs. Exercised by test/unit/test-credentials-logic.nix.
#
# A gem fetched from a private remote needs a credential inside the Nix build
# sandbox. `pkgs.fetchurl` offers exactly one supported channel for that:
# `netrcPhase`, a shell snippet that writes a netrc into the build directory,
# paired with `netrcImpureEnvVars` naming the variables it may read.
#
# The secret therefore never enters the store — but it does have to reach the
# builder's environment, and on multi-user Nix that environment belongs to the
# daemon, not to the invoking shell. That constraint is inherent to impure env
# vars; what this module does is make it explicit and say so in the error when
# the credential is absent.
{ lib }:

let

  # Host portion of a remote URL, without scheme, userinfo, port, or path.
  # This is what a netrc `machine` line matches on, and what a `credentials`
  # key must be.
  hostOf =
    url:
    let
      afterScheme = lib.last (lib.splitString "://" url);
      authority = builtins.head (lib.splitString "/" afterScheme);
      withoutUserinfo = lib.last (lib.splitString "@" authority);
    in
    builtins.head (lib.splitString ":" withoutUserinfo);

  credentialAttrNames = [
    "usernameVar"
    "passwordVar"
  ];

  # Check the shape of the `credentials` argument up front, so a typo surfaces
  # as an evaluation error naming the host rather than as a 401 during a build.
  validateCredentials =
    credentials:
    let
      checkEntry =
        host: entry:
        let
          unknown = builtins.filter (n: !(builtins.elem n credentialAttrNames)) (builtins.attrNames entry);
          missing = builtins.filter (n: !(entry ? ${n})) credentialAttrNames;
        in
        if lib.strings.hasInfix "/" host then
          throw "gems4nix: credentials key '${host}' looks like a URL; use a bare host, e.g. '${hostOf host}'"
        else if missing != [ ] then
          throw "gems4nix: credentials.\"${host}\" is missing ${lib.concatStringsSep " and " missing}; each entry needs { usernameVar = \"...\"; passwordVar = \"...\"; }"
        else if unknown != [ ] then
          throw "gems4nix: credentials.\"${host}\" has unrecognized attribute(s) ${lib.concatStringsSep ", " unknown}; only ${lib.concatStringsSep " and " credentialAttrNames} are supported"
        else
          entry;
    in
    lib.mapAttrs checkEntry credentials;

  # The credential covering a gem's remote, or null when the remote is public.
  # Returns the declared entry plus the host it matched, which netrcFetchAttrs
  # needs for the netrc `machine` line.
  credentialFor =
    credentials: gemAttrs:
    let
      hosts = map hostOf (gemAttrs.source.remotes or [ ]);
      matched = builtins.filter (h: credentials ? ${h}) hosts;
    in
    if matched == [ ] then
      null
    else
      let
        host = builtins.head matched;
      in
      credentials.${host} // { inherit host; };

  # Mirrors buildRubyGem's own `suffix` and URL construction. We reproduce them
  # because buildRubyGem builds its `src` internally from `source.remotes` and
  # `source.sha256` alone, with no hook for extra fetchurl arguments — the only
  # way in is to hand it a finished `src`.
  gemSuffix =
    gemAttrs:
    if gemAttrs.platform != "ruby" then
      "${gemAttrs.version}-${gemAttrs.platform}"
    else
      gemAttrs.version;

  gemUrls =
    gemAttrs:
    map (
      remote: "${remote}/gems/${gemAttrs.gemName}-${gemSuffix gemAttrs}.gem"
    ) gemAttrs.source.remotes;

  # fetchurl arguments that authenticate against one host.
  #
  # The guard runs before the netrc is written so an unset variable fails with
  # the reason and the fix, instead of a 401 that points at nix.conf — which
  # configures Nix's own downloader and has no bearing on a derivation's curl.
  netrcFetchAttrs =
    {
      host,
      usernameVar,
      passwordVar,
    }:
    {
      netrcImpureEnvVars = [
        usernameVar
        passwordVar
      ];
      netrcPhase = ''
        gems4nixMissingCredential() {
          echo >&2 "gems4nix: no credential available for ${host}"
          echo >&2 "  \$$1 is unset or empty inside the build sandbox."
          echo >&2 ""
          echo >&2 "  gemfileEnv declares this credential as:"
          echo >&2 "    credentials.\"${host}\" = { usernameVar = \"${usernameVar}\"; passwordVar = \"${passwordVar}\"; };"
          echo >&2 ""
          echo >&2 "  Nix reads impure environment variables from the environment of the"
          echo >&2 "  process that runs the build. On multi-user Nix that is nix-daemon,"
          echo >&2 "  not your shell, so exporting the variable interactively has no effect."
          echo >&2 "    nix-darwin / NixOS: nix.envVars.$1 = \"...\"; then restart nix-daemon"
          echo >&2 "    single-user Nix:    export $1 in the shell that runs the build"
          echo >&2 ""
          echo >&2 "  netrc-file in nix.conf does not apply here: it configures Nix's own"
          echo >&2 "  downloader, not the curl this derivation runs."
          exit 1
        }
        [ -n "''${${usernameVar}:-}" ] || gems4nixMissingCredential ${usernameVar}
        [ -n "''${${passwordVar}:-}" ] || gems4nixMissingCredential ${passwordVar}

        cat > netrc <<EOF
        machine ${host} login ''${${usernameVar}} password ''${${passwordVar}}
        EOF
      '';
    };

  # Hosts named in `credentials` that no gem in the lockfile actually uses.
  # A typo here is otherwise silent: the credential is simply never applied and
  # the build fails with a 401 as if nothing had been declared.
  unusedCredentialHosts =
    credentials: gems:
    let
      usedHosts = lib.unique (lib.concatMap (g: map hostOf (g.source.remotes or [ ])) gems);
    in
    builtins.filter (h: !(builtins.elem h usedHosts)) (builtins.attrNames credentials);

  warnUnusedCredentials =
    credentials: gems:
    let
      unused = unusedCredentialHosts credentials gems;
    in
    lib.warnIf (unused != [ ])
      "gems4nix: credentials declared for ${lib.concatStringsSep ", " unused}, but no gem in the lockfile is fetched from ${
        if builtins.length unused == 1 then "that host" else "those hosts"
      }"
      credentials;

in
{
  inherit
    hostOf
    validateCredentials
    credentialFor
    gemSuffix
    gemUrls
    netrcFetchAttrs
    unusedCredentialHosts
    warnUnusedCredentials
    ;
}
