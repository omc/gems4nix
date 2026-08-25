# Where Bundler expects a git gem to be.
#
# RubyGems finds a gem through `specifications/<name>-<version>.gemspec` on the
# GEM_PATH. Bundler does not use that index for a gem the lockfile puts in a
# GIT section: it looks in `bundler/gems/<scope>` under its install path and
# nowhere else, and raises Bundler::GitError when the directory is missing. So
# an environment that writes only the RubyGems layout is invisible to
# `require "bundler/setup"`, which is how every stock Rails app boots.
#
# No nixpkgs build dependencies, only lib.
{ lib }:

rec {
  # The repository name Bundler derives from a git remote: the last path
  # segment, without a `.git` suffix. Bundler splits on `:` as well as `/` so
  # that an scp-style remote gives the same answer as an https one.
  #
  #   repoBaseName "https://github.com/omc/errgonomic.git" => "errgonomic"
  #   repoBaseName "git@github.com:omc/errgonomic.git"     => "errgonomic"
  repoBaseName =
    url:
    let
      segments = builtins.filter (s: builtins.isString s && s != "") (builtins.split "[:/]" url);
    in
    if segments == [ ] then
      throw "gems4nix: cannot read a repository name out of the git remote '${url}'"
    else
      lib.removeSuffix ".git" (lib.last segments);

  # The directory name Bundler gives a git checkout. Keyed on the repository
  # and the revision, never on the gem: one repository can supply several gems
  # and Bundler checks it out once, under the repository's own name.
  #
  #   gitScope { url = "https://github.com/omc/errgonomic.git";
  #              rev = "f06314af89209f855019219fd198513855be0fd5"; }
  #   => "errgonomic-f06314af8920"
  gitScope = source: "${repoBaseName source.url}-${builtins.substring 0 12 source.rev}";
}
