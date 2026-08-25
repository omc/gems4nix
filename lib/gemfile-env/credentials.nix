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

  # A netrc entry is one line and `machine` is the only thing that starts one,
  # so any newline that reaches the file forges an entry for another host. The
  # host and the two variable names are known while Nix evaluates, so they are
  # refused here. The variables' values are not known until the build, and are
  # guarded in the phase that writes them.
  #
  # A netrcFile's contents are exempt by nature: that file is a netrc, so it is
  # many lines and several machine entries on purpose.
  forgesNetrcLine = value: builtins.match ".*[\n\r].*" value != null;

  # An environment variable name that is not a shell identifier cannot be
  # exported under that name, so it is a typo or an attempt to break out of the
  # `''${VAR}` the netrc line interpolates it into.
  isShellIdentifier = name: builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" name != null;

  # The path is interpolated into a double-quoted shell word. Inside those, the
  # shell still acts on `$`, a backtick and a backslash, and a `\"` ends the
  # word outright, so any of them reads a different file or runs something.
  shellUnsafePath = path: builtins.match ".*[\n\r\"$`\\].*" path != null;

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
          badVarNames = builtins.filter (
            n: entry ? ${n} && !(builtins.isString entry.${n} && isShellIdentifier entry.${n})
          ) envVarAttrNames;
        in
        if forgesNetrcLine host then
          throw "gems4nix: a credentials key contains a newline, which would forge a second netrc entry; use a bare host"
        else if lib.strings.hasInfix "/" host then
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
        else if entry ? netrcFile && shellUnsafePath entry.netrcFile then
          throw "gems4nix: credentials.\"${host}\".netrcFile contains a newline, a quote, a backslash, a backtick or a '$'. The path is read by a shell, so such a character makes it read a different file or run a command."
        else if badVarNames != [ ] then
          throw "gems4nix: credentials.\"${host}\".${builtins.head badVarNames} must name an environment variable, so it has to be a shell identifier such as GEM_REGISTRY_TOKEN. A value that is not one cannot be exported, and a newline in it would forge a second netrc entry."
        else
          entry;
    in
    lib.mapAttrs checkEntry credentials;

  # Every credential covering a gem's remotes, in the order the remotes are
  # tried, empty when they are all public. Each entry is the declared one plus
  # the host it matched, which netrcFetchAttrs needs for the `machine` line.
  #
  # All of them, not the first: fetchurl falls through to the next url when one
  # fails, so a gem served by two private registries needs both in the netrc.
  # Authenticating only the first turns the fallback into a bare 401, which is
  # the diagnostic-free failure this whole module exists to remove.
  #
  # Deduplicated by host, because two remotes differing only in path are one
  # host and one credential.
  credentialsFor =
    credentials: gemAttrs:
    let
      hosts = lib.unique (map hostOf (gemAttrs.source.remotes or [ ]));
    in
    map (host: credentials.${host} // { inherit host; }) (
      builtins.filter (h: credentials ? ${h}) hosts
    );

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

  # The missing-variable diagnostic, defined once however many env-mode hosts a
  # gem has. It takes the host and the three variable names as arguments so
  # that one definition can speak for all of them.
  missingCredentialHelper = ''
    gems4nixMissingCredential() {
      echo >&2 "gems4nix: no credential available for $1"
      echo >&2 "  \$$2 is unset or empty inside the build sandbox."
      echo >&2 ""
      echo >&2 "  gemfileEnv declares this credential as:"
      echo >&2 "    credentials.\"$1\" = { usernameVar = \"$3\"; passwordVar = \"$4\"; };"
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

    # A netrc entry is one line. A value carrying a newline would write the
    # rest of itself as further lines, and `machine` is all it takes to claim
    # another host. Neither Nix nor the heredoc can see this one: the value
    # arrives from the environment while the build runs.
    gems4nixRejectNewline() {
      if [ "$(printf '%s' "$3" | wc -l)" -ne 0 ]; then
        echo >&2 "gems4nix: the value of \$$2, the credential for $1, contains a newline."
        echo >&2 "  A netrc entry is a single line, so writing this value would add"
        echo >&2 "  lines of its own to the netrc and could claim another host."
        echo >&2 "  Check how the secret is stored: a trailing newline from a file"
        echo >&2 "  read into the variable is the usual cause."
        exit 1
      fi
    }
  '';

  # Mode 1: read the credential out of the build environment.
  #
  # The guard runs before the machine line is written, so an unset variable
  # fails naming the variable and the environment it is read from rather than
  # producing a 401 twenty lines later.
  envVarPhase =
    {
      host,
      usernameVar,
      passwordVar,
    }:
    ''
      [ -n "''${${usernameVar}:-}" ] || gems4nixMissingCredential ${host} ${usernameVar} ${usernameVar} ${passwordVar}
      [ -n "''${${passwordVar}:-}" ] || gems4nixMissingCredential ${host} ${passwordVar} ${usernameVar} ${passwordVar}
      gems4nixRejectNewline ${host} ${usernameVar} "''${${usernameVar}}"
      gems4nixRejectNewline ${host} ${passwordVar} "''${${passwordVar}}"

      cat >> netrc <<EOF
      machine ${host} login ''${${usernameVar}} password ''${${passwordVar}}
      EOF
    '';

  # Mode 2: read the credential out of a file the consumer controls, appended
  # to the build directory's netrc rather than handed to curl by path. The copy
  # keeps the whole thing inside the supported netrcPhase channel and lets the
  # readability check produce a real diagnostic.
  #
  # `[ -r ]` cannot distinguish absent from unreadable, and the difference is
  # the entire trap: a secret under a 0750 home is untraversable to the build
  # user, so stat can only report that it does not exist. The message therefore
  # names both causes instead of guessing.
  netrcFilePhase =
    { host, netrcFile }:
    ''
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
      cat "${netrcFile}" >> netrc
    '';

  # fetchurl arguments that authenticate against every host a gem may be
  # fetched from, each in whichever mode its entry declared.
  #
  # One netrc holds as many `machine` lines as it needs, so every contribution
  # appends and only the truncation at the top writes. A contribution that
  # overwrote would drop whichever host was written before it.
  netrcFetchAttrs =
    creds:
    let
      envCreds = builtins.filter (c: credentialMode c == "env") creds;
      phaseFor =
        c:
        if credentialMode c == "file" then
          netrcFilePhase { inherit (c) host netrcFile; }
        else
          envVarPhase { inherit (c) host usernameVar passwordVar; };
    in
    lib.optionalAttrs (envCreds != [ ]) {
      netrcImpureEnvVars = lib.concatMap (c: [
        c.usernameVar
        c.passwordVar
      ]) envCreds;
    }
    // {
      netrcPhase = lib.concatStringsSep "\n" (
        [ ": > netrc" ] ++ lib.optional (envCreds != [ ]) missingCredentialHelper ++ map phaseFor creds
      );
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
    credentialsFor
    gemSuffix
    gemUrls
    netrcFetchAttrs
    unusedCredentialHosts
    warnUnusedCredentials
    ;
}
