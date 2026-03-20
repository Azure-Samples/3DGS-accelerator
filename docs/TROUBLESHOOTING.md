# Troubleshooting Guide: 3DGS Video Processor

Common issues, solutions, and debugging techniques.

## Table of Contents

* [Quick Diagnostics](#quick-diagnostics)
* [Common Errors](#common-errors)
* [Performance Issues](#performance-issues)
* [Azure Blob Storage Issues](#azure-blob-storage-issues)
* [Debug Mode](#debug-mode)
* [FAQ](#faq)

## Quick Diagnostics

### Check Service Status

```bash
# Docker
docker ps | grep 3dgs-processor
docker logs 3dgs-processor --tail 50

# Kubernetes
kubectl get pods -n 3dgs
kubectl logs deployment/3dgs-processor -n 3dgs --tail 50
```

### Verify Configuration

```bash
# Environment variables
docker inspect 3dgs-processor | grep -A 20 "Env"

# Volume mounts
docker inspect 3dgs-processor | grep -A 20 "Mounts"
```

### Check Disk Space

```bash
# Host system
df -h

# Inside container
docker exec 3dgs-processor df -h /data
```

### Health Check

```bash
curl http://localhost:8080/health

# Expected response
{"status":"healthy","uptime_secs":3600}
```

## Common Errors

### Error: "No videos found in input folder"

**Symptom**: Folder detected but processing doesn't start.

**Causes**:

* Folder contains no video files
* Video files have unsupported extensions
* Files still uploading (stability timeout not met)

**Solutions**:

1. **Check file extensions**:

   ```bash
   ls input/scene_001/
   # Should show .mp4, .mov, .avi files
   ```

2. **Verify file completion**:

   ```bash
   # Wait for upload stability (30s default)
   # Check logs for "Upload stable, starting processing"
   ```

3. **Manually trigger**:

   ```bash
   touch input/scene_001/.complete
   # Force processing start
   ```

### Error: "FFmpeg extraction failed"

**Symptom**: Frame extraction fails during processing.

**Error Message**:

```
ERROR three_dgs_processor::extractors::ffmpeg: FFmpeg extraction failed
video_path="/data/input/scene_001/view1.mp4" error="Process exited with code 1"
```

**Causes**:

* Corrupted video file
* Unsupported codec
* Disk full during extraction

**Solutions**:

1. **Validate video file**:

   ```bash
   docker exec 3dgs-processor ffmpeg -i /data/input/scene_001/view1.mp4 2>&1 | grep "Invalid"
   ```

2. **Check disk space**:

   ```bash
   df -h /data
   # Ensure >10GB free
   ```

3. **Test FFmpeg manually**:

   ```bash
   docker exec 3dgs-processor ffmpeg -i /data/input/scene_001/view1.mp4 -vframes 1 /tmp/test.jpg
   ```

4. **Re-encode video**:

   ```bash
   ffmpeg -i corrupted.mp4 -c:v libx264 -preset fast -crf 23 re-encoded.mp4
   ```

### Error: "COLMAP reconstruction failed"

**Symptom**: Camera pose estimation fails.

**Error Message**:

```
ERROR three_dgs_processor::colmap::runner: COLMAP sparse reconstruction failed
error="Insufficient feature matches"
```

**Causes**:

* Videos don't overlap (different scenes)
* Insufficient texture (blank walls)
* Too few frames extracted
* Poor lighting conditions

**Solutions**:

1. **Verify multi-view capture**:
   * Check that videos show the same scene from different angles
   * Ensure 50-70% overlap between viewpoints

2. **Increase frame extraction**:

   ```yaml
   # config.yaml
   frame_extraction:
     interval_secs: 0.1  # Extract every 0.1s instead of 0.2s
   ```

3. **Check COLMAP output**:

   ```bash
   docker exec 3dgs-processor ls /tmp/colmap_*/sparse/0
   # Should contain cameras.bin, images.bin, points3D.bin
   ```

4. **Manual COLMAP run** (debugging):

   ```bash
   docker exec -it 3dgs-processor bash
   colmap feature_extractor --database_path /tmp/db.db --image_path /tmp/frames
   colmap exhaustive_matcher --database_path /tmp/db.db
   colmap mapper --database_path /tmp/db.db --image_path /tmp/frames --output_path /tmp/sparse
   ```

### Error: "Backend training failed"

**Symptom**: 3DGS training process crashes or fails.

**Error Message**:

```
ERROR three_dgs_processor::backends::gaussian_splatting: Training failed
iterations=5000 error="CUDA out of memory"
```

**Causes**:

* Insufficient GPU memory
* Too many Gaussians for available RAM
* Backend bug or incompatibility

**Solutions**:

1. **Check GPU availability**:

   ```bash
   docker exec 3dgs-processor nvidia-smi
   # Should show GPU and memory usage
   ```

2. **Reduce training parameters**:

   ```yaml
   # config.yaml
   training:
     iterations: 15000  # Reduce from 30000
     densify_grad_threshold: 0.0004  # Increase (fewer Gaussians)
   ```

3. **Switch backend**:

   ```bash
   # Use CPU backend if GPU unavailable
   -e BACKEND=3dgs-cpp
   ```

4. **Increase GPU memory** (cloud deployment):
   * Use larger GPU instance (e.g., AWS p3.2xlarge → p3.8xlarge)

### Error: "Azure Blob mount failed"

**Symptom**: Container starts but can't access Azure Blob Storage.

**Error Message**:

```
ERROR three_dgs_processor::azure::mount: Blobfuse2 mount failed
account="mystorageaccount" error="Authentication failed"
```

**Causes**:

* Invalid connection string or SAS token
* Expired SAS token
* Network connectivity issues
* Blobfuse2 not installed in container

**Solutions**:

1. **Verify credentials**:

   ```bash
   # Test with Azure CLI
   az storage blob list \
     --account-name mystorageaccount \
     --container-name 3dgs-input \
     --connection-string "..."
   ```

2. **Check SAS token expiry**:

   ```bash
   # Regenerate SAS token
   az storage container generate-sas \
     --account-name mystorageaccount \
     --name 3dgs-input \
     --permissions racwdl \
     --expiry 2026-12-31
   ```

3. **Verify container is privileged**:

   ```bash
   docker inspect 3dgs-processor | grep Privileged
   # Should show "Privileged": true
   ```

4. **Check Blobfuse2 installation**:

   ```bash
   docker exec 3dgs-processor which blobfuse2
   # Should show /usr/bin/blobfuse2
   ```

## Performance Issues

### Slow Frame Extraction

**Symptom**: Frame extraction takes minutes per video.

**Solutions**:

1. **Use SSD storage** for input/output paths
2. **Increase CPU allocation**:

   ```yaml
   deploy:
     resources:
       limits:
         cpus: '8'  # Increase from 4
   ```

3. **Reduce frame rate**:

   ```yaml
   frame_extraction:
     fps: 10  # Extract 10 fps instead of 30
   ```

### High Memory Usage

**Symptom**: Container OOM (Out of Memory) killed.

**Solutions**:

1. **Increase memory limit**:

   ```yaml
   deploy:
     resources:
       limits:
         memory: 32G  # Increase from 16GB
   ```

2. **Process smaller batches**:
   * Split large video sets into multiple jobs

3. **Check for memory leaks**:

   ```bash
   docker stats 3dgs-processor
   # Monitor RSS over time
   ```

### Disk Full Errors

**Symptom**: Processing stops with "No space left on device".

**Solutions**:

1. **Clean processed data**:

   ```bash
   # Manually delete old processed folders
   rm -rf processed/scene_*
   ```

2. **Reduce retention period**:

   ```bash
   -e RETENTION_DAYS=7  # Reduce from 30
   ```

3. **Increase disk size** (cloud deployment)
4. **Monitor disk usage**:

   ```bash
   docker exec 3dgs-processor df -h
   ```

## Azure Blob Storage Issues

### Slow Blobfuse2 Performance

**Solutions**:

1. **Increase cache size**:

   ```bash
   -e BLOBFUSE_CACHE_SIZE_MB=20480  # 20GB cache
   ```

2. **Use Premium Block Blob storage** for better IOPS
3. **Enable caching**:

   ```bash
   -e BLOBFUSE_FILE_CACHE_TIMEOUT_SECS=300
   ```

### Authentication Errors

**Verify with Azure CLI**:

```bash
# Test connection
az storage blob list \
  --account-name mystorageaccount \
  --container-name 3dgs-input \
  --auth-mode login

# Check permissions
az role assignment list \
  --assignee <managed-identity-id> \
  --scope /subscriptions/.../storageAccounts/mystorageaccount
```

## Debug Mode

### Enable Verbose Logging

```bash
# Set to trace level
-e LOG_LEVEL=trace

# Or debug level
-e LOG_LEVEL=debug
```

### Run Interactively

```bash
# Start container with bash
docker run -it --entrypoint bash youracr.azurecr.io/3dgs-processor:cpu

# Manually run processor
INPUT_PATH=/data/input OUTPUT_PATH=/data/output /app/3dgs-processor
```

### Inspect Temporary Files

```bash
# Keep temp files for debugging
-e KEEP_TEMP_FILES=true

# Check temp directory
docker exec 3dgs-processor ls -lh /tmp/3dgs_*
```

### Extract Stack Traces

```bash
# Enable Rust backtraces
-e RUST_BACKTRACE=1

# Or full backtraces
-e RUST_BACKTRACE=full
```

## FAQ

### Q: Why does processing take so long?

**A**: Processing time depends on:

* Video resolution (4K takes 3-4x longer than 1080p)
* Number of videos (3+ videos require more COLMAP matching)
* Training iterations (30000 iterations ≈ 10-30 minutes)
* GPU availability (CPU-only is 5-10x slower)

**Typical durations:**

* 2 videos, 1080p, 30000 iterations: **15-20 minutes**
* 5 videos, 4K, 30000 iterations: **60-90 minutes**

### Q: Can I run multiple instances for parallel processing?

**A**: Yes, with separate input directories:

```bash
# Instance 1
-e INPUT_PATH=/data/input-1

# Instance 2
-e INPUT_PATH=/data/input-2
```

**Note**: Each instance processes jobs sequentially.

### Q: How do I change the backend after deployment?

**A**: Restart container with new `BACKEND` env var:

```bash
docker stop 3dgs-processor
docker rm 3dgs-processor

docker run -d \
  -e BACKEND=gsplat \  # Changed from gaussian-splatting
  ...
```

### Q: What happens if the container crashes mid-processing?

**A**: Jobs in progress are moved to the error folder on restart. Re-upload videos to retry.

### Q: Can I process a single video (not multi-view)?

**A**: Yes, but reconstruction quality will be lower. Place a single video in the job folder.

### Q: How do I view the output models?

**A**: Use these viewers:

* **PLY files**: MeshLab, CloudCompare, Blender
* **SPLAT files**: <https://antimatter15.com/splat/> (web viewer)

### Q: Why are files in the error folder?

**A**: Check logs for the specific job:

```bash
docker logs 3dgs-processor 2>&1 | grep "scene_001"
```

Common reasons:

* Corrupted videos
* COLMAP reconstruction failure (insufficient overlap)
* Training divergence (rare)
* Disk full during processing

### Q: How do I reduce output file sizes?

**A**: Adjust training parameters:

```yaml
training:
  iterations: 15000  # Reduce from 30000
  densify_grad_threshold: 0.001  # Increase (fewer Gaussians)
```

This produces smaller .ply/.splat files with slightly lower quality.

### Q: Can I customize the output format?

**A**: Yes, modify `export_formats` in `config.yaml`:

```yaml
training:
  export_formats:
    - ply   # Include PLY
    # - splat  # Exclude SPLAT
```

Or implement a custom exporter in `src/exporters/`.

### Q: How do I monitor job progress in real-time?

**A**: Watch logs with filtering:

```bash
docker logs -f 3dgs-processor 2>&1 | grep -E "(Processing job|Training iteration|Export complete)"
```

Look for:

* `Processing job: scene_001` - Job started
* `Training iteration 10000/30000 loss=0.005` - Training progress
* `Export complete: model.ply` - Job finished

### Q: What's the difference between backends?

| Backend | Speed | Quality | GPU Required | Use Case |
|---------|-------|---------|--------------|----------|
| `gaussian-splatting` | Medium | Best | Yes | Research, highest quality |
| `gsplat` | Fast | Best | Yes | Production (recommended) |
| `3dgs-cpp` | Medium | Good | No | CPU-only environments |

**Recommendation**: Use `gsplat` for production deployments.

### Q: How do I clean up old data automatically?

**A**: Set retention policy:

```bash
-e RETENTION_DAYS=7  # Auto-delete processed data after 7 days
```

Manual cleanup:

```bash
find processed/ -type d -mtime +7 -exec rm -rf {} \;
```

### Q: Can I customize COLMAP parameters?

**A**: Yes, edit `config.yaml`:

```yaml
colmap:
  matcher_type: exhaustive  # or sequential, spatial
  num_threads: 8
  min_num_matches: 15
```

**Warning**: Incorrect COLMAP settings can cause reconstruction failures.

---

## Real-World Troubleshooting Examples

### Example 1: "Job stuck in processing for hours"

**Symptoms**:
- Job started but no progress updates
- Logs show "Training iteration 0/30000" for extended time
- High CPU usage but no GPU activity

**Root Cause**: GPU not detected, falling back to slow CPU training

**Solution**:
```bash
# Check GPU availability
docker exec 3dgs-processor nvidia-smi  # For NVIDIA
# OR
docker exec 3dgs-processor python -c "import torch; print(torch.cuda.is_available())"

# If False, restart with GPU support
docker run --gpus all \
  -e BACKEND=gsplat \
  youracr.azurecr.io/3dgs-processor:gpu

# Verify GPU detected in logs
docker logs 3dgs-processor | grep -i gpu
# Expected: "GPU detected: NVIDIA GeForce RTX 3090"
```

**Prevention**: Always check GPU detection on first deployment

---

### Example 2: "COLMAP reconstruction failed: insufficient points"

**Symptoms**:
```
ERROR COLMAP reconstruction failed: Only 324 3D points reconstructed (minimum: 500)
job_id=outdoor_scene
```

**Root Cause**: Videos have insufficient overlap or poor feature matching

**Diagnosis**:
```bash
# Check video overlap visually
docker exec 3dgs-processor ls /data/input/outdoor_scene/
# view1.mp4, view2.mp4, view3.mp4

# Examine frame extraction
docker exec 3dgs-processor ls /tmp/3dgs_outdoor_scene/frames/
# Should show frames from all videos
```

**Solutions**:

1. **Re-capture with better overlap**:
   - Ensure 60-70% overlap between viewpoints
   - Move camera slowly and smoothly
   - Avoid sudden viewpoint changes

2. **Adjust COLMAP settings** (reduce requirements):
   ```yaml
   # config.yaml
   colmap:
     min_num_matches: 10  # Reduced from 15
     multiple_models: false
   ```

3. **Add more videos** to the scene:
   ```bash
   # Add view4.mp4 and view5.mp4 for better coverage
   cp view4.mp4 view5.mp4 input/outdoor_scene/
   ```

4. **Use precalibrated backend** (if you have poses):
   ```bash
   -e RECONSTRUCTION_BACKEND=precalibrated
   # Provide camera_poses.json in job folder
   ```

---

### Example 3: "Video validation failed: resolution too low"

**Symptoms**:
```
ERROR Video validation failed: Resolution 640x480 below minimum 1280x720
video=/data/input/scene_001/phone_video.mp4
```

**Root Cause**: Input video doesn't meet quality requirements

**Solutions**:

1. **Re-encode video at higher resolution** (if source quality supports it):
   ```bash
   ffmpeg -i phone_video.mp4 -vf scale=1920:1080 -c:v libx264 phone_video_hd.mp4
   ```

2. **Lower validation thresholds** (not recommended for quality):
   ```bash
   -e MIN_VIDEO_WIDTH=640 \
   -e MIN_VIDEO_HEIGHT=480
   ```

3. **Use higher quality source**:
   - Record at 1080p or 4K on phone camera
   - Avoid downloading compressed social media videos
   - Use original camera files, not screenshots

---

### Example 4: "Disk full during processing"

**Symptoms**:
```
ERROR Disk space critical: 2.3 GB free (minimum: 10 GB)
WARN Cleanup attempt freed 5.2 GB (oldest 3 jobs removed)
ERROR Job failed: No space left on device
```

**Immediate Fix**:
```bash
# Free space manually
docker exec 3dgs-processor rm -rf /data/processed/old_job_*

# Check space
docker exec 3dgs-processor df -h /data
```

**Long-term Solutions**:

1. **Increase retention cleanup**:
   ```bash
   -e RETENTION_DAYS=3  # More aggressive cleanup
   ```

2. **Mount larger volume**:
   ```bash
   -v /mnt/large_disk/3dgs-data:/data
   ```

3. **Reduce temporary file size**:
   ```yaml
   # config.yaml
   frame_extraction:
     jpeg_quality: 85  # Reduced from 95
     max_dimension: 1920  # Cap resolution
   ```

4. **Monitor space proactively**:
   ```bash
   # Alert when below 20GB
   docker exec 3dgs-processor df -h /data | awk '$4 < 20480 {print "⚠️ Low disk space: " $4}'
   ```

---

### Example 5: "Azure Blob Storage authentication failed"

**Symptoms**:
```
ERROR Azure authentication failed: SAS token expired
ERROR Blobfuse2 mount failed: container 'input' not accessible
```

**Solutions**:

1. **Check SAS token expiration**:
   ```bash
   # Regenerate SAS token with longer expiry
   az storage container generate-sas \
     --account-name mystorageaccount \
     --name 3dgs-input \
     --permissions rwdl \
     --expiry 2026-12-31 \
     --https-only
   ```

2. **Use Managed Identity** (recommended):
   ```bash
   # Azure Container Instances
   az container create \
     --assign-identity \
     --role "Storage Blob Data Contributor" \
     ...
   
   # Set environment
   -e AZURE_STORAGE_ACCOUNT=mystorageaccount \
   -e AZURE_CONTAINER_NAME=3dgs-input
   # (no connection string or SAS token needed)
   ```

3. **Verify blob permissions**:
   ```bash
   az storage blob list \
     --account-name mystorageaccount \
     --container-name 3dgs-input \
     --auth-mode login
   ```

See [DEPLOYMENT.md](DEPLOYMENT.md#azure-blob-storage) for complete Azure setup.

---

### Example 6: "Training diverges: loss becomes NaN"

**Symptoms**:
```
INFO Training iteration 5234/30000 loss=0.002341
INFO Training iteration 5235/30000 loss=nan
ERROR Training failed: Loss became NaN (divergence)
```

**Root Cause**: Learning rate too high or unstable scene geometry

**Solutions**:

1. **Reduce learning rates**:
   ```yaml
   # config.yaml
   training:
     learning_rate: 0.0001  # Reduced from 0.0002
     position_lr: 0.00008   # Reduced from 0.00016
   ```

2. **Increase stabilization**:
   ```yaml
   training:
     densify_grad_threshold: 0.0001  # More conservative
     opacity_reset_interval: 2000    # More frequent resets
   ```

3. **Check input quality**:
   - Ensure COLMAP reconstruction is good (>1000 points)
   - Verify videos show consistent scene (no moving objects)
   - Check for proper lighting (avoid dark/overexposed areas)

4. **Try different backend**:
   ```bash
   # Switch from gsplat to gaussian-splatting
   -e BACKEND=gaussian-splatting
   ```

---

### Example 7: "Port 8080 already in use"

**Symptoms**:
```
ERROR Health check server failed to start: Address already in use
```

**Solution**:
```bash
# Find conflicting process
lsof -i :8080
# OR
netstat -tulpn | grep 8080

# Use different port
docker run -p 8081:8080 \  # Map internal 8080 to host 8081
  youracr.azurecr.io/3dgs-processor:cpu

# Access health endpoint
curl http://localhost:8081/health
```

**Prevention**: Always specify explicit port mapping in production

---

### Example 8: "Container exits immediately after start"

**Symptoms**:
```bash
docker ps  # Container not running
docker ps -a  # Shows "Exited (1) 5 seconds ago"
```

**Diagnosis**:
```bash
# Check logs for startup errors
docker logs 3dgs-processor

# Common errors:
# - Missing environment variables
# - Volume mount permission denied
# - Configuration file syntax error
```

**Solutions**:

1. **Missing environment variables**:
   ```bash
   # Verify required vars are set
   docker run ... \
     -e INPUT_PATH=/data/input \   # Required
     -e OUTPUT_PATH=/data/output \ # Required
     -e PROCESSED_PATH=/data/processed \
     -e ERROR_PATH=/data/error \
     -e BACKEND=gsplat  # Required
   ```

2. **Volume permissions**:
   ```bash
   # Fix ownership
   sudo chown -R $(id -u):$(id -g) /path/to/data
   
   # Or run as root (not recommended)
   docker run --user root ...
   ```

3. **Config file issues**:
   ```bash
   # Validate YAML syntax
   yamllint config.yaml
   
   # Test with default config
   docker run ... # Without -v config.yaml mount
   ```

---

### Example 9: "Memory usage keeps increasing"

**Symptoms**:
- Container shows 8GB+ memory usage
- System becomes unresponsive
- OOMKilled errors in logs

**Diagnosis**:
```bash
# Monitor memory in real-time
docker stats 3dgs-processor

# Check for memory leaks
docker exec 3dgs-processor ps aux --sort=-rss
```

**Solutions**:

1. **Set memory limits**:
   ```bash
   docker run --memory=8g --memory-swap=12g \
     youracr.azurecr.io/3dgs-processor:cpu
   ```

2. **Reduce concurrent processing**:
   ```yaml
   # Process videos sequentially instead of parallel
   frame_extraction:
     concurrent_videos: 1  # Reduced from auto
   ```

3. **Lower COLMAP memory usage**:
   ```yaml
   colmap:
     max_image_size: 1600  # Reduce from 3200
     cache_size: 16  # Reduce cache
   ```

4. **Cleanup temporary files more aggressively**:
   ```bash
   -e KEEP_TEMP_FILES=false  # Delete immediately after use
   ```

---

### Example 10: "Output models look corrupted/garbled"

**Symptoms**:
- PLY file loads but shows random noise
- SPLAT viewer shows artifacts
- Model has too few or too many Gaussians

**Root Causes & Solutions**:

1. **Bad input videos** (most common):
   ```bash
   # Check extracted frames
   docker exec 3dgs-processor ls /tmp/3dgs_*/frames/
   
   # Verify frame quality
   docker cp 3dgs-processor:/tmp/3dgs_job_id/frames/frame_000100.jpg .
   # Inspect visually - should be clear, well-lit
   ```

2. **COLMAP failure** (insufficient camera poses):
   ```bash
   # Check COLMAP output
   docker exec 3dgs-processor ls /tmp/3dgs_*/colmap/sparse/0/
   # Should contain: cameras.bin, images.bin, points3D.bin
   
   # Verify point count
   docker logs 3dgs-processor | grep "3D points"
   # Should be >500 (ideally >2000)
   ```

3. **Training insufficient**:
   ```yaml
   # Increase iterations
   training:
     iterations: 50000  # From 30000
   ```

4. **Wrong backend for your GPU**:
   ```bash
   # Auto-detect proper backend
   -e BACKEND=auto
   
   # Or manually select
   -e BACKEND=gsplat  # NVIDIA CUDA
   ```
<!-- -e BACKEND=gaussian-splatting  # Metal/ROCm -->

## Still Having Issues?

1. **Check logs carefully** - Error messages contain detailed context
2. **Enable debug logging** - `LOG_LEVEL=debug`
3. **Test with sample data** - Run `./scripts/generate-test-videos.sh`
4. **Report issues** - GitHub Issues with logs and configuration
