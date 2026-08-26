# Does the netrc a credentialed fetch writes say what we think it says?
#
# The unit tests assert on the text of the phase. This runs it. A shell snippet
# that reads correctly and behaves differently is the failure those cannot
# reach, and every property here is decided by the shell rather than by the
# string: whether a value lands verbatim, whether a second host appends or
# overwrites, and whether a newline in a credential can forge an entry.
#
# Nothing fetches. The phase is executed on its own with the credential
# variables supplied, which is what fetchurl does with it.
#
# Both hosts are env-mode on purpose. A netrcFile is an absolute path fixed
# during evaluation, and no such path exists inside the build sandbox.

{ pkgs, gemfileEnv }:

let
  env = gemfileEnv {
    name = "netrc-phase";
    gemfile = ./Gemfile;
    gemfileLock = ./two-registries.lock;
    groups = [ "default" ];
    platforms = [ "ruby" ];
    gemGroups.rake = [ "default" ];
    credentials = {
      "gems.example.invalid" = {
        usernameVar = "FIRST_USER";
        passwordVar = "FIRST_TOKEN";
      };
      "gems.private.invalid" = {
        usernameVar = "SECOND_USER";
        passwordVar = "SECOND_TOKEN";
      };
    };
  };
in
pkgs.runCommand "netrc-phase-behaviour"
  {
    phase = (pkgs.lib.head env.paths).src.drvAttrs.netrcPhase;
  }
  ''
    export SECOND_USER=bee SECOND_TOKEN=beetok

    # A password made of everything a shell reacts to. The heredoc expands the
    # variable but does not rescan the result, so all of it has to land as
    # written.
    awkward='p@ss w"rd`$(id)\'

    mkdir -p clean && (
      cd clean
      export FIRST_USER=alice FIRST_TOKEN="$awkward"
      sh -c "$phase" > log 2>&1 || { echo "the phase failed on ordinary credentials:" >&2; cat log >&2; exit 1; }

      grep -qxF "machine gems.example.invalid login alice password $awkward" netrc || {
        echo "the password did not land verbatim:" >&2; cat -A netrc >&2; exit 1; }
      grep -q 'uid=' netrc && { echo "the password was executed as a command:" >&2; cat netrc >&2; exit 1; }
      [ "$(grep -c '^machine ' netrc)" -eq 2 ] || {
        echo "expected one machine line per credentialed remote:" >&2; cat -A netrc >&2; exit 1; }
      grep -qxF 'machine gems.private.invalid login bee password beetok' netrc || {
        echo "the second host was overwritten rather than appended:" >&2; cat -A netrc >&2; exit 1; }
    )

    # The injection: a value carrying a newline and a forged entry for a host
    # nobody declared.
    mkdir -p poisoned && (
      cd poisoned
      export FIRST_USER=alice
      FIRST_TOKEN="$(printf 'realtoken\nmachine evil.invalid login e password e')"
      export FIRST_TOKEN
      if sh -c "$phase" > log 2>&1; then
        echo "a newline in a credential value was accepted:" >&2; cat -A netrc >&2; exit 1
      fi
      grep -qF 'FIRST_TOKEN' log || { echo "the refusal does not name the variable:" >&2; cat log >&2; exit 1; }
      if [ -e netrc ] && grep -q 'evil.invalid' netrc; then
        echo "the forged entry reached the netrc before the refusal:" >&2; cat -A netrc >&2; exit 1
      fi
    )

    touch $out
  ''
