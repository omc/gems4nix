# TODO

## Critiques and Recommendations

### Parser (`parse-gemfile-and-lockfile.nix`)

1. **`parseChecksumLine` assumes exactly 3 space-delimited parts.**
   If a checksum line has unexpected formatting (extra spaces, missing hash),
   `builtins.elemAt parts 2` will throw an unhelpful index error. There's no
   validation or error message guiding the user.

2. **Version-platform splitting on `-` is naive.**
   `lib.splitString "-"` on the version token breaks for multi-segment semver
   pre-release versions (e.g., `1.0.0-beta.1`). A gem version like
   `1.0.0-beta1-arm64-darwin` would be misparsed: `version = "1.0.0"`,
   `platform = "beta1-arm64-darwin"`. In practice Ruby gems don't use
   pre-release hyphens in the lockfile (they use `.pre.`), but the parser
   doesn't assert this; it silently miscategorizes.

3. **`takeLines` processes the entire remaining file after `start`.**
   `builtins.foldl'` iterates over every line after the start index, even
   though it stops collecting at the first blank line. For a 1000-line lockfile
   with the CHECKSUMS section at line 745, `takeLines` for the first GEM
   section iterates ~1000 lines. This isn't a correctness bug but is worth
   noting for very large lockfiles.

4. **`gemRemotes` first-writer-wins for duplicate gem names.**
   `builtins.listToAttrs` on a flattened list means if the same gem name
   appears in multiple GEM sections (e.g., `faraday` from both rubygems.org
   and a private registry), only the first section's remote survives. The TODO
   in `parser-helpers.nix` acknowledges this, but the current behavior is
   silently arbitrary rather than loudly wrong.

5. **Missing CHECKSUMS is the only validated section.**
   If the `GEM` section is missing or malformed, the parser will produce
   empty results or cryptic errors rather than a clear message.

6. **No support for git or path sources.**
   Gems sourced from git repos or local paths are silently ignored or cause
   errors. This is acknowledged in the README but there's no guard or warning.

### Filtering and Building (`default.nix`)

7. **`filterPlatform` ignores its first argument.**
   The function signature is `filterPlatform = groups: gem: ...` but the body
   references the outer `platforms` binding, not the `groups` parameter. The
   parameter name is misleading (should be `platforms` or `_`), and the
   function ignores whatever is passed to it. It works only because it's
   always called as `filterPlatform platforms`, shadowing correctly by
   accident.

8. **Platform resolution picks `elemAt 0` arbitrarily.**
   When multiple platform-specific gems exist (e.g., `arm64-darwin` and
   `universal-darwin` both match), `builtins.elemAt otherPlatformGems 0`
   picks the first one in list order, which depends on filter ordering.
   There is no preference ranking among non-ruby platforms.

9. **`gemConfig` shadows the function argument.**
   The `let` block defines a local `gemConfig` that merges
   `defaultGemConfig` with a custom nokogiri config. But the function
   argument also accepts `gemConfig ? defaultGemConfig`. The local `let`
   binding shadows the argument, so user-supplied `gemConfig` is ignored.

10. **Empty group gems fall through filtering.**
    Gems with `groups = []` (like `mini_portile2`, a build-time dependency)
    are filtered out by `filterGroup` since their intersection with any
    requested groups is empty. This is probably correct, but it means
    build-time dependencies that appear in the lockfile are silently dropped.
    No warning is emitted.

### General

11. **Single integration test only.**
    The test suite is one `nix eval` of a full Rails gemfile. There are no
    unit tests for individual parser functions or filtering logic.

12. **No CI or automated test invocation.**
    Tests are run manually. No flake check, no `nix flake check` integration.

13. **`gem-groups.rb` group propagation may over-propagate.**
    The Ruby script iterates all specs and propagates groups through
    descendants, but it does this for every spec regardless of whether that
    spec is a top-level dependency. A transitive dep shared by gems in
    different groups accumulates all groups, which may cause it to appear in
    groups the user didn't request (though this is arguably correct).
