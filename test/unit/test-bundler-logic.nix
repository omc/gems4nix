# Unit tests for bundler.nix (logic only, no fetchTarball)
#
# Accepts { lib }: so it can be imported by both:
#   - The standalone wrapper (test-bundler.nix) for `nix eval --file` usage
#   - The root flake.nix checks via `import ./test-bundler-logic.nix { lib = pkgs.lib; }`
#
# Returns: true (all assertions pass) or throws with a descriptive message.
#
# The expectations here are Bundler's, not ours: Bundler::Source::Git#base_name
# and #shortref_for_path decide the directory name, and a name that disagrees
# with them by one character leaves the gem as invisible as writing nothing.

{ lib }:

let
  bundler = import ../../lib/gemfile-env/bundler.nix { inherit lib; };
  inherit (bundler) repoBaseName gitScope;
  inherit (import ../helpers.nix) assertEq assertThrows;

  rev = "f06314af89209f855019219fd198513855be0fd5";

  # ── repoBaseName ─────────────────────────────────────────────

  test_repoBaseName_https =
    assertEq "an https remote gives the repository name"
      (repoBaseName "https://github.com/omc/errgonomic.git")
      "errgonomic";

  test_repoBaseName_scp =
    assertEq "an scp-style remote gives the same name as the https one"
      (repoBaseName "git@github.com:omc/errgonomic.git")
      "errgonomic";

  test_repoBaseName_no_git_suffix =
    assertEq "a remote written without .git keeps its last segment"
      (repoBaseName "https://github.com/omc/errgonomic")
      "errgonomic";

  test_repoBaseName_trailing_slash =
    assertEq "a trailing slash does not swallow the name"
      (repoBaseName "https://github.com/omc/errgonomic/")
      "errgonomic";

  test_repoBaseName_nested_path =
    assertEq "only the last path segment is the name"
      (repoBaseName "https://gitlab.example.com/group/subgroup/errgonomic.git")
      "errgonomic";

  test_repoBaseName_empty_remote = assertThrows "a remote with no segments names itself in the error" (
    repoBaseName ""
  );

  # ── gitScope ─────────────────────────────────────────────────

  test_gitScope_twelve_characters =
    assertEq "the scope takes twelve characters of the revision, as Bundler does"
      (gitScope {
        url = "https://github.com/omc/errgonomic.git";
        inherit rev;
      })
      "errgonomic-f06314af8920";

  # A gem name and its repository name are routinely different, and Bundler
  # names the directory after the repository. Keying on the gem instead
  # produces a directory Bundler never looks in.
  test_gitScope_follows_the_repository_not_the_gem =
    assertEq "the scope follows the repository name, not the gem name"
      (gitScope {
        url = "https://git.example.com/acme/widget-ruby.git";
        rev = "4f2e1c8a9b3d5e7f0a1b2c3d4e5f60718293a4b5";
      })
      "widget-ruby-4f2e1c8a9b3d";

  allTests =
    test_repoBaseName_https
    && test_repoBaseName_scp
    && test_repoBaseName_no_git_suffix
    && test_repoBaseName_trailing_slash
    && test_repoBaseName_nested_path
    && test_repoBaseName_empty_remote
    && test_gitScope_twelve_characters
    && test_gitScope_follows_the_repository_not_the_gem;

in
allTests
