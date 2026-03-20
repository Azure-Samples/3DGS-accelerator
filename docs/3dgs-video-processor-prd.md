# Product Requirements Document

## 3DGS Video-to-Gaussian Splatting Container

**Version:** 1.0  
**Date:** 2026-02-11  
**Status:** Draft

---

## 1. Executive Summary

A containerized Rust application that watches a mounted directory for uploaded video folders, extracts frames, processes them through a 3D Gaussian Splatting (3DGS) pipeline, and outputs `.ply` and `.splat` files. The container supports both local filesystem mounts and Azure Blob Storage via Blobfuse2.

---

## 2. Problem Statement

Users need an automated, containerized solution to convert video captures of real-world scenes into 3D Gaussian Splatting representations. The solution must work seamlessly across edge compute devices and Azure Container Instances, handling files from local storage or Azure Blob Storage without code changes.

---

## 3. Goals & Non-Goals

### Goals

- Watch a mounted directory and automatically process new video uploads
- Extract frames from multiple independent video files
- Extract necessary metadata from the video files, camera positioning, timestamps, etc. to create a manifest file to use with extracted frames
- Generate combined 3DGS output in both `.ply` and `.splat` formats
- Support swappable 3DGS processing backends
- Work identically with local mounts and Azure Blob Storage (via Blobfuse2)
- Run on both x86_64 and arm64 architectures

### Non-Goals (MVP)

- Real-time streaming video processing
- Advanced resource management / adaptive processing
- Separate microservice containers for each pipeline stage
- Web UI or REST API interface

---

## 4. Target Users

**External customers** using the product to generate 3DGS assets from video captures.

---

## 5. Functional Requirements

### 5.1 Input Handling

| Requirement | Details |
|-------------|---------|
| Input source | Multiple video files (independent captures of the same scene) |
| Supported formats | Common video formats (MP4, MOV, AVI, MKV, WebM) |
| Frame extraction | Container handles extraction from videos |
| Frame selection | User-specified frame count or rate |
| Input validation | Basic validation: file integrity, minimum resolution, sufficient frames |
| Metadata extraction | Extract and generate manifest file (see 5.1.1 below) |

#### 5.1.1 Metadata Extraction & Manifest Generation

For each video file, extract the following metadata to create a manifest file for COLMAP processing:

| Metadata Field | Source | Required | Notes |
|----------------|--------|----------|-------|
| Video filename | File system | Yes | Original video file name |
| Frame count | FFmpeg | Yes | Total frames extracted from this video |
| Frame resolution | FFmpeg | Yes | Width x Height (e.g., 1920x1080) |
| Frame rate (original) | FFmpeg | Yes | FPS of source video |
| Duration | FFmpeg | Yes | Video length in seconds |
| Recording timestamp | Video metadata/EXIF | If available | UTC timestamp of video recording |
| Camera model | Video metadata/EXIF | If available | Device/camera identifier |
| GPS coordinates | Video metadata/EXIF | If available | Latitude/Longitude per frame or video |
| Orientation | Video metadata/EXIF | If available | Device orientation (landscape/portrait/rotation) |

**Manifest File Format:** JSON

**Output Location:** Same directory as extracted frames

**Example manifest.json:**

```json
{
  "job_id": "job-001",
  "processing_timestamp": "2026-02-11T20:30:00Z",
  "videos": [
    {
      "filename": "video1.mp4",
      "frame_count": 120,
      "resolution": "1920x1080",
      "fps": 30.0,
      "duration_secs": 4.0,
      "recording_timestamp": "2026-02-11T18:15:23Z",
      "camera_model": "iPhone 15 Pro",
      "frames": [
        {
          "frame_number": 0,
          "timestamp_offset": 0.0,
          "filename": "video1_frame_0000.jpg"
        }
      ]
    }
  ],
  "camera_intrinsics": {
    "model": "OPENCV",
    "fx": 1000.0,
    "fy": 1000.0,
    "cx": 960.0,
    "cy": 540.0,
    "k1": 0.0,
    "k2": 0.0,
    "p1": 0.0,
    "p2": 0.0
  }
}
```

**Camera Intrinsics Strategy:**

- If EXIF metadata contains focal length: compute intrinsics from sensor size and focal length
- If unavailable: use COLMAP auto-calibration (camera model set to OPENCV)
- Users can override via optional `camera_intrinsics.yaml` file in input folder

### 5.2 Watch Mode Operation

| Requirement | Details |
|-------------|---------|
| Execution model | Long-running watch mode (not batch) |
| Watch mechanism | Hybrid: inotify for local, polling fallback for network/blobfuse mounts |
| Upload completion detection | File stability timeout (no new files for N seconds) |
| Stability timeout config | Environment variable: `UPLOAD_STABILITY_TIMEOUT_SECS` |
| Concurrent jobs | Queue new folders, process sequentially |

### 5.3 Processing Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                        WATCH LOOP                                │
├─────────────────────────────────────────────────────────────────┤
│  1. Detect new folder                                           │
│  2. Wait for upload stability (no new files for N seconds)      │
│  3. Validate input videos                                       │
│  4. Extract frames from all videos                              │
│  5. Run COLMAP (Structure-from-Motion)                          │
│  6. Train 3DGS model (swappable backend)                        │
│  7. Export .ply and .splat files                                │
│  8. Move input to 'processed' or 'error' folder                 │
│  9. Return to watching                                          │
└─────────────────────────────────────────────────────────────────┘
```

### 5.4 3DGS Processing Engine

| Requirement | Details |
|-------------|---------|
| Architecture | Modular/swappable backends |
| Initial backends | gaussian-splatting (reference), gsplat, 3DGS.cpp |
| Backend selection | Configurable via YAML config |
| GPU support | Optional (CPU fallback acceptable) |
| Parameters | Full control via YAML config file |

### 5.5 Output

| Requirement | Details |
|-------------|---------|
| Output formats | `.ply` (standard) and `.splat` (web-optimized) |
| Output structure | Single combined 3DGS from all input videos |
| Filename format | `YYYY-MM-DD_HH-MM-SS.ply`, `YYYY-MM-DD_HH-MM-SS.splat` |
| Timestamp | UTC |
| Intermediate artifacts | Not preserved (only final outputs saved) |

### 5.6 Post-Processing Handling

| Scenario | Behavior |
|----------|----------|
| Success | Move input folder to `processed/` directory |
| Failure | Retry N times (configurable), then move to `error/` directory |
| Partial failure | Fail entire job (no partial processing) |

---

## 6. Storage Requirements

### 6.1 Local Mode

| Requirement | Details |
|-------------|---------|
| Path configuration | Environment variables |
| Input path | `INPUT_PATH` - directory to watch for new folders |
| Output path | `OUTPUT_PATH` - directory for 3DGS output files |
| Processed path | `PROCESSED_PATH` - directory for successfully processed inputs |
| Error path | `ERROR_PATH` - directory for failed inputs |

### 6.2 Azure Blob Storage Mode

| Requirement | Details |
|-------------|---------|
| Integration method | Blobfuse2 (mounts blob as filesystem) |
| Mounting responsibility | Container handles blobfuse2 mounting |
| Container privileges | Requires privileged mode for FUSE mount |
| Authentication methods | Connection string, SAS token, Managed Identity (all supported) |

### 6.3 Azure Authentication Environment Variables

```bash
# Option 1: Connection string
AZURE_STORAGE_CONNECTION_STRING=...

# Option 2: SAS token
AZURE_STORAGE_ACCOUNT=...
AZURE_STORAGE_SAS_TOKEN=...

# Option 3: Managed Identity (auto-detected in Azure)
AZURE_STORAGE_ACCOUNT=...
AZURE_USE_MANAGED_IDENTITY=true
```

---

## 7. Configuration

### 7.1 Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `INPUT_PATH` | Yes | - | Path to watch for input folders |
| `OUTPUT_PATH` | Yes | - | Path for output 3DGS files |
| `PROCESSED_PATH` | Yes | - | Path for successfully processed inputs |
| `ERROR_PATH` | Yes | - | Path for failed inputs |
| `TEMP_PATH` | No | `/tmp/3dgs-work` | Working directory for intermediate processing |
| `CONFIG_PATH` | No | `/config/config.yaml` | Path to YAML config file |
| `UPLOAD_STABILITY_TIMEOUT_SECS` | No | `60` | Seconds of no file changes before processing |
| `MAX_RETRIES` | No | `3` | Retry count before moving to error folder |
| `POLL_INTERVAL_SECS` | No | `10` | Polling interval for network mounts |
| `FRAME_RATE` | No | `1` | Frames to extract per second of video |
| `FRAME_COUNT` | No | - | Total frames per video (overrides FRAME_RATE) |
| `BACKEND` | No | `gaussian-splatting` | 3DGS backend to use |
| `LOG_LEVEL` | No | `info` | Logging verbosity |
| `RETENTION_DAYS` | No | `30` | Days to retain processed and error folders |
| `AZURE_STORAGE_CONNECTION_STRING` | No | - | Azure Storage connection string (Option 1) |
| `AZURE_STORAGE_ACCOUNT` | No | - | Azure Storage account name (Options 2 & 3) |
| `AZURE_STORAGE_SAS_TOKEN` | No | - | Azure SAS token (Option 2) |
| `AZURE_USE_MANAGED_IDENTITY` | No | `false` | Use Managed Identity for auth (Option 3) |
| `AZURE_BLOB_CONTAINER_INPUT` | No | - | Azure Blob container name for input |
| `AZURE_BLOB_CONTAINER_OUTPUT` | No | - | Azure Blob container name for output |
| `AZURE_BLOB_CONTAINER_PROCESSED` | No | - | Azure Blob container name for processed |
| `AZURE_BLOB_CONTAINER_ERROR` | No | - | Azure Blob container name for errors |

### 7.2 YAML Configuration File

```yaml
# config.yaml - Advanced 3DGS parameters

backend: gaussian-splatting  # gaussian-splatting | gsplat | 3dgs-cpp

frame_extraction:
  rate: 1                    # Frames per second (if frame_count not set)
  count: null                # Total frames per video (overrides rate)
  
colmap:
  matcher: exhaustive        # exhaustive | sequential | vocab_tree
  camera_model: OPENCV       # SIMPLE_PINHOLE | OPENCV | FULL_OPENCV

training:
  iterations: 30000
  learning_rate: 0.0025
  densification_interval: 100
  densification_start: 500
  densification_stop: 15000
  opacity_reset_interval: 3000
  
export:
  formats:
    - ply
    - splat
  ply_precision: float32     # float32 | float16
```

---

## 8. Technical Requirements

### 8.1 Container Specification

| Requirement | Details |
|-------------|---------|
| Base language | Rust |
| Container format | OCI-compliant |
| Architectures | Multi-arch: x86_64 (amd64) and arm64 |
| GPU support | Optional (CUDA when available, CPU fallback) |
| Privileged mode | Required (for blobfuse2 FUSE mounting) |

### 8.2 Container Contents

- Rust application binary
- FFmpeg (video frame extraction)
- COLMAP (Structure-from-Motion)
- 3DGS backends (gaussian-splatting, gsplat, 3DGS.cpp)
- Blobfuse2 (Azure Blob mounting)

### 8.3 Deployment Targets

| Target | Notes |
|--------|-------|
| Edge compute devices | Local filesystem, limited resources possible |
| Azure Container Instances (ACI) | Blobfuse2 for storage, GPU optional |

---

## 9. Logging & Monitoring

| Requirement | Details |
|-------------|---------|
| Output | Console/stdout only |
| Format | Plain text with timestamps |
| Levels | Error, Warn, Info, Debug, Trace |
| Progress reporting | Per-stage progress (extraction, COLMAP, training, export) |
| Job status | Log entry on job start, completion, and failure |

---

## 10. Error Handling

| Scenario | Behavior |
|----------|----------|
| Invalid video file | Fail validation, move to error folder |
| COLMAP failure | Retry up to MAX_RETRIES, then error folder |
| Training failure | Retry up to MAX_RETRIES, then error folder |
| Storage full | Log error, pause processing until space available |
| Azure auth failure | Log error, retry with backoff |
| Files added during processing | Stop current job, restart processing from beginning |
| Network interruption (Azure Blob) | Execute standard cloud retry/backoff logic, continue operation |
| Partial uploads | Detected by stability timeout, not processed |
| Container restart mid-job | Restart app and reprocess folders |
| Duplicate job submissions | Skip folders already in processed/ or error/ |

---

## 11. Data Management Requirements

### 11.1 Temporary File Management

| Requirement | Details |
|-------------|--------|
| Cleanup policy | Always clean up temporary files after job completion (success or failure) |
| Temp directory | Defined by `TEMP_PATH` environment variable (default: `/tmp/3dgs-work`) |
| Cleanup timing | Immediate cleanup after job moves to processed/ or error/ |
| Cleanup scope | All intermediate artifacts: extracted frames, COLMAP outputs, training checkpoints |
| Disk space monitoring | Check available space before starting new job |

### 11.2 Processed and Error Folder Retention

| Requirement | Details |
|-------------|--------|
| Retention period | 30 days for both processed/ and error/ folders |
| Retention enforcement | Automatic cleanup of folders older than 30 days |
| Cleanup schedule | Daily check at midnight UTC |
| Retention configuration | Environment variable: `RETENTION_DAYS` (default: 30) |
| Cleanup logging | Log each folder deletion with timestamp and folder name |

### 11.3 Storage Thresholds

| Requirement | Details |
|-------------|--------|
| Minimum free space | Require 10GB free before starting new job |
| Space check timing | Before job start, before COLMAP, before training |
| Insufficient space behavior | Pause processing, log warning, resume when space available |

---

## 12. Operational Requirements

### 12.1 Process Lifecycle Management

| Requirement | Details |
|-------------|--------|
| Graceful shutdown | Handle SIGTERM correctly, complete current stage before exit |
| Shutdown timeout | Maximum 5 minutes to complete graceful shutdown |
| Forced shutdown | SIGKILL after shutdown timeout expires |
| Job interruption | On SIGTERM during processing, save progress state and exit cleanly |
| Cleanup on exit | Always clean up temp files before shutdown |

### 12.2 Metrics and Observability

| Requirement | Details |
|-------------|--------|
| Output destination | Console logs (stdout) |
| Metrics format | Structured log entries with key-value pairs |
| Processing metrics | Time per stage, total job time, frame count, output file sizes |
| System metrics | Disk usage, memory usage, CPU usage (if available) |
| Metric frequency | Log on stage completion and job completion |

#### Metric Log Format Example

```
[2026-02-11T20:15:00Z] INFO job_started job_id=job-001 videos=3
[2026-02-11T20:15:30Z] INFO frame_extraction_complete job_id=job-001 duration_secs=30 total_frames=360
[2026-02-11T20:18:45Z] INFO colmap_complete job_id=job-001 duration_secs=195 points=125430
[2026-02-11T20:45:12Z] INFO training_complete job_id=job-001 duration_secs=1587 iterations=30000
[2026-02-11T20:45:45Z] INFO export_complete job_id=job-001 duration_secs=33 ply_size_mb=45.2 splat_size_mb=38.7
[2026-02-11T20:45:45Z] INFO job_complete job_id=job-001 total_duration_secs=1845 status=success
```

### 12.3 Health Monitoring

| Requirement | Details |
|-------------|--------|
| Health endpoint | Optional HTTP endpoint at `/health` (disabled by default) |
| Health check content | JSON status: watching, processing, idle, error |
| Liveness indicator | Process responds to signals and logs activity |
| Readiness indicator | Successfully mounted storage and loaded configuration |

---

## 13. Success Criteria

### MVP Acceptance Criteria

#### Functional Requirements

- [ ] Container watches input directory and detects new folders
- [ ] Correctly waits for upload completion via stability timeout
- [ ] Extracts frames from multiple video files
- [ ] Generates combined 3DGS output in `.ply` and `.splat` formats
- [ ] Outputs files with UTC timestamp naming convention
- [ ] Successfully processes inputs from local mounts
- [ ] Successfully processes inputs from Azure Blob Storage via Blobfuse2
- [ ] Moves completed inputs to processed folder
- [ ] Retries failed jobs and moves to error folder after max retries
- [ ] Works on both x86_64 and arm64 architectures
- [ ] Backend is swappable via configuration
- [ ] Handles SIGTERM gracefully and cleans up resources
- [ ] Automatically cleans up temporary files after each job
- [ ] Enforces 30-day retention for processed and error folders

#### Quality Metrics

- [ ] Output PLY file viewable in standard 3DGS viewers (e.g., WebGL viewers, CloudCompare)
- [ ] Output SPLAT file loadable in web-based Gaussian splatting viewers
- [ ] Successful COLMAP reconstruction with >1000 reconstructed points
- [ ] No memory leaks over 24-hour continuous operation

#### Performance Metrics

- [ ] Logs processing metrics including time for each stage
- [ ] Container restart successfully resumes watching and reprocesses incomplete jobs
- [ ] Handles files added during processing by restarting job
- [ ] Recovers from network interruptions during Azure Blob operations

---

## 14. Timeline

**Target:** MVP delivery within 1-3 months

### Suggested Phases

**Phase 1: Core Pipeline**

- [ ] Project scaffolding (Rust, Dockerfile)
- [ ] Frame extraction from videos (FFmpeg integration)
- [ ] COLMAP integration
- [ ] Single 3DGS backend integration (gaussian-splatting)
- [ ] PLY and SPLAT export

**Phase 2: Watch Mode**

- [ ] Filesystem watcher (inotify)
- [ ] Polling fallback for network mounts
- [ ] Upload stability detection
- [ ] Job queue (sequential processing)
- [ ] Post-processing folder management

**Phase 3: Azure Integration**

- [ ] Blobfuse2 mounting in container
- [ ] All authentication methods
- [ ] Testing with Azure Blob Storage

**Phase 4: Multi-arch & Hardening**

- [ ] Multi-arch container build (x86_64 + arm64)
- [ ] Additional 3DGS backends (gsplat, 3DGS.cpp)
- [ ] Input validation
- [ ] Error handling and retry logic

---

## 15. Open Questions

1. **Default stability timeout** - Is 60 seconds a reasonable default for upload completion detection?
2. **Retry count** - Is 3 retries appropriate before moving to error folder?
3. **Video codecs** - Are there specific codecs that must be supported beyond standard FFmpeg defaults?
4. **Maximum job queue size** - Should there be a limit on queued jobs?
5. **Health check endpoint** - Should the container expose a health check for orchestrators? (Optional HTTP endpoint specified in Section 12.3)
6. **Minimum hardware requirements** - What are the minimum CPU, RAM, and GPU specifications?
7. **Performance targets** - What is acceptable processing time for different video sizes/quantities?

### Answered Questions

1. **~~What happens if container restarts mid-job?~~** - **ANSWERED:** Restart app and reprocess folders (see Section 10, Error Handling)

---

## 16. Testing & Quality Assurance

### 14.1 Test Coverage Requirements

| Metric | Target | Notes |
|--------|--------|-------|
| Code coverage | ≥70% | Measured by lines covered |
| Critical path coverage | 100% | All pipeline stages must have tests |
| Unit test execution time | <2 minutes | Fast feedback loop |
| Integration test execution time | <10 minutes | End-to-end scenarios |

### 14.2 Test Categories

#### Unit Tests

- Frame extraction logic
- Configuration parsing
- File system operations
- Metadata extraction
- Watch mode stability detection
- Retry logic
- Error handling

#### Integration Tests

- Full pipeline execution with sample videos
- COLMAP integration
- 3DGS backend integration (at least gaussian-splatting)
- File movement (input → processed/error)
- Configuration file loading

#### End-to-End Tests

- Local filesystem mode with complete job
- Multiple video processing
- Error scenarios (corrupted video, disk full simulation)
- Retry and failure handling

### 14.3 Test Data Requirements

| Test Asset | Description | Size |
|------------|-------------|------|
| Sample video set | 3 short videos of same scene from different angles | ~50MB total |
| Corrupted video | Invalid/truncated video file | <1MB |
| Minimal video | Smallest valid input (resolution, duration) | <5MB |
| Large video set | Performance testing dataset | ~500MB |

### 14.4 Quality Gates

**Before merging code:**

- [ ] All tests pass
- [ ] Code coverage ≥70%
- [ ] No critical security vulnerabilities (cargo audit)
- [ ] Rust clippy lints pass
- [ ] Code formatted with rustfmt

**Before release:**

- [ ] All acceptance criteria met (Section 11)
- [ ] Manual testing on both x86_64 and arm64
- [ ] Docker image builds successfully for both architectures
- [ ] Sample end-to-end test with local storage passes
- [ ] Documentation updated

### 14.5 Local Testing Strategy

For MVP development (before CI/CD):

```bash
# Run all tests with coverage
cargo tarpaulin --out Html --output-dir coverage

# Run clippy
cargo clippy --all-targets --all-features -- -D warnings

# Format check
cargo fmt -- --check

# Security audit
cargo audit

# Build multi-arch images locally
docker buildx build --platform linux/amd64,linux/arm64 -t 3dgs-processor:test .
```

---

## 17. Documentation Deliverables

### 15.1 User Documentation

**README.md** (Repository root)

- Project overview and purpose
- Quick start guide
- Installation instructions
- Basic usage examples
- Link to detailed documentation

**USER_GUIDE.md**

- Detailed setup instructions
- Configuration reference (all environment variables and YAML options)
- Input preparation guidelines
  - Recommended video capture techniques
  - Supported formats and codecs
  - Minimum quality requirements
- Directory structure setup
- Docker deployment examples (local and Azure)
- Expected output format description
- Common workflows and use cases

**TROUBLESHOOTING.md**

- Common error messages and solutions
- Debug mode instructions
- Log interpretation guide
- Performance optimization tips
- FAQ section
  - "Why did my job fail?"
  - "How do I know processing is complete?"
  - "What if frames are blurry?"
  - "How much disk space do I need?"
  - "Can I use videos from different cameras?"

### 15.2 Developer Documentation

**ARCHITECTURE.md**

- System architecture diagram
- Component descriptions
- Pipeline flow diagram
- Module organization
- Key design decisions

**CONTRIBUTING.md**

- Development environment setup
- Code style guidelines
- Testing requirements
- Pull request process
- How to add a new 3DGS backend

**BUILD.md**

- Build instructions for all platforms
- Docker image build process
- Multi-arch build setup
- Dependency management
- Release process

### 15.3 Operational Documentation

**DEPLOYMENT.md**

- Container deployment patterns
- Resource requirements and sizing
- Storage configuration
- Azure Blob Storage setup guide
- Blobfuse2 configuration examples
- Security hardening recommendations

### 15.4 Code Documentation

- **Inline documentation:** All public functions, structs, and modules documented with rustdoc comments
- **Module-level documentation:** Purpose and usage of each module
- **Example code:** Key functions include usage examples

---

## 18. Dependencies & Licensing

### 16.1 Project License

**MIT License**

This project is licensed under the MIT License, providing:

- Commercial use
- Modification rights
- Distribution rights
- Private use

Full license text to be included in `LICENSE` file in repository root.

### 16.2 Third-Party Dependencies

#### Core Rust Dependencies (examples)

| Crate | Purpose | License | Notes |
|-------|---------|---------|-------|
| tokio | Async runtime | MIT | Pin to stable version |
| notify | File system watching | CC0-1.0 | For inotify support |
| serde / serde_yaml | Config parsing | MIT/Apache-2.0 | Standard serialization |
| tracing | Logging | MIT | Structured logging support |
| clap | CLI argument parsing | MIT/Apache-2.0 | If CLI needed |

#### Bundled External Tools

| Tool | Purpose | License | Distribution |
|------|---------|---------|-------------|
| FFmpeg | Frame extraction | LGPL 2.1+ | Dynamically linked |
| COLMAP | Structure-from-Motion | BSD 3-Clause | Bundled binary |
| gaussian-splatting | 3DGS training (reference) | Custom/Academic | Review license before bundling |
| gsplat | 3DGS training | Apache-2.0 | Alternative backend |
| 3DGS.cpp | 3DGS training (C++) | MIT | Alternative backend |
| Blobfuse2 | Azure Blob mounting | MIT | Bundled in container |

### 16.3 License Compliance Requirements

**Before MVP Release:**

- [ ] All dependency licenses reviewed and documented
- [ ] NOTICE file created listing all third-party components
- [ ] LICENSE file added to repository root
- [ ] Verify FFmpeg LGPL compliance (dynamic linking)
- [ ] Verify 3DGS backend licenses allow commercial use
- [ ] Include license files for bundled tools in container image

**Ongoing:**

- [ ] Dependency version pinning in `Cargo.toml`
- [ ] Regular dependency updates for security patches
- [ ] License compatibility check for new dependencies
- [ ] CVE scanning of container images

### 16.4 Security & Updates

| Process | Frequency | Tool |
|---------|-----------|------|
| Rust dependency audit | Weekly | `cargo audit` |
| Container CVE scan | Per build | Docker Scout / Trivy |
| Dependency updates | Monthly | `cargo outdated` |
| Security advisories | As published | GitHub Dependabot (when available) |

**Vulnerability Response:**

- Critical vulnerabilities: Patch within 48 hours
- High severity: Patch within 1 week
- Medium/Low: Include in next regular update

---

## 19. Appendix

### A. Example Usage

```bash
# Local mode
docker run --privileged \
  -e INPUT_PATH=/data/input \
  -e OUTPUT_PATH=/data/output \
  -e PROCESSED_PATH=/data/processed \
  -e ERROR_PATH=/data/error \
  -e UPLOAD_STABILITY_TIMEOUT_SECS=60 \
  -v /local/input:/data/input \
  -v /local/output:/data/output \
  -v /local/processed:/data/processed \
  -v /local/error:/data/error \
  -v /local/config.yaml:/config/config.yaml \
  3dgs-processor:latest

# Azure Blob mode
docker run --privileged \
  -e INPUT_PATH=/data/input \
  -e OUTPUT_PATH=/data/output \
  -e PROCESSED_PATH=/data/processed \
  -e ERROR_PATH=/data/error \
  -e AZURE_STORAGE_CONNECTION_STRING="..." \
  -e AZURE_BLOB_CONTAINER_INPUT=input \
  -e AZURE_BLOB_CONTAINER_OUTPUT=output \
  3dgs-processor:latest
```

### B. Directory Structure (Runtime)

```
/data/
├── input/                    # Watched directory
│   ├── job-001/              # New upload (waiting for stability)
│   │   ├── video1.mp4
│   │   ├── video2.mp4
│   │   └── video3.mp4
│   └── job-002/              # Queued
├── output/                   # 3DGS outputs
│   ├── 2026-02-11_20-03-57.ply
│   └── 2026-02-11_20-03-57.splat
├── processed/                # Successfully processed inputs
│   └── job-000/
└── error/                    # Failed inputs after max retries
```

### C. Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Normal shutdown (SIGTERM received) |
| 1 | Configuration error |
| 2 | Storage mount failure |
| 3 | Unrecoverable runtime error |
