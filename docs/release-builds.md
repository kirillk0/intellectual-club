# Release builds

`.github/workflows/publish-intellectual-club.yml` coordinates desktop releases
and Docker images for the same commit. The old standalone image workflow has
been merged into it.

The `frontend` job runs frontend tests and builds production web assets once on
Linux. `mix assets.deploy` includes Vue type checking, Vite, Phoenix assets and
digests, and the production PWA manifest. The `web-static-<commit SHA>` artifact
contains the entire static tree, its commit SHA, and SHA-256 hashes of all files.
Consumers validate the commit and file hashes before replacing their static tree.

macOS arm64, Windows x64, and the Linux amd64/arm64 application images reuse this
artifact. Elixir dependencies, native libraries, Erlang runtimes, and Rust
binaries remain platform-specific builds with separate caches. The platform
builds can run in parallel after their prerequisites complete.

Backend tests run once on Linux and once on Windows, both including the
`:whitebox` tests that local runs skip by default. Linux runs them through
`bin/server-test --all` in parallel partitions. Windows also runs Rust
tests and portable application smoke tests. macOS runs its bundle smoke test.
The desktop GitHub release waits for both desktop builds and the Linux backend
tests; Docker builds wait for Linux backend tests. Publication is disabled for
pull requests, which still run the shared frontend, Linux backend, and Windows
checks.

Pushes to `main` build desktop packages and detect changes affecting the two
Docker images. Manual runs expose `build_desktop`, `build_app`, and
`build_shell_outlet` switches. Docker image tags and the six desktop release
assets retain their existing conventions.

## Local builds

Local builds compile web assets themselves unless explicitly given an artifact.
Development bundles always build their own development assets.

After building production assets, export them for the current commit:

```sh
node bin/static-assets.mjs export build/ci-static "$(git rev-parse HEAD)"
```

The export directory must be empty. To reuse it on macOS:

```sh
IC_PREBUILT_STATIC_DIR="$PWD/build/ci-static" \
  ./bin/build-macos-app --mode prod --output build/release
```

On Windows, pass `-PrebuiltStaticDirectory build/ci-static` to
`bin/build-windows-release.ps1`. This skips frontend installation, tests, and
compilation, while retaining backend, Rust, and application smoke tests.

Plain `docker build .` still builds its own assets. With Buildx, an exported
artifact can be supplied as a named context:

```sh
docker buildx build \
  --build-context web-static=./build/ci-static \
  --build-arg STATIC_ASSETS=prebuilt \
  --build-arg BUILD_COMMIT_SHA="$(git rev-parse HEAD)" \
  .
```

Prebuilt mode fails for a missing, incomplete, modified, or different-commit
artifact instead of silently rebuilding assets. Artifacts belong to a single
workflow run; they are not selected from another run by a mutable branch name.
