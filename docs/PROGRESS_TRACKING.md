# Progress Tracking and Checkpointing

The 3DGS video processor includes comprehensive progress tracking and checkpointing capabilities that enable:

- **Real-time progress monitoring** via health endpoint
- **Automatic checkpoint persistence** for restart resilience
- **Resume from checkpoint** after failures or restarts
- **Detailed stage tracking** through the processing pipeline

## Table of Contents

- [Overview](#overview)
- [Processing Stages](#processing-stages)
- [Checkpoint Storage](#checkpoint-storage)
- [Health Endpoint Integration](#health-endpoint-integration)
- [Resume Capability](#resume-capability)
- [Usage Examples](#usage-examples)
- [Configuration](#configuration)

## Overview

The progress tracking system monitors job execution through 8 distinct stages, saving checkpoint data to disk after each stage completes. This provides:

1. **Visibility**: Track progress percentage and current stage
2. **Resilience**: Resume jobs after process restarts
3. **Monitoring**: Query job status via HTTP health endpoint
4. **Debugging**: Inspect saved checkpoints for troubleshooting

## Processing Stages

Jobs progress through the following stages:

| Stage | Name | Description | Progress % |
|-------|------|-------------|------------|
| 0 | Validation | Folder validation and video discovery | 0% |
| 1 | FrameExtraction | Extract frames from all videos concurrently | 12.5% |
| 2 | MetadataExtraction | Extract GPS and camera metadata | 25% |
| 3 | ManifestGeneration | Generate manifest.json with camera intrinsics | 37.5% |
| 4 | ColmapReconstruction | Run COLMAP sparse reconstruction | 50% |
| 5 | Training | Train 3DGS model | 62.5% |
| 6 | PlyExport | Export model to PLY format | 75% |
| 7 | SplatExport | Export model to SPLAT format | 87.5% |
| 8 | Completed | Job finished successfully | 100% |

Progress percentage is calculated as: `(stage_number / 8) * 100`

## Checkpoint Storage

### File Location

Checkpoints are stored in the output directory as:

```
{output_folder}/.checkpoint.json
```

For example:

```
/mnt/output/job-abc123/.checkpoint.json
```

### Checkpoint Format

Checkpoints are JSON files containing:

```json
{
  "job_id": "job-abc123",
  "stage": "Training",
  "input_folder": "/mnt/input/scene-001",
  "output_folder": "/mnt/output/job-abc123",
  "temp_folder": "/tmp/job-abc123",
  "timestamp": 1708790400,
  "completed_stages": {
    "video_count": 3,
    "total_frames": 450,
    "manifest_path": "/mnt/output/job-abc123/manifest.json",
    "colmap_sparse_path": "/tmp/job-abc123/colmap/sparse",
    "colmap_points": 125000,
    "gaussian_count": null,
    "ply_path": null,
    "splat_path": null
  }
}
```

### Checkpoint Lifecycle

1. **Created**: When job starts (Validation stage)
2. **Updated**: After each stage completes
3. **Finalized**: When job completes successfully (marked as Completed)
4. **Retained**: Kept for status queries (cleaned up by retention policy)

## Health Endpoint Integration

When the health check endpoint is enabled (`HEALTH_CHECK_ENABLED=true`), it exposes real-time progress information.

### Enabling Health Endpoint

```bash
export HEALTH_CHECK_ENABLED=true
export HEALTH_CHECK_PORT=8080
```

### Health Response Format

```json
{
  "state": "processing",
  "last_update": "2026-02-24T12:30:00Z",
  "current_job": {
    "job_id": "job-abc123",
    "stage": "Training",
    "progress_percentage": 62.5,
    "video_count": 3,
    "total_frames": 450,
    "gaussian_count": null,
    "started_at": "2026-02-24T12:00:00Z"
  }
}
```

### Querying Progress

```bash
curl http://localhost:8080/health | jq .

# Example output:
{
  "state": "processing",
  "current_job": {
    "job_id": "scene-capture-20260224",
    "stage": "Training",
    "progress_percentage": 62.5,
    "video_count": 5,
    "total_frames": 750,
    "started_at": "2026-02-24T12:00:00Z"
  }
}
```

### Monitoring Progress in Script

```bash
#!/bin/bash
# Monitor job progress until completion

while true; do
  response=$(curl -s http://localhost:8080/health)
  state=$(echo "$response" | jq -r '.state')
  
  if [ "$state" == "processing" ]; then
    progress=$(echo "$response" | jq -r '.current_job.progress_percentage')
    stage=$(echo "$response" | jq -r '.current_job.stage')
    echo "Progress: ${progress}% - Stage: $stage"
  elif [ "$state" == "watching" ]; then
    echo "Job completed, processor watching for new jobs"
    break
  else
    echo "State: $state"
  fi
  
  sleep 5
done
```

## Resume Capability

The processor automatically resumes jobs from the last completed checkpoint.

### How Resume Works

1. **On job start**: Check for existing `.checkpoint.json` in output folder
2. **Validate checkpoint**: Ensure it's recent (< 24 hours) and not completed
3. **Resume from stage**: Skip already-completed stages, continue from current stage
4. **Re-process if needed**: Some stages (frame extraction, training) may be re-executed

### Resume Example

If a job fails at the Training stage:

```
Stage 0 (Validation): ✓ Completed (skipped on resume)
Stage 1 (FrameExtraction): ✓ Completed (skipped on resume)  
Stage 2 (MetadataExtraction): ✓ Completed (skipped on resume)
Stage 3 (ManifestGeneration): ✓ Completed (skipped on resume)
Stage 4 (ColmapReconstruction): ✓ Completed (skipped on resume)
Stage 5 (Training): ✗ Failed (resume starts here)
```

On restart, the job automatically resumes from Training stage, skipping all previous stages.

### Force Fresh Start

To force a fresh start (ignore checkpoints), delete the checkpoint file:

```bash
rm /mnt/output/job-abc123/.checkpoint.json
```

## Usage Examples

### Example 1: Monitor Progress Programmatically

```rust
use three_dgs_processor::health::{HealthCheckState, JobProgress};
use three_dgs_processor::processor::ProcessingStage;

async fn monitor_job(health_state: &HealthCheckState) {
    loop {
        let status = health_state.get_status().await;
        
        if let Some(job) = status.current_job {
            println!("Job: {} - {}% - {}", 
                job.job_id,
                job.progress_percentage,
                job.stage
            );
            
            if job.progress_percentage >= 100.0 {
                break;
            }
        }
        
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}
```

### Example 2: Inspect Checkpoint

```bash
# View current checkpoint
cat /mnt/output/job-abc123/.checkpoint.json | jq .

# Check progress percentage
cat /mnt/output/job-abc123/.checkpoint.json | jq '.stage' | \
  python -c "
stages = {'Validation': 0, 'FrameExtraction': 12.5, 'MetadataExtraction': 25,
          'ManifestGeneration': 37.5, 'ColmapReconstruction': 50,
          'Training': 62.5, 'PlyExport': 75, 'SplatExport': 87.5, 
          'Completed': 100}
import sys, json
stage = json.load(sys.stdin)
print(f'{stages.get(stage, 0)}%')
"
```

### Example 3: Resume After Restart

```bash
# Start processor
docker run -d --name 3dgs-processor \
  -e INPUT_PATH=/mnt/input \
  -e OUTPUT_PATH=/mnt/output \
  youracr.azurecr.io/3dgs-processor:cpu

# ... processor crashes or is stopped ...

# Restart - automatically resumes from checkpoint
docker start 3dgs-processor

# Check logs to confirm resume
docker logs 3dgs-processor | grep "Resuming from checkpoint"
```

## Configuration

Progress tracking is always enabled. Checkpoint files are created automatically in the output directory.

### Environment Variables

No specific configuration needed for progress tracking itself. Related settings:

```bash
# Health endpoint (optional, for exposing progress via HTTP)
HEALTH_CHECK_ENABLED=true
HEALTH_CHECK_PORT=8080

# Output path (where checkpoints are stored)
OUTPUT_PATH=/mnt/output

# Retention (how long to keep completed checkpoints)
CLEANUP_RETENTION_DAYS=7  # Default: 7 days
```

### Checkpoint Retention

Completed checkpoints (stage = Completed) are retained based on `CLEANUP_RETENTION_DAYS`:

```bash
export CLEANUP_RETENTION_DAYS=7  # Keep completed checkpoints for 7 days
```

Old checkpoints are cleaned up by the retention scheduler to prevent disk space issues.

## Architecture

### Key Components

1. **ProgressTracker** (`src/processor/progress.rs`)
   - Tracks current stage and progress percentage
   - Saves checkpoints to disk
   - Provides resume capability

2. **JobCheckpoint** (`src/processor/progress.rs`)
   - Serializable checkpoint data structure
   - Persisted as JSON to output folder

3. **ProcessingStage** (`src/processor/progress.rs`)
   - Enum of all pipeline stages
   - Provides progress percentage calculation

4. **HealthCheckState** (`src/health/mod.rs`)
   - Exposes progress via HTTP endpoint
   - Updated by ProgressTracker during job execution

### Data Flow

```
Job Execution
     ↓
ProgressTracker (creates checkpoint)
     ↓
Complete Stage → Update checkpoint → Save to disk
     ↓
Update HealthCheckState (if enabled)
     ↓
Health Endpoint returns progress
```

## Troubleshooting

### Checkpoint Not Resuming

**Issue**: Job restarts from beginning even though checkpoint exists

**Solutions**:

1. Check checkpoint age - must be < 24 hours
2. Verify checkpoint is not marked as Completed
3. Check logs for "Checkpoint too old" warnings
4. Ensure output folder path matches checkpoint location

### Progress Not Updating in Health Endpoint

**Issue**: `/health` endpoint shows stale progress

**Solutions**:

1. Verify `HEALTH_CHECK_ENABLED=true`
2. Check health endpoint port is correct
3. Ensure job is actually running (check container logs)
4. Confirm checkpoint file is being updated (check timestamps)

### Disk Space Issues from Checkpoints

**Issue**: Many old checkpoint files consuming space

**Solutions**:

1. Reduce `CLEANUP_RETENTION_DAYS` value
2. Manually delete old output folders
3. Enable automatic cleanup (verify retention scheduler is running)

## Best Practices

1. **Monitor Progress**: Enable health endpoint in production for visibility
2. **Set Reasonable Retention**: Balance debugging needs vs disk space
3. **Log Checkpoint Events**: Retain logs showing checkpoint save/resume
4. **Test Resume**: Periodically test restart resilience in staging
5. **Handle Failed Jobs**: Move failed jobs to error folder to avoid re-processing

## Related Documentation

- [Architecture](ARCHITECTURE.md) - System architecture overview
- [Deployment](DEPLOYMENT.md) - Deployment guide
- [User Guide](USER_GUIDE.md) - End-to-end usage guide
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
