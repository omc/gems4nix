# Testing Strategy

## Philosophy

Tests follow a **red-green-refactor** loop:

1. **Red:** Write a test that captures expected behavior. Run it. Watch it
   fail (or verify it passes if testing existing correct behavior). For new
   bug-fix tests, the test should fail against the current code to confirm the
   bug is real before fixing.

2. **Green:** Make the minimal change to pass the test. For tests that
   validate existing correct behavior, this step is already done: the test
   passes on first run, confirming the implementation is correct.

3. **Refactor:** With passing tests as a safety net, improve the code. Rerun
   tests to confirm nothing broke.

## Test Structure

```
lib/gemfile-env/
├── default.nix                        # orchestrator: imports helpers, builds gems
├── parse-gemfile-and-lockfile.nix     # IO shell: readFile, runCommand, delegates to helpers
├── parser-helpers.nix                 # pure: all parsing (line, section, lockfile assembly)
├── filter-helpers.nix                 # pure: filterGroup, filterPlatform, resolvePlatforms
├── gem-groups.rb                      # Ruby script for group extraction
└── gem-dependencies.rb                # (placeholder)

test/
├── test-helpers.nix                   # shared assertEq, assertThrows
├── test.nix                           # integration test (full Rails build)
├── unit/
│   ├── test-parser.nix                # unit tests for parser-helpers.nix
│   └── test-filter.nix                # unit tests for filter-helpers.nix
└── rails/
    ├── Gemfile
    ├── Gemfile.lock
    └── gemset.nix
```

### Architecture for testability

All pure logic lives in `*-helpers.nix` files that take only `{ lib }` as
input. The production modules (`parse-gemfile-and-lockfile.nix`, `default.nix`)
import these helpers and add IO / nixpkgs build concerns on top. Tests import
the helpers directly to avoid needing `callPackage`, `runCommand`, or Ruby.

Shared assertion functions (`assertEq`, `assertThrows`) live in
`test/test-helpers.nix` and are imported by all unit test files.

### Integration test (`test/test.nix`)

The existing test that evaluates a full `gemfileEnv` against the Rails
fixture. This remains as-is and validates the end-to-end pipeline.

## What to Test

### Parser unit tests (`test-parser.nix`)

| Function            | Test case                                         | Validates                          |
|---------------------|---------------------------------------------------|------------------------------------|
| `findIndices`       | Multiple matches in a list                        | Returns all matching indices       |
| `findIndices`       | No matches                                        | Returns empty list                 |
| `findIndices`       | Single match                                      | Returns singleton list             |
| `takeLines`         | Lines until first blank                           | Stops at empty string              |
| `takeLines`         | No blank line (runs to end)                       | Returns remaining lines            |
| `takeLines`         | Blank line immediately after header               | Returns empty list                 |
| `parseChecksumLine` | Simple gem (no platform)                          | Correct name, version, sha256      |
| `parseChecksumLine` | Platform-specific gem (`arm64-darwin`)             | Platform parsed, not in version    |
| `parseChecksumLine` | Multi-segment platform (`aarch64-linux-gnu`)       | Full platform string preserved     |
| `parseChecksumLine` | Multi-segment version (`1.18.8`)                  | Version not split on dots          |
| `parseGemSection`   | Standard rubygems section                         | Remote URL and gem list extracted   |
| `parseGemSection`   | Remote with trailing slash                        | Trailing slash stripped             |
| `parseGemSection`   | Remote without trailing slash                     | URL preserved as-is                |
| `parseGemSection`   | Gems with complex dependency lines                | Only gem names extracted            |

### Filter unit tests (`test-filter.nix`)

| Function              | Test case                                       | Validates                          |
|-----------------------|-------------------------------------------------|------------------------------------|
| `filterGroup`         | Gem with matching group                         | Included                           |
| `filterGroup`         | Gem with no matching group                      | Excluded                           |
| `filterGroup`         | Gem with multiple groups, one matches            | Included                           |
| `filterGroup`         | Gem with empty groups                           | Excluded                           |
| `filterPlatform`      | Gem matches one of requested platforms           | Included                           |
| `filterPlatform`      | Gem platform not in requested list               | Excluded                           |
| `filterPlatform`      | "ruby" platform gem with "ruby" requested        | Included                           |
| Platform resolution   | Platform-specific preferred over ruby            | Non-ruby gem selected              |
| Platform resolution   | Only ruby available                              | Ruby gem selected                  |
| Platform resolution   | Multiple non-ruby platforms                      | First one selected (documents behavior) |

## Running Tests

### Run all unit tests

```sh
# Parser unit tests
nix eval --file test/unit/test-parser.nix --json

# Filter unit tests
nix eval --file test/unit/test-filter.nix --json

# Both (bash one-liner)
nix eval --file test/unit/test-parser.nix --json && \
nix eval --file test/unit/test-filter.nix --json && \
echo "all unit tests passed"
```

### Run integration test

```sh
nix eval --file test/test.nix
# or, to actually build the gem environment:
nix build --file test/test.nix
```

### Red-green-refactor example

```sh
# 1. RED: write a new test case in test/unit/test-parser.nix, then:
nix eval --file test/unit/test-parser.nix --json
# => error: ... (test fails; good, the bug is confirmed)

# 2. GREEN: fix the code in lib/gemfile-env/parse-gemfile-and-lockfile.nix
nix eval --file test/unit/test-parser.nix --json
# => true (test passes; fix is correct)

# 3. REFACTOR: clean up, then re-run to confirm nothing broke
nix eval --file test/unit/test-parser.nix --json && \
nix eval --file test/unit/test-filter.nix --json && \
echo "all tests still pass"
```

Each `nix eval` returns `true` on success or throws an assertion error with a
descriptive message on failure. No external test harness needed.
