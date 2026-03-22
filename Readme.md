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

Platforms are auto-detected from `stdenv.hostPlatform.system`. The mapping covers `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, and `x86_64-linux`, including musl and universal-darwin variants. You can override with an explicit `platforms` list if needed.

You can also provide `groups` to filter gems:

```nix
gemEnv {
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
| `complex` | Rails 8, ffi, nokogiri, bootsnap, errgonomic (git), hello_gem (path) | Full Rails env, git/path sources (SKIP until TODO #13) |

See `TESTING.md` for the full test strategy, structure, and red-green-refactor workflow.

## WIP

This is a few days of coding. It's being used in prod but for a specific Rails app and its gems that gets daily attention from a team. There is probably more generalized usage to take into account and collect into unit tests. Still, in general, the hard parts are already solved in nixpkgs, this is just an alternate route to collecting the relevant attributes for each gem.

- Git and path gem sources. The parser gracefully skips these (no crash), but the gems aren't included in the environment. `buildRubyGem` already handles both source types; we just need to parse the `GIT` and `PATH` lockfile sections.
- `bundlerEnv` has a much more capable `buildEnv` with Bundler-aware binstubs. Need to study the differences and decide what to adopt.
- See `TODO.md` for the full list of critiques and upstream alignment opportunities.

Once these are in a good place, I'm also thinking about pre Bundler 2.6 backwards compatibility. Maybe this is worth its own standalone tool to generate the hashes, if we have created compelling solutions to the other quirks present in Bundix.
