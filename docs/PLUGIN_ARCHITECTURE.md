# Plugin Architecture: Backend System Deep Dive

> **Audience:** Developers building or maintaining backend plugins for the 3DGS Video Processor.  
> **Last updated:** March 2026  
> **See also:** [plugins/README.md](../plugins/README.md) (operational usage), [ARCHITECTURE.md](ARCHITECTURE.md) (system overview)

---

## Table of Contents

- [Overview](#overview)
- [Where Plugins Operate in the Pipeline](#where-plugins-operate-in-the-pipeline)
- [Loading Model: Dynamic vs. Compiled](#loading-model-dynamic-vs-compiled)
- [Plugin Discovery](#plugin-discovery)
- [Binary Interface (ABI) Contract](#binary-interface-abi-contract)
- [The GaussianSplatBackend Trait](#the-gaussiansplatbackend-trait)
- [Types a Plugin Must Understand](#types-a-plugin-must-understand)
- [Building a Plugin: Step-by-Step](#building-a-plugin-step-by-step)
- [Configuration and Backend Selection](#configuration-and-backend-selection)
- [Safety and Limitations](#safety-and-limitations)
- [Troubleshooting](#troubleshooting)

---

## Overview

The 3DGS Video Processor uses a **plugin-based backend architecture** to support multiple 3D Gaussian Splatting training implementations. A "backend" is a component that takes camera-posed image frames and produces a trained Gaussian Splatting model, then exports it to PLY and SPLAT formats.

Backends can be delivered in two ways:

| Delivery | Description | Example |
|----------|-------------|---------|
| **Built-in** | Compiled directly into the `3dgs-processor` binary. Always available. | `gaussian-splatting`, `gsplat`, `3dgs-cpp`, `mock` |
| **Plugin** | A separate shared library (`.so`/`.dylib`/`.dll`) placed in a plugin directory and loaded at runtime via `libloading`. | Any custom backend |

The plugin system allows new training backends to be added **without recompiling the core binary** — just drop a shared library into the `./plugins/` directory and set `BACKEND=<name>`.

---

## Where Plugins Operate in the Pipeline

Plugins operate at a **single, well-defined stage** — the training and export phase. They do NOT participate in file watching, video decoding, frame extraction, or COLMAP reconstruction.

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Processing Pipeline                         │
│                                                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────────────┐    │
│  │  1. File     │    │  2. Frame   │    │  3. COLMAP Sparse    │    │
│  │  Watcher     │───▶│  Extraction │───▶│  Reconstruction      │    │
│  │  (notify)    │    │  (FFmpeg)   │    │  (Feature matching,  │    │
│  └─────────────┘    └─────────────┘    │   camera poses)      │    │
│                                         └──────────┬───────────┘    │
│                                                     │               │
│                                                     ▼               │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                                                              │   │
│  │              ╔══════════════════════════════╗                 │   │
│  │              ║   4. BACKEND PLUGIN STAGE    ║                 │   │
│  │              ║                              ║                 │   │
│  │              ║  4a. train()                 ║                 │   │
│  │              ║      Input: frame paths +    ║                 │   │
│  │              ║             TrainingConfig    ║                 │   │
│  │              ║      Output: BackendOutput   ║                 │   │
│  │              ║                              ║                 │   │
│  │              ║  4b. export_ply()            ║                 │   │
│  │              ║      Write .ply file         ║                 │   │
│  │              ║                              ║                 │   │
│  │              ║  4c. export_splat()          ║                 │   │
│  │              ║      Write .splat file       ║                 │   │
│  │              ╚══════════════════════════════╝                 │   │
│  │                                                              │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                     │               │
│                                                     ▼               │
│                                         ┌──────────────────────┐    │
│                                         │  5. Output Files     │    │
│                                         │  (model.ply,         │    │
│                                         │   model.splat,       │    │
│                                         │   manifest.json)     │    │
│                                         └──────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

**What your plugin receives:** Paths to extracted image frames (JPEG/PNG) and a `TrainingConfig` struct with hyperparameters. The COLMAP reconstruction (camera poses, sparse point cloud) is available in the workspace directory structure.

**What your plugin produces:** A `BackendOutput` struct with the model checkpoint path, iteration count, loss metrics, and metadata. Then `.ply` and `.splat` export files.

---

## Loading Model: Dynamic vs. Compiled

The system uses a **three-tier resolution** strategy implemented in `BackendRegistry` (`src/backends/registry.rs`):

```
User requests backend "my-backend"
         │
         ▼
┌─────────────────────────┐
│ 1. Built-in Factories   │  HashMap<String, BackendFactory>
│    (compiled into binary)│  Checked first. O(1) lookup.
│                         │
│    gaussian-splatting ✓ │
│    gsplat             ✓ │
│    3dgs-cpp           ✓ │
│    mock               ✓ │
└────────────┬────────────┘
             │ Not found
             ▼
┌─────────────────────────┐
│ 2. Plugin Cache         │  HashMap<String, Arc<dyn Backend>>
│    (previously loaded   │  Avoids re-loading .so files.
│     plugins in memory)  │
└────────────┬────────────┘
             │ Not found
             ▼
┌─────────────────────────┐
│ 3. Plugin Discovery     │  Search filesystem for .so/.dylib/.dll
│    (PluginLoader)       │  Load via libloading, call create_backend()
│                         │  Cache result for future requests.
└─────────────────────────┘
```

**Built-in backends** are registered at startup via `register_defaults()`:

```rust
pub fn register_defaults(&mut self) {
    self.register("gaussian-splatting", || Arc::new(GaussianSplattingBackend::new()));
    self.register("gsplat", || Arc::new(GsplatBackend::new()));
    self.register("3dgs-cpp", || Arc::new(ThreeDGSCppBackend::new()));
    self.register("mock", || Arc::new(MockBackend::new()));
}
```

**Plugin backends** are only loaded when a name doesn't match any built-in. The `libloading` crate performs the actual dynamic library loading at runtime.

---

## Plugin Discovery

When a backend name is not found in the built-in registry or plugin cache, `PluginLoader` (`src/backends/plugin_loader.rs`) searches the filesystem.

### Search Path Order (Highest to Lowest Priority)

| Priority | Source | Path | Condition |
|----------|--------|------|-----------|
| 1 | `PLUGIN_PATH` env var | User-defined directory | Only if directory exists |
| 2 | Relative to executable | `<exe_dir>/plugins/` | Only if directory exists |
| 3 | System-wide | `/usr/local/lib/3dgs-processor/plugins/` | Only if directory exists |
| 4 | Current working directory | `./plugins/` | Only if directory exists |

### Platform-Specific Library Naming

Given a backend name (e.g., `"my-renderer"`), the loader constructs the filename:

| Platform | Pattern | Example |
|----------|---------|---------|
| Linux | `lib{name}_backend.so` | `libmy-renderer_backend.so` |
| macOS | `lib{name}_backend.dylib` | `libmy-renderer_backend.dylib` |
| Windows | `{name}_backend.dll` | `my-renderer_backend.dll` |

### Discovery Algorithm

```
1. Compute library filename for platform
2. For each search path (in priority order):
     a. Check if <search_path>/<library_filename> exists
     b. If found → return path, stop searching
3. If no match → return error with list of searched paths
```

### Listing Available Plugins

`PluginLoader::list_available_plugins()` scans all search paths and extracts backend names from filenames matching the naming pattern. This is used by `BackendRegistry::list_backends()` to show all available backends (built-in + plugin).

---

## Binary Interface (ABI) Contract

### The `create_backend` Function

Every plugin shared library **must export exactly one C-ABI function**:

```rust
#[no_mangle]
#[allow(improper_ctypes_definitions)]
pub extern "C" fn create_backend() -> Box<dyn GaussianSplatBackend> {
    Box::new(MyBackend::new())
}
```

**Requirements:**

| Attribute | Purpose |
|-----------|---------|
| `#[no_mangle]` | Prevents Rust name mangling so the symbol is discoverable as `create_backend` |
| `extern "C"` | Uses C calling convention for stable function call ABI |
| Return type `Box<dyn GaussianSplatBackend>` | Returns a heap-allocated trait object |

### Host-Side Loading

The host binary (`src/backends/plugin_loader.rs`) defines the type alias and loading sequence:

```rust
#[allow(improper_ctypes_definitions)]
type CreateBackendFn = unsafe extern "C" fn() -> Box<dyn GaussianSplatBackend>;

// Loading sequence:
let library = unsafe { Library::new(&plugin_path)? };                    // 1. Open .so
let create_backend: Symbol<CreateBackendFn> = unsafe {
    library.get(b"create_backend")?                                      // 2. Resolve symbol
};
let backend = unsafe { create_backend() };                               // 3. Call constructor
self.libraries.push(library);                                            // 4. Keep library alive
```

The library handle is stored in a `Vec<Library>` to prevent the OS from unloading the shared library while the backend is still in use.

### ⚠️ ABI Compatibility: Critical Constraint

The `Box<dyn GaussianSplatBackend>` return type is a Rust **trait object** — a fat pointer containing a data pointer and a vtable pointer. **This is NOT a stable C ABI.** It relies on Rust's internal memory layout, which means:

> **The plugin and the host binary MUST be compiled with the same Rust compiler version and the same version of all shared dependencies** (`anyhow`, `async-trait`, `serde`, etc.).

If there is a version mismatch, you may encounter:
- Segfaults when calling trait methods
- Corrupted vtable pointers
- Undefined behavior

**Best practice:** Build plugins in the same workspace or with the same `Cargo.lock` as the host binary.

---

## The GaussianSplatBackend Trait

Defined in `src/backends/mod.rs`, this is the trait every backend (built-in or plugin) must implement:

```rust
use anyhow::Result;
use async_trait::async_trait;
use std::path::Path;

#[async_trait]
pub trait GaussianSplatBackend: Send + Sync {
    /// Train a 3DGS model from extracted frames.
    ///
    /// `frames` — Paths to JPEG/PNG images (ordered temporally if from video).
    /// `config` — Hyperparameters: iterations, learning rate, densification settings.
    ///
    /// Returns BackendOutput with model path, iteration count, and metadata.
    /// This is typically long-running (minutes to hours).
    async fn train(&self, frames: &[&Path], config: &TrainingConfig) -> Result<BackendOutput>;

    /// Export the trained model to PLY (Polygon File Format).
    ///
    /// PLY is the standard 3D point cloud format with Gaussian attributes
    /// (position, covariance, spherical harmonics, opacity).
    async fn export_ply(&self, model: &BackendOutput, output_path: &Path) -> Result<()>;

    /// Export the trained model to SPLAT format.
    ///
    /// SPLAT is a compact binary format optimized for real-time web rendering.
    /// 32 bytes per Gaussian: position, scale, rotation, color, opacity.
    async fn export_splat(&self, model: &BackendOutput, output_path: &Path) -> Result<()>;
}
```

**Trait bounds:** `Send + Sync` are required because backends are used in tokio async contexts and may be shared across tasks via `Arc<dyn GaussianSplatBackend>`.

**Async methods:** The `#[async_trait]` macro desugars these to `Pin<Box<dyn Future>>`. If your backend does synchronous/blocking work (e.g., calling an external binary), wrap it in `tokio::task::spawn_blocking`:

```rust
async fn train(&self, frames: &[&Path], config: &TrainingConfig) -> Result<BackendOutput> {
    let frames_owned: Vec<PathBuf> = frames.iter().map(|p| p.to_path_buf()).collect();
    let config = config.clone();

    tokio::task::spawn_blocking(move || {
        // Call external binary, do CPU-intensive work, etc.
        run_training_sync(&frames_owned, &config)
    })
    .await
    .context("Training task panicked")?
}
```

---

## Types a Plugin Must Understand

### `TrainingConfig`

Defined in `src/config/yaml.rs`. Passed as input to `train()`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrainingConfig {
    pub iterations: u32,              // Default: 30000
    pub learning_rate: f64,           // Default: 0.0025
    pub densification_interval: u32,  // Default: 100
    pub densification_start: u32,     // Default: 500
    pub densification_stop: u32,      // Default: 15000
    pub opacity_reset_interval: u32,  // Default: 3000
}
```

### `BackendOutput`

Defined in `src/backends/models.rs`. Returned from `train()`, passed to `export_ply()` and `export_splat()`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackendOutput {
    pub model_path: PathBuf,          // Path to trained model checkpoint
    pub iterations_completed: u32,    // Actual iterations run
    pub final_loss: Option<f64>,      // Final training loss
    pub gaussian_count: Option<usize>,// Number of Gaussian primitives
    pub metadata: BackendMetadata,    // Backend-specific metadata
}
```

Construct with `BackendOutput::new(model_path, iterations, backend_name)` and optionally set `final_loss`, `gaussian_count`, etc.

### `BackendMetadata`

Defined in `src/backends/models.rs`. Included in `BackendOutput`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BackendMetadata {
    pub backend_name: String,
    pub backend_version: Option<String>,
    pub training_time_secs: Option<f64>,
    pub peak_memory_bytes: Option<usize>,
    pub gpu_device: Option<String>,
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,  // Custom key-value pairs
}
```

The `extra` field allows plugins to include arbitrary metadata without modifying the core types.

---

## Building a Plugin: Step-by-Step

### 1. Create a Separate Crate

```bash
cargo new --lib my-3dgs-backend
cd my-3dgs-backend
```

### 2. Configure `Cargo.toml`

```toml
[package]
name = "my-3dgs-backend"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]   # Produces a .so / .dylib / .dll

[dependencies]
three_dgs_processor = { path = "../3DGS-accelerator" }  # Or git URL
anyhow = "1.0"
async-trait = "0.1"
tokio = { version = "1.40", features = ["full"] }
```

> **Critical:** `crate-type = ["cdylib"]` tells Cargo to produce a C-compatible shared library.

### 3. Implement the Backend Trait

```rust
// src/lib.rs
use anyhow::{Context, Result};
use async_trait::async_trait;
use std::path::{Path, PathBuf};
use three_dgs_processor::backends::{
    BackendMetadata, BackendOutput, GaussianSplatBackend, TrainingConfig,
};

pub struct MyBackend;

impl MyBackend {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl GaussianSplatBackend for MyBackend {
    async fn train(&self, frames: &[&Path], config: &TrainingConfig) -> Result<BackendOutput> {
        let frames_owned: Vec<PathBuf> = frames.iter().map(|p| p.to_path_buf()).collect();
        let iterations = config.iterations;

        let output = tokio::task::spawn_blocking(move || -> Result<BackendOutput> {
            // YOUR TRAINING LOGIC HERE
            // e.g., call an external binary, run a Python script, etc.

            let model_path = PathBuf::from("/tmp/my-model/checkpoint.pth");
            let mut output = BackendOutput::new(
                model_path,
                iterations,
                "my-backend".to_string(),
            );
            output.final_loss = Some(0.001);
            output.gaussian_count = Some(500_000);
            output.metadata.training_time_secs = Some(120.0);
            Ok(output)
        })
        .await
        .context("Training task panicked")??;

        Ok(output)
    }

    async fn export_ply(&self, model: &BackendOutput, output_path: &Path) -> Result<()> {
        // Copy or convert the model to PLY format
        std::fs::copy(&model.model_path, output_path)
            .context("Failed to export PLY")?;
        Ok(())
    }

    async fn export_splat(&self, model: &BackendOutput, output_path: &Path) -> Result<()> {
        // Convert the model to SPLAT format
        // ...
        Ok(())
    }
}
```

### 4. Export the Constructor Function

Add this at the bottom of `src/lib.rs`:

```rust
/// Plugin entry point. Called by the host to create a backend instance.
///
/// # Safety
/// This function is called across the FFI boundary via libloading.
/// The host and plugin must be compiled with the same Rust toolchain.
#[no_mangle]
#[allow(improper_ctypes_definitions)]
pub extern "C" fn create_backend() -> Box<dyn GaussianSplatBackend> {
    Box::new(MyBackend::new())
}
```

### 5. Build the Plugin

```bash
cargo build --release
```

This produces:
- **Linux:** `target/release/libmy_3dgs_backend.so`
- **macOS:** `target/release/libmy_3dgs_backend.dylib`
- **Windows:** `target/release/my_3dgs_backend.dll`

### 6. Install the Plugin

Rename the library to match the naming convention and copy to a plugin directory:

```bash
# Linux example — backend name will be "my-backend"
cp target/release/libmy_3dgs_backend.so \
   /path/to/3DGS-accelerator/plugins/libmy-backend_backend.so
```

### 7. Use the Plugin

```bash
export BACKEND=my-backend
./3dgs-processor
```

Or in `config.yaml`:

```yaml
backend: "my-backend"
```

---

## Configuration and Backend Selection

### Selection Priority

The backend is resolved by `BackendRegistry::resolve_backend_name()` in this order:

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | `BACKEND` environment variable | `export BACKEND=gsplat` |
| 2 | `backend` field in YAML config file | `backend: "3dgs-cpp"` |
| 3 (lowest) | Auto-detection based on GPU | CUDA → `gsplat`, Metal → `gaussian-splatting`, None → `mock` |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `BACKEND` | Backend name to use | `gaussian-splatting` |
| `PLUGIN_PATH` | Additional plugin search directory | (none) |
| `FORCE_CPU_BACKEND` | If set, auto-detection selects `mock` | (unset) |
| `COLMAP_USE_CPU` | If set, forces COLMAP to CPU-only mode (no GPU/OpenGL) | (unset) |

### Auto-Detection

When no backend is explicitly configured (or `backend: "auto"` in YAML), the system detects available GPU hardware:

| GPU Detected | Selected Backend |
|-------------|-----------------|
| NVIDIA/CUDA | `gsplat` |
| Apple Metal | `gaussian-splatting` |
| AMD ROCm | `gaussian-splatting` |
| None | `mock` (with warning) |

---

## Safety and Limitations

### Dynamic Loading Is Unsafe

Plugin loading uses `unsafe` blocks in three places:

1. **`Library::new()`** — Loading the shared library may execute initialization code (`__attribute__((constructor))` in C, or Rust `#[ctor]`).
2. **`library.get(b"create_backend")`** — Symbol resolution trusts that the symbol has the correct type signature.
3. **`create_backend()`** — Calling the constructor executes arbitrary plugin code.

**Mitigation:** Only load plugins from trusted sources. Restrict write access to plugin directories.

### ABI Stability

This is the most significant limitation. The plugin interface uses `Box<dyn GaussianSplatBackend>`, which is a Rust trait object (fat pointer = data ptr + vtable ptr). The layout of this type is **not guaranteed to be stable across Rust compiler versions**.

**Consequences:**
- Plugin and host **must** be compiled with the **same `rustc` version**
- Plugin and host **must** use the **same versions** of shared dependencies (`anyhow`, `async-trait`, `serde`, etc.)
- Upgrading the host binary may require recompiling all plugins

**Why not a C FFI?** A pure C-ABI interface would be more stable but would lose Rust's type safety and async trait ergonomics. The current approach prioritizes developer experience over cross-version compatibility.

### Library Lifetime

Loaded libraries are stored in `PluginLoader.libraries: Vec<Library>` to prevent the OS from unloading them. If a library were unloaded while a backend trait object still existed, calling methods on that object would segfault.

### No Sandboxing

Plugins run in the same process as the host with full access to memory, filesystem, and network. There is no capability restriction or isolation.

### Thread Safety

Backends are wrapped in `Arc<dyn GaussianSplatBackend>` and must be `Send + Sync`. Ensure your implementation is safe for concurrent use (or uses interior mutability with `Mutex`/`RwLock` if needed).

---

## Troubleshooting

### Plugin Not Found

```
Error: Backend plugin 'my-backend' not found. Searched for 'libmy-backend_backend.so' in: ["./plugins/"]
```

**Checklist:**
- Verify the file exists: `ls -la plugins/libmy-backend_backend.so`
- Check the naming pattern matches: `lib{name}_backend.{ext}`
- Check `PLUGIN_PATH` if using a custom directory: `echo $PLUGIN_PATH`
- Ensure the search directory exists (non-existent dirs are silently skipped)

### Symbol Not Found

```
Error: Plugin './plugins/libmy-backend_backend.so' does not export 'create_backend' function
```

**Checklist:**
- Verify `#[no_mangle]` is on the function
- Verify `pub extern "C" fn create_backend()` signature
- Inspect symbols: `nm -D plugins/libmy-backend_backend.so | grep create_backend`
- Ensure `crate-type = ["cdylib"]` in `Cargo.toml`

### ABI Mismatch / Segfault

```
Segmentation fault (core dumped)
```

This typically happens when calling `train()`, `export_ply()`, or `export_splat()` on a plugin loaded from a library compiled with a different Rust version.

**Checklist:**
- Verify both host and plugin use the same `rustc`: `rustc --version`
- Verify matching dependency versions in `Cargo.lock`
- Rebuild the plugin with the same toolchain as the host

### Library Loading Errors

```
Error: Failed to load plugin library: ./plugins/libmy-backend_backend.so
```

**Checklist:**
- Check shared library dependencies: `ldd plugins/libmy-backend_backend.so` (Linux) or `otool -L` (macOS)
- Ensure all linked libraries are available at runtime
- Check file permissions: `chmod 755 plugins/libmy-backend_backend.so`

### Plugin Works Locally but Not in Docker

- Ensure the plugin is built for the correct architecture (the container's `linux/amd64` or `linux/arm64`)
- Mount the plugins directory or copy `.so` files into the container image
- Verify libc compatibility (musl vs. glibc) if using Alpine-based images

---

## Reference: Source Files

| File | Description |
|------|-------------|
| `src/backends/mod.rs` | `GaussianSplatBackend` trait definition |
| `src/backends/models.rs` | `BackendOutput`, `BackendMetadata` types |
| `src/backends/plugin_loader.rs` | Dynamic library discovery and loading |
| `src/backends/registry.rs` | Backend registration, selection, and caching |
| `src/backends/gaussian_splatting.rs` | Built-in reference backend |
| `src/backends/gsplat.rs` | Built-in gsplat (Python/CUDA) backend |
| `src/backends/three_dgs_cpp.rs` | Built-in C++ backend |
| `src/backends/mock.rs` | Testing/mock backend |
| `src/backends/gpu_detect.rs` | GPU detection for auto-selection |
| `src/config/yaml.rs` | `TrainingConfig` struct definition |
| `plugins/README.md` | Operational plugin usage guide |
