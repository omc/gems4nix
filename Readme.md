Bundler 2.6 shipped with the ability to write checksums into its lockfile. That means for apps using Bundler >= 2.6 we no longer need a standalone tool to fetch gems and hash them. Instead we can parse the Gemfile and Gemfile.lock directly from Nix, which is what you're looking at here.

Along the way we're paying special attention to multi-platform support for Ruby gems. This had been problematic in Bundix, and solutions seem to be scattered across PRs in various states of languished. We may as well get that sorted out here as well, because I want to use Sorbet, and stop worrying about cross platform gems in general.

This project does make use of existing Nixpkgs abstractions as much as possible to avoid reimplementing work that doesn't need to be reimplemented. Notably, `buildRubyGem`. That lets us focus the scope, avoid rabbit holes, and generally derisk things.

Quick reference:

```nix
gemEnv {
  name = "test-gem-env";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;
};
```

You can also provide a list of `groups` and `platforms` to include gems for those specific groups and platforms, as described by the Gemfile. There is currently no attempt to create a conventional mapping between your Nix system and the Ruby platform, that's up to you. (For now.)

Here's an example with other groups and a hackish conditionalized list of platforms. TBD on how I want to create a nicer convention here. Maybe a filter predicate. Suggestions welcome.

```nix
gemEnv {
  name = "gems-prod";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;
  groups = [ "default" "production" ];
  platforms = [ "ruby" ] ++ {
    aarch64-darwin = [ "arm64-darwin" "universal-darwin" ];
    aarch64-linux = [ "aarch64-linux" "arm-linux-gnu"];
    x86_64-darwin = [ "x86_64-darwin" "universal-darwin" ];
    x86_64-linux = [ "x86_64-linux" "x86_64-linux-gnu" ];
  }.${pkgs.system} or [];
}
```


## WIP

This is a few days of coding. It's being used in prod but for a specific Rails app and its gems that gets daily attention from a team. There is probably more generalized usage to take into account and collect into unit tests. Still, in general, the hard parts are already solved in nixpkgs, this is just an alternate routes to collecting the relevant attributes for each gem.

- Bundling gems from source (git or path). Not too bad, buildRubyGem should do this for us, we just need to parse the Gemfile and Gemfile.lock correctly.
- It looks like buildRubyGem supports multiple remotes? Need to understand what that's about. Similar to the above.
- bundlerEnv has a much more complicated (generalizable?) buildEnv, need to study the differences.
- Better conventions for filtering platforms. Cf., [ffi](https://rubygems.org/gems/ffi/versions) and [nokogiri](https://rubygems.org/gems/nokogiri/versions).
- In all cases, we need better testing, I've been yolo `nix eval` and `nix build`ing it.

Once these are in a good place, I'm also thinking about pre Bundler 2.6 backwards compatibility. Maybe this is worth its own standalone tool to generate the hashes, if we have created compelling solutions to the other quirks present in Bundix.
