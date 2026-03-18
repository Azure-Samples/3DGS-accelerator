# COLMAP Pipeline: Current Implementation vs. Community Best Practices

> **Context:** This document compares the COLMAP pipeline choices in our 3DGS Video Processor
> against the **official reference implementation** ([graphdeco-inria/gaussian-splatting `convert.py`](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/convert.py))
> and **community best practices** from the [Step-by-step 3DGS Tutorial](https://www.youtube.com/watch?v=EdIuDLicU0c),
> [DEAR18 guide](https://dear18.github.io/articles/1.Run_3DGS_on_Your_Own_Video.html),
> and [COLMAP documentation](https://colmap.github.io/).

---

## 1. Summary of Divergences

| Setting | Our Default | Reference `convert.py` | Community Recommendation | Severity |
|---------|-------------|----------------------|--------------------------|----------|
| Camera model | `OPENCV` | `OPENCV` | PINHOLE/SIMPLE_RADIAL for phones; OPENCV for wide-angle | ⚠️ Medium |
| Matcher | `exhaustive` | `exhaustive` | **Sequential** for video frames | 🔴 High |
| `ImageReader.single_camera` | ❌ Not set | `1` | `1` for single-device video | 🔴 High |
| `SiftExtraction.use_gpu` | ❌ Not set | Configurable (`--no_gpu`) | Yes when GPU available | ⚠️ Medium |
| `SiftMatching.use_gpu` | ❌ Not set | Configurable (`--no_gpu`) | Yes when GPU available | ⚠️ Medium |
| `estimate_affine_shape` | ❌ Not set | Not set | ✅ Enable for better descriptors | ⚠️ Medium |
| `domain_size_pooling` | ❌ Not set | Not set | ✅ Enable for better descriptors | ⚠️ Medium |
| `cross_check` | ❌ Not set | Not set | ✅ Enable for accurate matches | ⚠️ Medium |
| `guided_matching` | ❌ Not set | Not set | ✅ Enable for accurate matches | ⚠️ Medium |
| Mapper BA tolerance | ❌ Not set | `0.000001` | Increase BA iterations | 🔴 High |
| Image undistortion | ❌ **Missing** | ✅ `image_undistorter` | Required for quality output | 🔴 Critical |
| Frame rate (from video) | 1 FPS | N/A (expects images) | 10 FPS from 30 FPS source | ⚠️ Medium |

---

## 2. Detailed Analysis

### 2.1 Camera Model — `OPENCV` vs. `RADIAL` / `PINHOLE`

**Current choice:** `OPENCV` (default in `config.example.yaml` and `src/config/yaml.rs:139`)

**Reference `convert.py`:** Also defaults to `OPENCV`, but documents `PINHOLE` as an alternative.

**Community recommendation:** Depends on the lens type:

| Source | Camera Model | Best For |
|--------|-------------|----------|
| Smartphone / DSLR | `PINHOLE` or `SIMPLE_RADIAL` | Minimal distortion lenses |
| Wide-angle / GoPro / Drone | `OPENCV` or `OPENCV_FISHEYE` | Strong radial + tangential distortion |
| Unknown / Mixed | `OPENCV` | Safe default |

**Assessment:** Our `OPENCV` default is **correct as a safe choice** for a general-purpose service where input cameras are unknown. However, using `OPENCV` for smartphone video adds unnecessary parameters (tangential distortion coefficients) that can overfit with limited data, potentially degrading reconstruction quality.

**Suggestion:**
- Make `camera_model` configurable per-job (already partially supported via YAML).
- Consider adding `SIMPLE_RADIAL` as an option — it provides radial distortion correction without the overhead of tangential coefficients.
- Add documentation that `PINHOLE` is best for pre-undistorted images.
- The reference implementation runs `image_undistorter` *after* reconstruction to convert everything to ideal pinhole intrinsics — this step is **missing** from our pipeline (see §2.8).

---

### 2.2 Feature Matching — Exhaustive vs. Sequential

**Current choice:** `exhaustive` (default in `config.example.yaml` and `src/config/yaml.rs:135`)

**Reference `convert.py`:** Also uses `exhaustive_matcher`.

**Community recommendation:** **Sequential matching for video-sourced frames.**

This is the **single most impactful divergence**. Our service is specifically designed to process **video input** (extracted frames with temporal ordering). The DEAR18 guide explicitly states:

> *"Select the sequential matching mode for images captured from a video, as this speeds up the matching process."*

| Matcher | Complexity | Use Case | Time (500 images) |
|---------|-----------|----------|-------------------|
| Exhaustive | O(n²) | Unordered photo collections | ~Hours |
| Sequential | O(n·k) | Temporally ordered video frames | ~Minutes |
| Vocab Tree | O(n·log n) | Very large datasets (10k+ images) | Moderate |

For a service processing video frames (our primary use case), exhaustive matching is **needlessly slow**. With 500 frames, exhaustive attempts ~125,000 pair matches; sequential with overlap=10 attempts ~5,000.

**Suggestion:**
- **Change the default to `sequential`** for video-sourced input.
- Add `--SequentialMatching.overlap` parameter (default: 10) to control the matching window.
- Keep `exhaustive` available for unordered photo collections (if ever supported).
- Add `--SequentialMatching.loop_detection` for scenes where the camera returns to previously visited positions.

---

### 2.3 `ImageReader.single_camera` — Missing Critical Flag

**Current choice:** ❌ Not set

**Reference `convert.py`:** `--ImageReader.single_camera 1`

**Impact:** When this flag is missing, COLMAP estimates **independent intrinsic parameters for every image**. For video frames from a single device (our primary input), this is wasteful and can produce inconsistent calibrations across frames.

Setting `single_camera=1` forces COLMAP to share a single set of intrinsic parameters across all images, which:
- Dramatically improves calibration stability
- Reduces the number of unknowns in bundle adjustment
- Produces more consistent camera poses

**Suggestion:** Set `--ImageReader.single_camera 1` by default. Consider making it configurable for multi-camera setups.

---

### 2.4 GPU Acceleration — `SiftExtraction.use_gpu` / `SiftMatching.use_gpu`

**Current choice:** ✅ Implemented — GPU enabled by default, controllable via `COLMAP_USE_CPU` env var.

**Reference `convert.py`:** Passes `--SiftExtraction.use_gpu` and `--SiftMatching.use_gpu` based on `--no_gpu` flag.

**Impact:** COLMAP's GPU-accelerated SIFT extraction is **5–10× faster** than CPU. Since our service already requires GPU for training, we leverage it for COLMAP steps too.

**Implementation:** `--SiftExtraction.use_gpu 1` and `--SiftMatching.use_gpu 1` are passed by default. Set `COLMAP_USE_CPU=1` to disable GPU for COLMAP (useful for headless servers or when GPU should be reserved for training). This is independent of `FORCE_CPU_BACKEND`, which only affects the 3DGS training backend.

---

### 2.5 Feature Descriptor Quality — `estimate_affine_shape` and `domain_size_pooling`

**Current choice:** ❌ Not set

**Reference `convert.py`:** Not set.

**Community recommendation (DEAR18):** Enable both for better feature descriptors.

> *"In feature extraction stage, enabling estimate_affine_shape and domain_size_pooling helps to generate better feature descriptors."*

These options make SIFT descriptors more robust to viewpoint changes and scale variations. The cost is ~20-30% more time during feature extraction, but it produces better matches and ultimately better reconstructions.

**Suggestion:** Enable via:
```
--SiftExtraction.estimate_affine_shape 1
--SiftExtraction.domain_size_pooling 1
```
Add as optional flags in `ColmapConfig`, defaulting to `true`.

---

### 2.6 Matching Quality — `cross_check` and `guided_matching`

**Current choice:** ❌ Not set

**Reference `convert.py`:** Not set.

**Community recommendation (DEAR18):** Enable both.

> *"Enable cross_check and guided_matching to ensure more accurate feature matching."*

- **`cross_check`** verifies matches in both directions (A→B and B→A must agree). Reduces false matches.
- **`guided_matching`** uses estimated geometry to refine matches. Improves accuracy after initial matching.

**Suggestion:** Enable via `--SiftMatching.cross_check 1` and `--SiftMatching.guided_matching 1`. The computational overhead is modest compared to the quality improvement.

---

### 2.7 Mapper Bundle Adjustment Tolerance

**Current choice:** ❌ Not set (uses COLMAP default)

**Reference `convert.py`:** `--Mapper.ba_global_function_tolerance=0.000001`

The reference implementation tightens the bundle adjustment convergence tolerance from COLMAP's default. This makes bundle adjustment converge faster (fewer iterations needed) while still producing accurate results. The comment in `convert.py` explains:

> *"The default Mapper tolerance is unnecessarily large, decreasing it speeds up bundle adjustment steps."*

**Suggestion:** Add `--Mapper.ba_global_function_tolerance=0.000001` to the mapper invocation.

---

### 2.8 Image Undistortion Step — CRITICAL MISSING STAGE

**Current choice:** ❌ **Not implemented**

**Reference `convert.py`:** Runs `colmap image_undistorter` after sparse reconstruction.

This is the **most critical gap**. The reference pipeline:
1. Runs feature extraction + matching + mapper in a `distorted/` subdirectory
2. Runs `image_undistorter` to produce undistorted images with ideal pinhole intrinsics
3. Passes undistorted images + updated poses to 3DGS training

Without this step:
- **Images with lens distortion are fed directly to the 3DGS trainer**, causing visible artifacts (bent lines, blurry edges)
- The camera model mismatch (OPENCV intrinsics with distortion vs. what the renderer expects) degrades rendering quality
- This is especially problematic with the `OPENCV` camera model which encodes distortion that needs to be removed

**Suggestion:**
Add a new pipeline stage between COLMAP sparse reconstruction and 3DGS training:

```rust
// In ColmapRunner
pub async fn undistort_images(
    &self,
    image_dir: &Path,
    sparse_input_dir: &Path,   // distorted/sparse/0
    output_dir: &Path,
) -> Result<()> {
    // colmap image_undistorter \
    //   --image_path INPUT/input \
    //   --input_path INPUT/distorted/sparse/0 \
    //   --output_path OUTPUT \
    //   --output_type COLMAP
}
```

Mirror the `convert.py` directory structure: work in `distorted/` during SfM, then undistort to the final output directory.

---

### 2.9 Frame Extraction Rate

**Current choice:** 1 FPS (default in `config.example.yaml`)

**Community recommendation:** ~10 FPS from 30 FPS source (DEAR18), or 2-5 FPS depending on scene complexity.

1 FPS may be too sparse for reliable COLMAP reconstruction, especially for fast-moving cameras. At 1 FPS from a 30 FPS video, there's a 30× gap between frames, which can break feature matching continuity.

**Suggestion:**
- Increase default to `2.0` FPS as a safer minimum.
- Add guidance in documentation: "For walking-speed capture, 2 FPS is sufficient. For fast motion or handheld, use 5-10 FPS."
- Consider adaptive frame extraction based on scene motion (advanced feature).

---

## 3. Recommended Code Changes

### Priority 1 — Critical (Affects output quality)

| Change | File(s) | Effort |
|--------|---------|--------|
| Add `image_undistorter` step | `src/colmap/runner.rs`, `src/colmap/mod.rs` | Medium |
| Add `--ImageReader.single_camera 1` | `src/colmap/runner.rs:51-58` | Trivial |
| Add `--Mapper.ba_global_function_tolerance=0.000001` | `src/colmap/runner.rs:164-172` | Trivial |
| Change default matcher to `sequential` | `src/config/yaml.rs:135` | Trivial |

### Priority 2 — Performance

| Change | File(s) | Effort |
|--------|---------|--------|
| ~~Add `--SiftExtraction.use_gpu` / `--SiftMatching.use_gpu`~~ | `src/colmap/runner.rs` | ✅ Done — controlled via `COLMAP_USE_CPU` env var |
| Add `--SequentialMatching.overlap` parameter | `src/colmap/runner.rs`, `src/config/yaml.rs` | Small |

### Priority 3 — Quality Improvements

| Change | File(s) | Effort |
|--------|---------|--------|
| Add `estimate_affine_shape` + `domain_size_pooling` | `src/colmap/runner.rs` | Small |
| Add `cross_check` + `guided_matching` | `src/colmap/runner.rs` | Small |
| Add `SIMPLE_RADIAL` camera model option | `src/config/yaml.rs`, docs | Trivial |
| Increase default frame rate to 2.0 FPS | `src/config/yaml.rs:131` | Trivial |

---

## 4. Proposed `config.example.yaml` COLMAP Section

```yaml
colmap:
  # Feature matching strategy
  # sequential: Recommended for video input (faster, assumes temporal order)
  # exhaustive: For unordered photo collections (slowest, most robust)
  # vocab_tree: For large datasets (10k+ images, requires vocabulary file)
  matcher: sequential

  # Sequential matching window (images before/after to match against)
  sequential_overlap: 10

  # Camera model for feature extraction
  # OPENCV: Safe default, handles radial + tangential distortion
  # SIMPLE_RADIAL: Better for smartphones with mild distortion
  # PINHOLE: For pre-undistorted images only
  camera_model: OPENCV

  # Assume all images from a single camera (shared intrinsics)
  # Set to false for multi-camera setups
  single_camera: true

  # GPU acceleration for SIFT extraction and matching
  use_gpu: true

  # Enhanced feature descriptors (slower extraction, better quality)
  estimate_affine_shape: true
  domain_size_pooling: true

  # Enhanced matching accuracy
  cross_check: true
  guided_matching: true

  # Bundle adjustment convergence tolerance (lower = tighter)
  ba_global_function_tolerance: 0.000001
```

---

## 5. Proposed `run_colmap` Pipeline Update

```
Current:
  ① Feature Extraction → ② Feature Matching → ③ Mapper → ④ Parse Output

Proposed:
  ① Feature Extraction → ② Feature Matching → ③ Mapper → ④ Image Undistortion → ⑤ Parse Output
     (in distorted/)        (in distorted/)       (in distorted/)    (to clean output)
```

The directory structure should mirror `convert.py`:
```
temp_dir/
├── distorted/
│   ├── database.db       ← COLMAP database (feature extraction + matching)
│   └── sparse/
│       └── 0/            ← Raw sparse reconstruction (with distortion)
├── images/               ← Undistorted images (output of image_undistorter)
└── sparse/
    └── 0/                ← Undistorted sparse model (final output)
```

---

## 6. References

| Source | Key Takeaway |
|--------|-------------|
| [graphdeco-inria `convert.py`](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/convert.py) | OPENCV default, exhaustive matcher, single_camera=1, undistortion step, BA tolerance |
| [Step-by-step 3DGS Tutorial (YouTube)](https://www.youtube.com/watch?v=EdIuDLicU0c) | Recommended by official repo; practical walkthrough of COLMAP + training pipeline |
| [DEAR18: Run 3DGS on Your Own Video](https://dear18.github.io/articles/1.Run_3DGS_on_Your_Own_Video.html) | Sequential matching for video, affine_shape, domain_size_pooling, cross_check, guided_matching |
| [COLMAP Documentation](https://colmap.github.io/tutorial.html) | Camera model descriptions, matcher details, parameter reference |
| [Reshot.ai 3DGS Tutorial](https://www.reshot.ai/3d-gaussian-splatting) | SIMPLE_RADIAL for smartphones, OPENCV for wide-angle |
| [3DGS Hands-on Course](https://learngeodata.eu/3d-gaussian-splatting-hands-on-course-for-beginners/) | Sequential matcher for continuous imagery |
