# Lockfile Fixtures

Real and synthetic `Gemfile.lock` files used by unit tests.

## Contributing a fixture

1. Copy your `Gemfile.lock` into this directory with a descriptive name
   (e.g., `grpc-old-style.lock`, `private-remote.lock`).
2. Ensure the lockfile includes a `CHECKSUMS` section (`bundle lock --add-checksums`).
3. Add platforms with `bundle lock --add-platform <platform>` if testing
   platform resolution.
4. Reference the fixture from a test in `test/unit/`.

## Existing fixtures

| File | Description |
|------|-------------|
| `minimal.lock` | Two pure-Ruby gems (rack, rake). Copied from `examples/simple/`. |
| `medium.lock` | Nokogiri, ffi, puma with multi-platform variants. Copied from `examples/medium/`. |
| `ruby-only.lock` | Only `ruby` in PLATFORMS -- no precompiled native variants. |
