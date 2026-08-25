Bundler 2.6 shipped with the ability to write checksums into its lockfile. That means for apps using Bundler >= 2.6 we no longer need a standalone tool to fetch gems and hash them. Instead we can parse the Gemfile and Gemfile.lock directly from Nix, which is what you're looking at here.

Along the way we're paying special attention to multi-platform support for Ruby gems. This had been problematic in Bundix, and solutions seem to be scattered across PRs in various states of languished. We may as well get that sorted out here as well, because I want to use Sorbet, and stop worrying about cross platform gems in general.

This project does make use of existing Nixpkgs abstractions as much as possible to avoid reimplementing work that doesn't need to be reimplemented. Notably, `buildRubyGem`. That lets us focus the scope, avoid rabbit holes, and generally derisk things.

Quick reference:

```nix
gemfileEnv {
  name = "test-gem-env";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;
};
```

Platforms are auto-detected from `stdenv.hostPlatform.system`. The mapping covers `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, and `x86_64-linux`, including musl and universal-darwin variants. You can override with an explicit `platforms` list if needed.

You can also provide `groups` to filter gems:

```nix
gemfileEnv {
  name = "gems-prod";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;
  groups = [ "default" "production" ];
  # platforms auto-detected; override if needed:
  # platforms = [ "ruby" "arm64-darwin" "universal-darwin" ];
}
```


## How platform resolution works

Many gems ship precompiled native variants alongside a pure-ruby fallback.
The lockfile's CHECKSUMS section lists all of them:

```
nokogiri (1.18.8) sha256=8c7464...          # pure ruby, compiles libxml2 from source
nokogiri (1.18.8-arm64-darwin) sha256=483b...  # precompiled for Apple Silicon
nokogiri (1.18.8-x86_64-linux-gnu) sha256=4a7... # precompiled for x86 Linux
```

gems4nix narrows this down in three steps, matching what `bundle install` does:

1. **Filter by platform.** Keep only variants whose platform string is in the
   accepted set for this system. On `aarch64-darwin` that's
   `["ruby" "arm64-darwin" "universal-darwin"]`. This discards
   `x86_64-linux-gnu` etc.

2. **Prefer native over ruby.** If both `arm64-darwin` and `ruby` variants
   survive the filter, pick the native one. Native gems are precompiled, which
   means less compile time and complexity, and maybe better cache behavior.

3. **One gem per name.** After resolution each gem name maps to exactly one
   derivation.

`ffi` works the same way, its native variants avoid compiling libffi:

```
ffi (1.17.2)                    # needs libffi headers + C compiler
ffi (1.17.2-arm64-darwin)       # precompiled, no build deps
```

The `PLATFORMS` section of the lockfile tells Bundler which platforms to
resolve for. It may list platforms like `universal-darwin` that no gem
actually ships a variant for. That's fine, those simply match nothing and
the `ruby` fallback is used.

### Preference ranking

`resolvePlatforms` accepts a preference-ordered platform list (from
`platformsForSystem`) and ranks candidates by position. On `aarch64-darwin`
the order is `["ruby" "arm64-darwin" "universal-darwin"]`, so an exact
arch match always beats a compatible one, and any native variant beats
pure ruby.

## Git and path sources

`GIT` and `PATH` sections of the lockfile are parsed and built alongside `GEM`
ones. Nothing to configure for the common case:

```
GIT
  remote: https://github.com/omc/errgonomic.git
  revision: f06314af89209f855019219fd198513855be0fd5
  branch: main
  specs:
    errgonomic (0.5.1)

PATH
  remote: vendor/hello_gem
  specs:
    hello_gem (0.1.0)
```

Git gems are fetched with `builtins.fetchGit`, pinned to `revision:`. There is
no hash in the lockfile for these, and inventing a side table of hashes is
exactly the bundix workflow this project exists to delete. The tradeoffs are
real and worth knowing:

- **The fetch happens at evaluation time.** `nix eval`, `nix flake show` and
  `nix flake check` on anything touching a git gem need network access and, for
  a private repo, credentials. Remote builders don't help; evaluation is local.
- **A private repo needs credentials your git already has.**
  `builtins.fetchGit` runs your git as you, so a credential source that git
  reaches should work. A `url.<ssh>.insteadOf` rewrite onto an ssh key is the
  one we verified. Two things that look like they should work don't. Nix's
  `access-tokens` setting covers the `github:` and `gitlab:` flake fetchers,
  not `builtins.fetchGit` on a plain git URL. And a credential helper needs an
  entry for the host: one holding no GitHub credential failed the way an
  unconfigured machine does,
  `fatal: could not read Username for 'https://github.com'`. A CI runner needs
  its own arrangement — a deploy key plus an `insteadOf` rewrite, a netrc or
  token helper, or `gemSrcOverrides`.
- **The result is not substitutable.** It isn't a fixed-output derivation, so a
  binary cache can't serve it. Every fresh machine refetches.
- If that doesn't suit you, `gemSrcOverrides` swaps the fetcher per gem:

  ```nix
  gemSrcOverrides.errgonomic = pkgs.fetchgit {
    url = "https://github.com/omc/errgonomic.git";
    rev = "f06314af89209f855019219fd198513855be0fd5";
    hash = "sha256-...";
  };
  ```

Path remotes resolve against the Gemfile's directory. Pass `root` when the
path gems live somewhere else. The usual case is a Gemfile written into the
store with `writeText`, whose directory is `/nix/store`:

```nix
gemfileEnv {
  name = "my-app";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;
  root = ./.;
}
```

`root` must be a Nix **path**, not a string: `..` and `.` in a remote are
normalised by path arithmetic, and a string wouldn't be copied into the store.
A path gem's source must also be reachable from the flake. A `remote:
../shared/mygem` works only when that directory sits inside the flake's source
tree. A missing one is an evaluation error naming `root`, not a silent skip.

Known limitations, stated rather than implied:

- **A git gem is invisible to `bundler/setup`.** Plain `require` finds it, so a
  Rails app that boots through Bundler cannot use one. The next section has the
  detail and the workaround.
- **Native extensions in a git gem will fail.** They need `gemPath` wired up for
  inter-gem build dependencies (TODO #9). Pure-Ruby git gems are what's tested.
- **Only GitHub is exercised.** Fetching a bare SHA is verified against GitHub;
  `allRefs = true` is the hedge for servers that don't set
  `uploadpack.allowAnySHA1InWant`, but other hosts are untested.
- `glob:` on a GIT or PATH section throws, as does a `PLUGIN SOURCE` section.
  `buildRubyGem` builds the first `*.gemspec` it finds, so honouring a glob
  isn't possible without silently picking the wrong gem.
- Any `CHECKSUMS` line without a hash that no GIT or PATH section explains is
  now an evaluation error. Previously such gems were dropped silently and only
  surfaced as a `LoadError` at runtime.

### Git gems don't work under `bundler/setup` yet

Read this before you put a git gem in a Rails app.

We install a git gem as an ordinary gem, so plain `require` finds it through
the `GEM_PATH`. Bundler doesn't. `Bundler::Source::Git` looks for a git gem in
`bundler/gems/<name>-<shortrev>` under Bundler's install path — `GEM_HOME`
unless `BUNDLE_PATH` says otherwise — and nowhere else. So an app that boots
with `require "bundler/setup"`, which is every stock Rails app, fails on the
git gem:

```
bundler/source/git.rb:236:in `rescue in load_spec_files':
  https://github.com/omc/errgonomic.git (at main@f06314a) is not yet
  checked out. Run `bundle install` first. (Bundler::GitError)
```

That transcript is bundler 2.5.22. The line number moves between releases.

Gems from `GEM` and `PATH` sections are fine. Bundler resolves a rubygems gem
through `Gem::Specification`, which reads the `GEM_PATH`, and it reads a path
gem's gemspec straight out of its directory. Only `GIT` sources are affected.

**Until this is fixed, vendor the gem and depend on it as a `PATH` source, or
publish it to a registry.** A vendored path gem loads under `bundler/setup`
with no `bundle install`. `TODO.md` item 10 is the real fix and item 13 has the
detail.

## Testing

Unit tests for the parser and filter helpers:

```sh
nix eval --file test/unit/test-parser.nix --json
nix eval --file test/unit/test-filter.nix --json
```

Integration tests via `examples/`:

```sh
cd examples/simple  && nix flake check --no-write-lock-file
cd examples/medium  && nix flake check --no-write-lock-file
cd examples/complex && nix flake check --no-write-lock-file
```

| Example   | Gems | What it tests |
|-----------|------|---------------|
| `simple`  | rack, rake | Pure-ruby gems load and report correct versions |
| `medium`  | nokogiri, puma, ethon, rack, minitest | Native platform variants, group filtering, `defaultGemConfig` overrides |
| `complex` | Rails 8, ffi, nokogiri, bootsnap, errgonomic (git), hello_gem (path) | Full Rails env, git and path sources, transitive deps |

See `TESTING.md` for the full test strategy, structure, and red-green-refactor workflow.

## WIP

This is a few days of coding. It's being used in prod but for a specific Rails app and its gems that gets daily attention from a team. There is probably more generalized usage to take into account and collect into unit tests. Still, in general, the hard parts are already solved in nixpkgs, this is just an alternate route to collecting the relevant attributes for each gem.

- `bundlerEnv` has a much more capable `buildEnv` with Bundler-aware binstubs. Need to study the differences and decide what to adopt.
- See `TODO.md` for the full list of critiques and upstream alignment opportunities.

Once these are in a good place, I'm also thinking about pre Bundler 2.6 backwards compatibility. Maybe this is worth its own standalone tool to generate the hashes, if we have created compelling solutions to the other quirks present in Bundix.
