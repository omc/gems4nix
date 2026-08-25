# TODO

> For the latest status, see [GitHub Issues](https://github.com/omc/gems4nix/issues).

## Critiques and Recommendations

### Parser (`parse.nix`, `parse-gemfile-and-lockfile.nix`)

1. **Done. Version-platform splitting parses from the right.**
   `splitVersionPlatform` matches the version token against a list of known Ruby platform strings and strips the matching suffix, rather than splitting on the first `-`. `1.16.0.beta.1-arm64-darwin` and `2.0.0-beta.2-aarch64-linux-gnu` both split correctly, and a token with no known suffix is `platform = "ruby"`. Gated by `test_parseChecksum_beta_version_with_platform`, `test_parseChecksum_prerelease_multi_segment_platform`, and the `splitVersionPlatform` tests in `test/unit/test-parse-logic.nix`.

2. **Open. `takeLines` processes the entire remaining file after `start`.**
   `builtins.foldl'` iterates over every line after the start index, even
   though it stops collecting at the first blank line. For a 1000-line lockfile
   with the CHECKSUMS section at line 745, `takeLines` for the first GEM
   section iterates ~1000 lines. This isn't a correctness bug but is worth
   noting for very large lockfiles.

3. **Open. `indexRemotes` is first-writer-wins for duplicate gem names.**
   `builtins.listToAttrs` on a flattened list means if the same gem name
   appears in multiple GEM sections (e.g., `faraday` from both rubygems.org
   and a private registry), only the first section's remote survives. The TODO
   in `parse.nix` acknowledges this, but the current behavior is
   silently arbitrary rather than loudly wrong.

4. **Open. No support for git or path sources.**
   Gems sourced from git repos or local paths are gracefully skipped by the
   parser (their hashless checksum lines return null) but are not included
   in the built environment. The `examples/complex/` integration test
   documents this: `errgonomic` (git) and `hello_gem` (path) print SKIP
   rather than OK. See also #13.

### Filtering and Building (`default.nix`)

5. **Done. Transitive dependencies survive group filtering.**
   Gems with `groups = []` (like `mini_portile2`, a build-time dependency of ruby-platform nokogiri) used to be dropped by `filterGroup`, producing `Could not find 'mini_portile2' (~> 2.8.2)` during the nokogiri build.

   The pipeline now expands the group-filtered set through the dependency graph parsed from the lockfile's `specs:` section (`expandTransitiveDeps` in `resolve.nix`), before platform filtering, so a kept gem's build-time dependencies are kept whatever their groups.

   **Regression test:** `test/unit/test-resolve-logic.nix` → `test_ruby_only_nokogiri_keeps_build_deps`, now a positive assertion in `allTests`.

### General

6. **Done. `nix flake check` runs the suite in CI.**
   `.github/workflows/ci.yml` runs `nix flake check` on every pull request and on pushes to `main`. The root `checks` output carries the unit suites, the credential, argument and Ruby-override wiring checks, and two `runCommand` integration checks that build real gem environments.

   Still by hand: the `examples/` flakes, each of which has its own `nix flake check`. CI is `x86_64-linux` only.

7. **Open. `gem-groups.rb` group propagation may over-propagate.**
   The Ruby script iterates all specs and propagates groups through
   descendants, but it does this for every spec regardless of whether that
   spec is a top-level dependency. A transitive dep shared by gems in
   different groups accumulates all groups, which may cause it to appear in
   groups the user didn't request (though this is arguably correct).

### Upstream nixpkgs alignment

The goal is to replace bundix while seamlessly supporting multi-platform gems
with pre-distributed native binaries, using only the Gemfile.lock as source of
truth. The closer we stay to nixpkgs' existing `ruby-modules/` infrastructure,
the less we maintain and the more we benefit from upstream fixes.

8. **Open. Use `bundled-common/functions.nix` instead of reimplementing helpers.**
   nixpkgs already has `filterGemset`, `platformMatches`, `groupMatches`,
   `applyGemConfigs`, and `composeGemAttrs` in
   `pkgs/development/ruby-modules/bundled-common/functions.nix`. Our
   `resolve.nix` reimplements some of these. The upstream versions
   handle edge cases we don't yet (e.g., `platformMatches` checks
   `ruby.rubyEngine` and `version.majMin`, not raw platform strings;
   `groupMatches` always includes `"default"`; `filterGemset` recursively
   expands transitive dependencies via a `converge` fixpoint).

   **Action:** Import and delegate to `bundled-common/functions.nix` where
   possible. Where our behavior intentionally diverges (e.g., platform
   matching by lockfile platform strings rather than Ruby engine), document
   why and keep our version. The functions that are clearly identical
   (`applyGemConfigs`, `groupMatches`) should be dropped in favor of
   upstream.

9. **Partly done. `ruby` and the platform guard landed; `gemPath` did not.**
   We still pass a flat attrset to `buildRubyGem` rather than delegating to upstream's `composeGemAttrs`. Of what that function assembles:

   - **Done.** The caller's `ruby` reaches `buildRubyGem`, so the gems and the `GEM_PATH` setup hook are built against the same Ruby. Gated by `test/integration/ruby-override/wiring.nix`.
   - **Done.** `type` and `gemName` come from the parsed metadata.
   - **Open.** `gemPath` is not set. A gem with a native extension that reads another gem's headers at build time (nokogiri wanting `mini_portile2`) does not see its siblings, so it can fail where `bundlerEnv` succeeds. The transitive expansion in #5 puts the sibling in the environment; it does not put it on the building gem's `gemPath`.

   **Action for the open half:** use `composeGemAttrs`, or replicate its `gemPath` logic, to wire up inter-gem build dependencies.

   **Fixed regression (grpc):** `defaultGemConfig`'s `grpc` entry carries a `postPatch` with `substituteInPlace Makefile`, intended for source compilation. Applying it by gem name alone reached the precompiled `grpc-1.78.1-arm64-darwin` variant, which has no `Makefile`, producing `substitute(): ERROR: file 'Makefile' does not exist`.

   The pipeline now resolves platform duplicates before applying gem configs, and applies them only when `platform == "ruby"`, so a precompiled variant never receives source-build overrides. Gated by `test_pipeline_precompiled_skips_gemConfig` and `test_pipeline_ruby_only_gets_gemConfig` in `test/unit/test-resolve-logic.nix`. Those tests assert against a local restatement of the pipeline rather than against `default.nix` itself, which is a real gap.

10. **Open. Produce Bundler-aware binstubs like `bundlerEnv` does.**
    Our `buildEnv` creates a flat symlink forest of gems, but doesn't
    generate Bundler-compatible binstubs. Upstream `bundlerEnv` runs
    `gen-bin-stubs.rb` which generates wrappers that call `Bundler.setup()`
    with the correct `GEM_PATH`, `BUNDLE_GEMFILE`, and `BUNDLE_FROZEN=1`.

    Without these, `bundle exec` and Bundler's runtime dependency resolution
    don't work in the Nix environment. Rails apps rely on `Bundler.setup()`
    to activate exactly the right gem versions. A plain `buildEnv` will have
    all gems on the `GEM_PATH` but Bundler won't know about them.

    **Action:** Either call `gen-bin-stubs.rb` in a `postBuild` hook (like
    `bundlerEnv` does), or provide a `confFiles` derivation with the
    Gemfile/Gemfile.lock pair and delegate to upstream's stubs machinery.

11. **Open. Emit a `gemset.nix`-compatible attrset for interop.**
    The parsed gem metadata is close (but not identical) to the
    `gemset.nix` format that `bundlerEnv` and `bundled-common` expect. The
    upstream format is keyed by gem name (not a list), includes a
    `dependencies` field, and uses `platforms` (plural, a list of
    `{ engine, version }` records) rather than `platform` (singular string).

    If we emitted a compatible attrset, users could:
    - Swap between gems4nix and bundlerEnv without changing their Nix code
    - Use `bundlerEnv` directly with our parsed output as the `gemset`
    - Incrementally adopt gems4nix without a hard cutover

    **Action:** Add a `toGemset` function to `parse.nix` that
    converts our internal representation to the `gemset.nix` format. This
    also serves as a migration path and compatibility layer.

12. **Done. Transitive dependency expansion is wired into the pipeline.**
    `parseDependencies` reads the indented dependency lines under each gem in the `specs:` section into a `{ gemName = [ deps ]; }` graph, and `expandTransitiveDeps` closes the group-filtered set over it. `gem-groups.rb` is still what assigns groups; the expansion is what stops a missed transitive dep from being silently dropped, which is the failure in #5.

    Dropping the Ruby `runCommand` entirely is a separate change, tracked in #14.

13. **Open. `buildRubyGem` can handle git and path sources natively.**
    `buildRubyGem` already supports `type = "git"` (via
    `nix-bundle-install.rb`, which monkey-patches Bundler to install from a
    git checkout) and path sources (via `pathDerivation` in
    `bundled-common/functions.nix`). We don't need to implement these from
    scratch; we just need to parse the `GIT` and `PATH` sections of the
    lockfile and pass the right attributes.

    The lockfile format for git sources is:
    ```
    GIT
      remote: https://github.com/user/repo.git
      revision: abc123
      specs:
        gemname (1.0.0)
    ```

    **Action:** Parse `GIT` and `PATH` sections alongside `GEM` sections.
    For git sources, set `source.type = "git"`, `source.url`, `source.rev`.
    For path sources, set `source.type = "path"`, `source.path`.
    `buildRubyGem` handles the rest.

14. **Partly done. The parsers exist; nothing calls them.**
    The `specs:` half is wired: `parseDependencies` feeds the expansion in #12.

    The `DEPENDENCIES` half is written and unit-tested but unreachable from the pipeline. `parseDependenciesSection` and `takeDependenciesSection` in `parse.nix` are exported and covered by `test/unit/test-parse-logic.nix`, and `parse-gemfile-and-lockfile.nix` calls neither. Retiring the IFD means calling them and propagating groups along the `specs:` edges in Nix.

    The rest of this item still stands. Between the two sections, the entire dependency graph and group assignment is recoverable from the lockfile alone, in pure Nix, without running Ruby.

    Eliminating the `runCommand` that invokes `gem-groups.rb` would:
    - Remove the Ruby/Bundler build-time dependency from evaluation
    - Make the parser fully pure (no IFD)
    - Speed up `nix eval` by avoiding a derivation build
    - Make the entire pipeline testable without IO

    **Action:** Parse the dependency tree from the `specs:` indentation
    structure (4-space = gem, 6-space = dependency). Parse group membership
    from the `DEPENDENCIES` section. Propagate groups through the dependency
    edges in pure Nix. This is the single highest-leverage change for the
    project's architecture.
