# Contributing to gems4nix

## Architecture Overview

gems4nix is a three-stage pipeline: **parse** the lockfile, **resolve** gems
for the target system, and **build** derivations via nixpkgs' `buildRubyGem`.
All parsing and resolution logic is pure Nix (no IO, no nixpkgs deps), making
it directly testable with `nix eval`. See [ARCHITECTURE.md](ARCHITECTURE.md)
for the full pipeline diagram and file map.

## How to Run Tests

```sh
# All checks (unit + integration) via flake
nix flake check

# Unit tests individually (returns true or throws on failure)
nix eval --file test/unit/test-parse.nix --json
nix eval --file test/unit/test-resolve.nix --json
nix eval --file test/unit/test-pipeline.nix --json
nix eval --file test/unit/test-credentials.nix --json
nix eval --file test/unit/test-arguments.nix --json
nix eval --file test/unit/test-bundler.nix --json

# The pending ledger: every known limitation is still a limitation
nix eval --file test/unit/test-pending.nix ledger

# Integration examples
cd examples/simple  && nix flake check --no-write-lock-file
cd examples/medium  && nix flake check --no-write-lock-file
cd examples/complex && nix flake check --no-write-lock-file

# Everything at once
nix eval --file test/unit/test-parse.nix --json && \
nix eval --file test/unit/test-resolve.nix --json && \
nix eval --file test/unit/test-pipeline.nix --json && \
nix eval --file test/unit/test-credentials.nix --json && \
nix eval --file test/unit/test-arguments.nix --json && \
nix eval --file test/unit/test-bundler.nix --json && \
nix eval --file test/unit/test-pending.nix ledger && \
echo "unit tests passed" && \
for ex in simple medium complex; do
  (cd examples/$ex && nix flake check --no-write-lock-file) || exit 1
done && \
echo "all tests passed"
```

`examples/complex` has a git-sourced gem, and `builtins.fetchGit` runs while Nix evaluates the flake. That check therefore needs the network every time, even when every gem is already in the store, and it obeys the git configuration of whoever runs it: a `url.<ssh>.insteadOf` rewrite for `https://github.com/` redirects the fetch to ssh, and it fails there if the ssh agent holds no usable key.

## How to Add a Test

1. Identify which layer the test belongs to:
   - **Parsing** (lockfile text to gem attrs) -- `test/unit/test-parse-logic.nix`
   - **Resolution** (filtering, platform matching) -- `test/unit/test-resolve-logic.nix`
   - **Pipeline** (end-to-end parse + resolve) -- `test/unit/test-pipeline-logic.nix`
   - **Credentials** (private registry auth) -- `test/unit/test-credentials-logic.nix`
   - **Argument surface** (what `gemfileEnv` accepts) -- `test/unit/test-arguments-logic.nix`
   - **Bundler's view of a git gem** (where Bundler reads one from) -- `test/unit/test-bundler-logic.nix`
   - **A known limitation you are not fixing yet** -- `test/unit/test-pending-logic.nix`

2. Add a test case. Each test is an `assertEq` call with a descriptive name:
   ```nix
   (assertEq "test_my_new_case"
     (someFunction someInput)
     expectedOutput)
   ```

3. Add it to the `allTests` list at the bottom of the file.

4. Run the test:
   ```sh
   nix eval --file test/unit/test-parse.nix --json
   ```
   It returns `true` on success or throws with the test name and diff on failure.

## How to Record a Limitation You Are Not Fixing

`test/unit/test-pending-logic.nix` holds tests written as the behaviour gems4nix should have and does not. Each one fails today, and the `ledger` it exports asserts that each one still fails, so `nix flake check` turns red the moment a limitation quietly stops being one. Write the test as a positive assertion, say what a fix would have to change, and name the file the test should move to when someone makes it pass.

A limitation no Nix expression can reach — a Bundler behaviour, a git server's behaviour, the evaluating user's configuration — goes in the same file's `nonTests` attrset as prose. Say why no test can reach it and what a test would need, so the next reader does not rediscover that from scratch.

## How to Contribute a Lockfile Fixture (Bug Reports)

If you have a `Gemfile.lock` that causes a build failure or incorrect behavior:

1. Add your `Gemfile.lock` to `test/fixtures/lockfiles/` with a descriptive
   name (e.g., `nokogiri-ruby-only.lock`).
2. Add a unit test in the appropriate `test-*-logic.nix` file that parses or
   resolves against your lockfile content and demonstrates the bug.
3. Open a PR or issue with both files.

Minimal lockfile excerpts are preferred over full lockfiles. Include at least
the `GEM`, `PLATFORMS`, and `CHECKSUMS` sections relevant to the bug.

## How to Add a Gem Config Override

Gem config overrides live in `lib/gemfile-env/gem-configs.nix`. Each entry is a
function that receives the gem's attributes and returns an attrset to merge:

```nix
{
  my-gem = attrs: {
    buildInputs = [ some-package ];
    NIX_CFLAGS_COMPILE = "-I${some-package}/include";
  };
}
```

Notes:
- Gem configs are only applied to ruby-platform gems (precompiled native gems
  skip config, since they do not need source build overrides).
- Check `nixpkgs.defaultGemConfig` first -- it may already handle your gem.
- Our local overrides in `gem-configs.nix` layer on top of `defaultGemConfig`.

## Test Philosophy

Tests follow a **red-green-refactor** loop:

1. **Red:** Write a test that captures expected behavior. Run it. Watch it fail
   (or verify it passes if testing existing correct behavior).
2. **Green:** Make the minimal change to pass the test.
3. **Refactor:** With passing tests as a safety net, clean up the code. Re-run
   tests to confirm nothing broke.

Key principles:
- Unit tests are pure Nix evaluations -- no network, no builds, no IO.
- Unit tests use synthetic lockfile content (inline strings), not real files.
- Integration tests (`examples/`) use real `Gemfile.lock` files from rubygems.org
  and build actual gem derivations.
- Shared assertion helpers (`assertEq`, `assertThrows`, `expectedFailure`) live in `test/helpers.nix`.

## Code Style

- Format with `nixfmt`.
- Pure logic files (`parse.nix`, `resolve.nix`) take only `{ lib }:` as input
  for testability. No nixpkgs build dependencies.
- IO (file reads, IFD) is isolated in `parse-gemfile-and-lockfile.nix`.
- Comments explain "why", not "what".
