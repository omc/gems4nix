# Credentials for gems hosted on private registries.
#
# Pure logic: no IO, no nixpkgs. Exercised by test/unit/test-credentials-logic.nix.
#
# A gem fetched from a private remote needs a credential inside the Nix build
# sandbox. `pkgs.fetchurl` offers exactly one supported channel for that:
# `netrcPhase`, a shell snippet that writes a netrc into the build directory.
# Both modes here go through it, so neither puts a secret in the store.
#
# Where the secret comes from is the consumer's choice, because the two answers
# fail on different machines:
#
#   usernameVar / passwordVar   read from the build environment. On multi-user
#                               Nix that is the daemon's environment, not the
#                               invoking shell's.
#   netrcFile                   read from a path at build time. Needs no daemon
#                               configuration, but the build user has to be able
#                               to read the path, and on Linux the sandbox has
#                               to expose it.
#
# The path in `netrcFile` is a string, never a Nix path literal, so the file is
# not copied into the store. Both modes report their own failure mode by name.
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

  envVarAttrNames = [
    "usernameVar"
    "passwordVar"
  ];
  fileAttrNames = [ "netrcFile" ];
  credentialAttrNames = envVarAttrNames ++ fileAttrNames;

  shapeHint = "an entry is either { usernameVar = \"...\"; passwordVar = \"...\"; } or { netrcFile = \"/run/secrets/...\"; }";

  # Which mode an entry declares. Used by netrcFetchAttrs to dispatch, and by
  # validateCredentials to reject a half-specified or mixed entry.
  credentialMode = entry: if entry ? netrcFile then "file" else "env";

  # Check the shape of the `credentials` argument up front, so a typo surfaces
  # as an evaluation error naming the host rather than as a 401 during a build.
  validateCredentials =
    credentials:
    let
      checkEntry =
        host: entry:
        let
          declared = builtins.attrNames entry;
          unknown = builtins.filter (n: !(builtins.elem n credentialAttrNames)) declared;
          envAttrs = builtins.filter (n: builtins.elem n envVarAttrNames) declared;
          missingEnv = builtins.filter (n: !(entry ? ${n})) envVarAttrNames;
        in
        if lib.strings.hasInfix "/" host then
          throw "gems4nix: credentials key '${host}' looks like a URL; use a bare host, e.g. '${hostOf host}'"
        else if unknown != [ ] then
          throw "gems4nix: credentials.\"${host}\" has unrecognized attribute(s) ${lib.concatStringsSep ", " unknown}; ${shapeHint}"
        else if declared == [ ] then
          throw "gems4nix: credentials.\"${host}\" is empty; ${shapeHint}"
        else if entry ? netrcFile && envAttrs != [ ] then
          throw "gems4nix: credentials.\"${host}\" mixes netrcFile with ${lib.concatStringsSep " and " envAttrs}; pick one, since ${shapeHint}"
        else if !(entry ? netrcFile) && missingEnv != [ ] then
          throw "gems4nix: credentials.\"${host}\" is missing ${lib.concatStringsSep " and " missingEnv}; ${shapeHint}"
        else if entry ? netrcFile && !(builtins.isString entry.netrcFile) then
          throw "gems4nix: credentials.\"${host}\".netrcFile must be a string, not a Nix path; a path literal would copy the secret into the store"
        else if entry ? netrcFile && !(lib.strings.hasPrefix "/" entry.netrcFile) then
          throw "gems4nix: credentials.\"${host}\".netrcFile must be an absolute path, but got '${entry.netrcFile}'"
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

  # Every failure message closes with this, because `netrc-file` in nix.conf is
  # where the error otherwise sends people, and it is the one layer that cannot
  # fix it.
  wrongLayerNote = ''
    echo >&2 ""
    echo >&2 "  netrc-file in nix.conf does not apply here: it configures Nix's own"
    echo >&2 "  downloader, not the curl this derivation runs."
  '';

  # Mode 1: read the credential out of the build environment.
  #
  # The guard runs before the netrc is written, so an unset variable fails
  # naming the variable and the environment it is read from rather than
  # producing a 401 twenty lines later.
  envVarFetchAttrs =
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
          echo >&2 "  Feed the daemon's environment from a secret file rather than setting"
          echo >&2 "  the value in your system configuration, which would store it"
          echo >&2 "  world-readable. Or switch this entry to netrcFile."
          ${wrongLayerNote}
          exit 1
        }
        [ -n "''${${usernameVar}:-}" ] || gems4nixMissingCredential ${usernameVar}
        [ -n "''${${passwordVar}:-}" ] || gems4nixMissingCredential ${passwordVar}

        cat > netrc <<EOF
        machine ${host} login ''${${usernameVar}} password ''${${passwordVar}}
        EOF
      '';
    };

  # Mode 2: read the credential out of a file the consumer controls, copied
  # into the build directory rather than handed to curl by path. The copy keeps
  # the whole thing inside the supported netrcPhase channel and lets the
  # readability check produce a real diagnostic.
  #
  # `[ -r ]` cannot distinguish absent from unreadable, and the difference is
  # the entire trap: a secret under a 0750 home is untraversable to the build
  # user, so stat can only report that it does not exist. The message therefore
  # names both causes instead of guessing.
  netrcFileFetchAttrs =
    { host, netrcFile }:
    {
      netrcPhase = ''
        if [ ! -r "${netrcFile}" ]; then
          echo >&2 "gems4nix: cannot read the netrc for ${host} at ${netrcFile}"
          echo >&2 "  The build user cannot read that path. Either it does not exist, or"
          echo >&2 "  it is unreadable — which looks identical from in here, because a"
          echo >&2 "  directory the build user cannot traverse makes the file it contains"
          echo >&2 "  indistinguishable from absent."
          echo >&2 ""
          echo >&2 "  The build does not run as you. Under a multi-user daemon it runs as"
          echo >&2 "  a build user sharing no group with you, so a secret under a 0750"
          echo >&2 "  home directory is unreachable no matter its own mode."
          echo >&2 "  Check that every directory on the path is traversable and that the"
          echo >&2 "  file itself is readable by the build user."
          echo >&2 ""
          echo >&2 "  On Linux the sandbox also has to expose the path:"
          echo >&2 "    extra-sandbox-paths = ${netrcFile}"
          ${wrongLayerNote}
          exit 1
        fi
        cp "${netrcFile}" netrc
      '';
    };

  # fetchurl arguments that authenticate against one host, in whichever mode
  # the entry declared.
  netrcFetchAttrs =
    credential:
    if credentialMode credential == "file" then
      netrcFileFetchAttrs {
        inherit (credential) host netrcFile;
      }
    else
      envVarFetchAttrs {
        inherit (credential) host usernameVar passwordVar;
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
    credentialMode
    validateCredentials
    credentialFor
    gemSuffix
    gemUrls
    netrcFetchAttrs
    unusedCredentialHosts
    warnUnusedCredentials
    ;
}
