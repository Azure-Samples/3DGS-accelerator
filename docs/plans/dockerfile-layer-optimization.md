# Optimize Dockerfile Layer Caching for Frequent Rust Code Changes

**Status:** TODO — NEEDS REVIEW

## Problem Statement

The current Dockerfile places the Rust `builder` stage early, meaning any change to Rust source code invalidates downstream heavyweight layers (Python, CUDA, COLMAP). Since the Rust application changes far more frequently than the system/Python/CUDA/COLMAP toolchain, this causes unnecessarily long rebuild times during iterative development.

## Recommended Approach

Reorder and split Dockerfile stages so heavyweight, slow-changing system/Python/CUDA/COLMAP layers build first. Place Rust source compilation as late as possible with dependency-caching so that a Rust-only code change triggers only a fast recompile and binary copy — not a full image rebuild.

## Steps

### Phase 1: Reorder Stages (Slow-Changing First)

1. Create early "base" stages for system dependencies:
   - `base-os` / `base-gpu-runtime` for apt packages, CUDA runtime, Python env, COLMAP install.
   - These stages must not depend on any Rust source files.
2. For the GPU target specifically, ensure CUDA/PyTorch/COLMAP steps stay above Rust copy boundaries. Prevent accidental cache bust from `ARG`/`ENV` placement that can be deferred.

### Phase 2: Split Rust Build into Dependency + App Compile

3. Create a Rust dependency-caching stage:
   - Copy only `Cargo.toml` and `Cargo.lock` (and minimal crate manifests if workspace expands).
   - Run a skeleton build to download and compile all dependencies. This layer is invalidated only when dependencies change.
4. Create the Rust app build stage late in the file (*depends on step 3*):
   - Copy `src/` only after the dependency cache is established.
   - Compile and strip the final binary.

### Phase 3: Finalize Runtime Stage

5. Keep the runtime stage stable:
   - Inherit from the stable runtime base built in Phase 1.
   - Copy only the final Rust binary from Phase 2 and required runtime assets.
   - Avoid copying the full workspace into the runtime image.
6. Ensure CPU and GPU targets both consume the same prebuilt Rust artifact pattern without forcing early invalidation.

### Phase 4: Add BuildKit Cache Mounts

7. Add BuildKit cache mounts (`--mount=type=cache`) for Cargo registry/git and `target/` directory to speed repeated local and CI builds.

### Phase 5: Documentation

8. Update recommended build commands in `docs/DOCKER_BUILD.md` for iterative Rust development and release builds.

## Relevant Files

- `Dockerfile` — Primary stage reordering and cache optimization.
- `Cargo.toml` / `Cargo.lock` — Dependency graph input for dependency-layer caching.
- `docker-build.sh` — Align build scripts with optimized targets/flags.
- `docker-build-podman.sh` — Parity if podman path is used.
- `docs/DOCKER_BUILD.md` — Update guidance for cache-friendly workflows.

## Verification

1. Build once cold: `docker build --target gpu -t 3dgs-processor:gpu-latest .`
2. Modify one Rust source file only, rebuild, and confirm cache reuse in all non-Rust layers (check `--progress=plain` output).
3. Modify a `Cargo.toml` dependency and verify only the dependency/build layers invalidate — not the system/Python/COLMAP layers.
4. Repeat for CPU target and verify comparable caching behavior.
5. Run container smoke test to confirm the binary still executes and expected paths/env work.

## Decisions

- **Included:** Stage reordering, Rust-focused cache optimization, CPU and GPU target consistency, build reproducibility with lockfile-driven dependency caching.
- **Excluded:** Functional changes to app behavior, major dependency version upgrades, runtime architecture changes unrelated to build speed.

## Further Considerations

1. **Dependency caching method:**
   - Option A: `cargo-chef` — best structured caching, slight added complexity.
   - Option B: Manual dummy-build approach — simpler but less robust for complex workspaces.
   - Recommendation: Option A if acceptable in CI/dev images.
2. **CI integration:** Use buildx cache export/import (`type=registry` or `type=gha`) for remote cache reuse across builds.
3. **Multi-arch constraints:** Keep GPU `amd64`-only assumptions isolated so CPU multi-arch caching remains effective.
