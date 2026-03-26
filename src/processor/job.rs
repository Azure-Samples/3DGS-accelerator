//! Job execution orchestration for end-to-end processing
//!
//! This module coordinates the complete processing pipeline:
//! 1. Folder validation and video discovery
//! 2. Frame extraction from all videos
//! 3. Metadata extraction (GPS, camera info)
//! 4. Manifest generation
//! 5. COLMAP sparse reconstruction
//! 6. 3DGS backend training
//! 7. PLY and SPLAT export
//!
//! Jobs are processed sequentially (one at a time) to avoid resource contention.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::time::Instant;
use tracing::{error, info, warn, instrument};

use crate::backends::{BackendRegistry, TrainingConfig};
use crate::extractors::ffmpeg::{ExtractionOptions, VideoInput};
use crate::reconstruction::get_reconstruction_backend;
use crate::extractors::{extract_metadata, FrameSet, VideoMetadata};
use crate::health::{HealthCheckState, JobProgress};
use crate::manifest::generate_manifest;
use crate::processor::multi_video::process_videos;
use crate::processor::progress::{ProgressTracker, ProcessingStage};
use crate::validation::{ValidationConfig, VideoValidator};

/// Parameters for job execution
#[derive(Clone)]
pub struct JobExecutionParams {
    pub job_id: String,
    pub input_folder: PathBuf,
    pub output_folder: PathBuf,
    pub temp_folder: PathBuf,
    pub training_config: TrainingConfig,
    pub backend_name: Option<String>,
    pub validation_config: ValidationConfig,
}

/// Job execution result
#[derive(Debug, Clone)]
pub struct JobResult {
    /// Job identifier
    pub job_id: String,
    /// Processing status
    pub status: JobStatus,
    /// Total processing time
    pub duration_secs: f64,
    /// Output paths (if successful)
    pub outputs: Option<JobOutputs>,
    /// Error message (if failed)
    pub error: Option<String>,
}

/// Job processing status
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobStatus {
    /// Job completed successfully
    Success,
    /// Job failed with error
    Failed,
}

/// Output paths from successful job execution
#[derive(Debug, Clone)]
pub struct JobOutputs {
    /// Path to exported PLY file
    pub ply_path: PathBuf,
    /// Path to exported SPLAT file
    pub splat_path: PathBuf,
    /// Path to manifest JSON
    pub manifest_path: PathBuf,
    /// Path to COLMAP sparse reconstruction
    pub colmap_sparse_path: PathBuf,
}

/// Execute a complete processing job for a folder
///
/// This function orchestrates the entire pipeline from video input to
/// final 3DGS model export. It handles all intermediate steps and cleanup.
/// Supports checkpoint resumption for restart resilience.
///
/// # Arguments
///
/// * `job_id` - Unique identifier for this job
/// * `input_folder` - Path to folder containing input videos
/// * `output_folder` - Path where outputs will be written
/// * `temp_folder` - Path for temporary working files
/// * `training_config` - 3DGS training hyperparameters
/// * `backend_name` - Backend to use (or None for auto-detection)
/// * `health_state` - Optional health check state for progress updates
///
/// # Returns
///
/// A `JobResult` containing status, outputs, and timing information
///
/// # Processing Steps
///
/// 1. **Validation**: Check folder exists and contains videos
/// 2. **Frame Extraction**: Extract frames from all videos concurrently
/// 3. **Metadata Extraction**: Extract GPS and camera metadata
/// 4. **Manifest Generation**: Create manifest.json with camera intrinsics
/// 5. **COLMAP**: Run sparse reconstruction for camera poses
/// 6. **Training**: Run 3DGS backend training (auto-selected based on GPU)
/// 7. **Export**: Export to PLY and SPLAT formats
///
/// # Checkpointing
///
/// Progress is saved after each stage to `.checkpoint.json` in the output folder.
/// If the process restarts, it will automatically resume from the last checkpoint.
///
/// # Error Handling
///
/// If any step fails, the function returns a JobResult with status=Failed
/// and captures the error message. Temporary files are cleaned up on both
/// success and failure paths.
#[instrument(skip(params, health_state), fields(job_id = %params.job_id))]
pub async fn execute_job(
    params: JobExecutionParams,
    health_state: Option<&HealthCheckState>,
) -> JobResult {
    let start_time = Instant::now();
    let job_start_time = chrono::Utc::now();

    info!(
        job_id = %params.job_id,
        input_folder = %params.input_folder.display(),
        "Starting job execution"
    );

    // Try to resume from checkpoint
    let mut progress = match ProgressTracker::try_resume(&params.output_folder) {
        Ok(Some(tracker)) => {
            info!(
                job_id = %params.job_id,
                stage = ?tracker.stage(),
                progress = tracker.progress_percentage(),
                "Resuming from checkpoint"
            );
            tracker
        }
        Ok(None) => {
            info!(job_id = %params.job_id, "Starting new job (no checkpoint found)");
            ProgressTracker::new(
                params.job_id.clone(),
                params.input_folder.clone(),
                params.output_folder.clone(),
                params.temp_folder.clone(),
            )
        }
        Err(e) => {
            warn!(
                job_id = %params.job_id,
                error = %e,
                "Failed to load checkpoint, starting fresh"
            );
            ProgressTracker::new(
                params.job_id.clone(),
                params.input_folder.clone(),
                params.output_folder.clone(),
                params.temp_folder.clone(),
            )
        }
    };

    // Execute pipeline and capture result
    let result = execute_job_internal(
        &params,
        &mut progress,
        health_state,
        job_start_time,
    )
    .await;

    let duration_secs = start_time.elapsed().as_secs_f64();

    match result {
        Ok(outputs) => {
            info!(
                job_id = %params.job_id,
                duration_secs = duration_secs,
                "Job completed successfully"
            );
            JobResult {
                job_id: params.job_id,
                status: JobStatus::Success,
                duration_secs,
                outputs: Some(outputs),
                error: None,
            }
        }
        Err(e) => {
            error!(
                job_id = %params.job_id,
                duration_secs = duration_secs,
                error = %format!("{:#}", e),
                "Job failed"
            );
            JobResult {
                job_id: params.job_id,
                status: JobStatus::Failed,
                duration_secs,
                outputs: None,
                error: Some(e.to_string()),
            }
        }
    }
}

/// Internal job execution implementation
///
/// Separated from execute_job() to simplify error handling with ?
async fn execute_job_internal(
    params: &JobExecutionParams,
    progress: &mut ProgressTracker,
    health_state: Option<&HealthCheckState>,
    job_start_time: chrono::DateTime<chrono::Utc>,
) -> Result<JobOutputs> {
    /// Helper to update health endpoint with current progress
    async fn update_health(progress: &ProgressTracker, health_state: Option<&HealthCheckState>, job_start_time: chrono::DateTime<chrono::Utc>) {
        if let Some(state) = health_state {
            let completed = progress.completed_stages();
            let job_progress = JobProgress {
                job_id: progress.job_id().to_string(),
                stage: progress.stage().name().to_string(),
                progress_percentage: progress.progress_percentage(),
                video_count: completed.video_count,
                total_frames: completed.total_frames,
                gaussian_count: completed.gaussian_count,
                started_at: job_start_time,
            };
            state.update_job_progress(job_progress).await;
        }
    }

    // Initialize backend registry and select appropriate backend
    let mut registry = BackendRegistry::new();
    registry.register_defaults();
    
    let selected_backend = params.backend_name.clone().unwrap_or_else(|| {
        BackendRegistry::resolve_backend_name(None)
    });
    
    info!(
        job_id = %params.job_id,
        backend = %selected_backend,
        "Using 3DGS backend"
    );
    
    let backend = registry.get_backend(&selected_backend)
        .await
        .with_context(|| format!("Failed to load backend '{}'", selected_backend))?;

    let job_id = &params.job_id;
    let input_folder = &params.input_folder;
    let output_folder = &params.output_folder;
    let temp_folder = &params.temp_folder;
    let training_config = &params.training_config;

    // Step 1: Validate folder and discover videos
    if progress.stage() == ProcessingStage::Validation {
        info!(job_id = %job_id, "Step 1: Validating folder and discovering videos");
        let videos =
            discover_videos(input_folder).context("Failed to discover videos in input folder")?;

        if videos.is_empty() {
            anyhow::bail!(
                "No videos found in input folder: {}",
                input_folder.display()
            );
        }

        info!(
            job_id = %job_id,
            video_count = videos.len(),
            "Discovered {} videos",
            videos.len()
        );

        // Validate discovered videos
        info!(
            job_id = %job_id,
            min_width = params.validation_config.min_width,
            min_height = params.validation_config.min_height,
            min_frames = params.validation_config.min_frames,
            min_duration = params.validation_config.min_duration_secs,
            "Validating videos against requirements"
        );
        
        let validator = VideoValidator::new(params.validation_config.clone());
        let mut validation_errors = Vec::new();
        
        for video in &videos {
            match validator.validate(&video.path).await {
                Ok(metadata) => {
                    info!(
                        job_id = %job_id,
                        video = %video.filename,
                        width = metadata.resolution.width,
                        height = metadata.resolution.height,
                        frames = metadata.frame_count,
                        duration = metadata.duration_secs,
                        "Video passed validation"
                    );
                },
                Err(e) => {
                    error!(
                        job_id = %job_id,
                        video = %video.filename,
                        error = %e,
                        "Video failed validation"
                    );
                    validation_errors.push(format!("{}: {}", video.filename, e));
                }
            }
        }
        
        if !validation_errors.is_empty() {
            anyhow::bail!(
                "Video validation failed ({} errors):\n{}",
                validation_errors.len(),
                validation_errors.join("\n")
            );
        }
        
        info!(
            job_id = %job_id,
            "All {} videos passed validation",
            videos.len()
        );

        progress.set_video_count(videos.len())?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
    }

    // Re-discover videos for processing (needed if resuming from checkpoint)
    let videos = discover_videos(input_folder)?;

    // Step 2: Extract frames from all videos concurrently
    let frame_sets = if progress.stage() == ProcessingStage::FrameExtraction {
        info!(job_id = %job_id, "Step 2: Extracting frames from videos");
        let extraction_options = ExtractionOptions::from_env_config(None, None);
        let sets = process_videos(videos.clone(), extraction_options)
            .await
            .context("Failed to extract frames from videos")?;

        let total_frames: usize = sets.iter().map(|fs| fs.frame_count).sum();
        info!(
            job_id = %job_id,
            total_frames = total_frames,
            "Extracted {} total frames",
            total_frames
        );

        progress.set_total_frames(total_frames)?;
        progress.set_frame_cache(sets.clone())?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        sets
    } else {
        info!(job_id = %job_id, "Step 2: Checking for cached frame extraction");
        // Try to use cached frame sets if available and valid
        match progress.get_cached_frames()? {
            Some(cached_sets) => {
                info!(
                    job_id = %job_id,
                    frame_count = cached_sets.iter().map(|fs| fs.frame_count).sum::<usize>(),
                    "Using cached frames, skipping re-extraction"
                );
                cached_sets
            }
            None => {
                info!(job_id = %job_id, "Cache invalid or missing, re-extracting frames");
                let extraction_options = ExtractionOptions::from_env_config(None, None);
                let sets = process_videos(videos.clone(), extraction_options).await?;
                progress.set_frame_cache(sets.clone())?;
                sets
            }
        }
    };

    // Step 3: Extract metadata from all videos
    let metadata = if progress.stage() == ProcessingStage::MetadataExtraction {
        info!(job_id = %job_id, "Step 3: Extracting metadata from videos");
        let meta = extract_metadata_batch(&videos)
            .await
            .context("Failed to extract metadata from videos")?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        meta
    } else {
        info!(job_id = %job_id, "Step 3: Skipping metadata extraction (already completed)");
        extract_metadata_batch(&videos).await?
    };

    // Step 4: Generate manifest
    let manifest_path = if progress.stage() == ProcessingStage::ManifestGeneration {
        info!(job_id = %job_id, "Step 4: Generating manifest");
        let manifest = generate_manifest(job_id.to_string(), &metadata, &frame_sets, input_folder)
            .context("Failed to generate manifest")?;

        let manifest_path = output_folder.join("manifest.json");
        std::fs::create_dir_all(output_folder).context("Failed to create output directory")?;

        let manifest_json =
            serde_json::to_string_pretty(&manifest).context("Failed to serialize manifest")?;
        std::fs::write(&manifest_path, manifest_json).context("Failed to write manifest file")?;

        info!(
            job_id = %job_id,
            manifest_path = %manifest_path.display(),
            "Manifest written"
        );

        progress.set_manifest_path(manifest_path.clone())?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        manifest_path
    } else {
        info!(job_id = %job_id, "Step 4: Skipping manifest generation (already completed)");
        progress.completed_stages().manifest_path.clone().unwrap_or_else(|| output_folder.join("manifest.json"))
    };

    // Step 5: Run reconstruction (COLMAP or alternative backend)
    let sparse_output_dir = if progress.stage() == ProcessingStage::ColmapReconstruction {
        info!(job_id = %job_id, "Step 5: Running reconstruction");
        
        // Get reconstruction backend (from env var or default to COLMAP)
        let reconstruction_backend = get_reconstruction_backend(None)
            .context("Failed to get reconstruction backend")?;
        
        info!(
            job_id = %job_id,
            backend = %reconstruction_backend.name(),
            "Using reconstruction backend: {}",
            reconstruction_backend.name()
        );
        
        let reconstruction_work_dir = temp_folder.join("colmap");
        std::fs::create_dir_all(&reconstruction_work_dir).context("Failed to create reconstruction work directory")?;

        // Collect all frame paths from all videos
        let image_dir = temp_folder.join("images");
        std::fs::create_dir_all(&image_dir).context("Failed to create frames directory")?;

        // Copy or link frames to single directory for reconstruction
        copy_frames_to_colmap_dir(&frame_sets, &image_dir)
            .context("Failed to prepare frames for reconstruction")?;

        let output_dir = reconstruction_work_dir.clone();

        // Build reconstruction config — honour COLMAP_MATCHER env var
        let colmap_matcher = std::env::var("COLMAP_MATCHER")
            .unwrap_or_else(|_| "exhaustive".to_string());
        let colmap_camera_model = std::env::var("COLMAP_CAMERA_MODEL")
            .unwrap_or_else(|_| "OPENCV".to_string());
        let reconstruction_config = serde_json::json!({
            "matcher": colmap_matcher,
            "camera_model": colmap_camera_model
        });

        let reconstruction_output = reconstruction_backend
            .reconstruct(&image_dir, &output_dir, &reconstruction_config)
            .await
            .context("Reconstruction failed")?;

        // Validate reconstruction quality
        reconstruction_backend
            .validate_output(&reconstruction_output)
            .context("Reconstruction validation failed")?;

        info!(
            job_id = %job_id,
            total_points = reconstruction_output.stats.total_points,
            registered_images = reconstruction_output.stats.registered_images,
            backend = %reconstruction_output.stats.backend_name,
            "Reconstruction completed with {} points from {} images",
            reconstruction_output.stats.total_points,
            reconstruction_output.stats.registered_images
        );

        progress.set_colmap_sparse_path(
            reconstruction_output.output_dir.clone(),
            reconstruction_output.stats.total_points
        )?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        reconstruction_output.output_dir
    } else {
        info!(job_id = %job_id, "Step 5: Skipping reconstruction (already completed)");
        progress.completed_stages().colmap_sparse_path.clone().unwrap_or_else(|| temp_folder.join("colmap"))
    };

    // Step 6: Train 3DGS model
    let model_output = if progress.stage() == ProcessingStage::Training {
        info!(job_id = %job_id, "Step 6: Training 3DGS model");

        // Read frame paths from image_dir so gsplat backend derives the correct
        // workspace (image_dir.parent() = temp_folder) and finds colmap/sparse/0
        let mut frame_paths: Vec<PathBuf> = std::fs::read_dir(&temp_folder.join("images"))
            .context("Failed to read image dir for training")?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jpg"))
            .collect();
        frame_paths.sort();

        let frame_path_refs: Vec<&Path> = frame_paths.iter().map(|p| p.as_path()).collect();

        let output = backend
            .train(&frame_path_refs, training_config)
            .await
            .context("3DGS training failed")?;

        info!(
            job_id = %job_id,
            gaussian_count = output.gaussian_count.unwrap_or(0),
            "Training completed with {} Gaussians",
            output.gaussian_count.unwrap_or(0)
        );

        progress.set_gaussian_count(output.gaussian_count.unwrap_or(0))?;
        progress.set_model_output(output.clone())?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        output
    } else {
        info!(job_id = %job_id, "Step 6: Checking for cached trained model");
        // Try to use cached model if available
        if let Some(cached_model) = progress.get_cached_model() {
            info!(
                job_id = %job_id,
                model_path = %cached_model.model_path.display(),
                gaussian_count = cached_model.gaussian_count.unwrap_or(0),
                "Using cached trained model, skipping re-training"
            );
            cached_model.clone()
        } else {
            info!(job_id = %job_id, "No valid cached model found, re-training");
            let mut frame_paths: Vec<PathBuf> = std::fs::read_dir(&temp_folder.join("images"))
                .context("Failed to read image dir for re-training")?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jpg"))
                .collect();
            frame_paths.sort();
            let frame_path_refs: Vec<&Path> = frame_paths.iter().map(|p| p.as_path()).collect();
            let output = backend.train(&frame_path_refs, training_config).await?;
            progress.set_model_output(output.clone())?;
            output
        }
    };

    // Step 7: Export to PLY
    let ply_path = if progress.stage() == ProcessingStage::PlyExport {
        info!(job_id = %job_id, "Step 7: Exporting to PLY format");
        let path = output_folder.join(format!("{}.ply", job_id));
        backend
            .export_ply(&model_output, &path)
            .await
            .context("Failed to export PLY")?;

        info!(
            job_id = %job_id,
            ply_path = %path.display(),
            "PLY export completed"
        );

        progress.set_ply_path(path.clone())?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        path
    } else {
        info!(job_id = %job_id, "Step 7: Skipping PLY export (already completed)");
        progress.completed_stages().ply_path.clone().unwrap_or_else(|| output_folder.join(format!("{}.ply", job_id)))
    };

    // Step 8: Export to SPLAT
    let splat_path = if progress.stage() == ProcessingStage::SplatExport {
        info!(job_id = %job_id, "Step 8: Exporting to SPLAT format");
        let path = output_folder.join(format!("{}.splat", job_id));
        backend
            .export_splat(&model_output, &path)
            .await
            .context("Failed to export SPLAT")?;

        info!(
            job_id = %job_id,
            splat_path = %path.display(),
            "SPLAT export completed"
        );

        progress.set_splat_path(path.clone())?;
        progress.complete_stage()?;
        update_health(progress, health_state, job_start_time).await;
        path
    } else {
        info!(job_id = %job_id, "Step 8: Skipping SPLAT export (already completed)");
        progress.completed_stages().splat_path.clone().unwrap_or_else(|| output_folder.join(format!("{}.splat", job_id)))
    };

    // Mark job as completed
    progress.finalize()?;

    // Return outputs
    Ok(JobOutputs {
        ply_path,
        splat_path,
        manifest_path,
        colmap_sparse_path: sparse_output_dir,
    })
}

/// Discover video files in a folder
///
/// Searches for common video file extensions (.mp4, .mov, .avi, .mkv)
fn discover_videos(folder: &Path) -> Result<Vec<VideoInput>> {
    if !folder.exists() {
        anyhow::bail!("Input folder does not exist: {}", folder.display());
    }

    if !folder.is_dir() {
        anyhow::bail!("Input path is not a directory: {}", folder.display());
    }

    let video_extensions = ["mp4", "mov", "avi", "mkv", "MP4", "MOV", "AVI", "MKV"];
    let mut videos = Vec::new();

    for entry in std::fs::read_dir(folder)
        .with_context(|| format!("Failed to read directory: {}", folder.display()))?
    {
        let entry = entry?;
        let path = entry.path();

        if path.is_file() {
            if let Some(extension) = path.extension() {
                if video_extensions.contains(&extension.to_str().unwrap_or("")) {
                    let filename = path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("unknown")
                        .to_string();

                    videos.push(VideoInput { path, filename });
                }
            }
        }
    }

    Ok(videos)
}

/// Extract metadata from multiple videos
async fn extract_metadata_batch(videos: &[VideoInput]) -> Result<Vec<VideoMetadata>> {
    let mut metadata = Vec::new();

    for video in videos {
        let meta = extract_metadata(video).await.with_context(|| {
            format!("Failed to extract metadata from: {}", video.path.display())
        })?;
        metadata.push(meta);
    }

    Ok(metadata)
}

/// Copy frames to a single directory for COLMAP processing
///
/// COLMAP expects all frames in a single directory
fn copy_frames_to_colmap_dir(frame_sets: &[FrameSet], output_dir: &Path) -> Result<()> {
    for (video_idx, frame_set) in frame_sets.iter().enumerate() {
        for (frame_idx, frame_path) in frame_set.frame_paths.iter().enumerate() {
            // Create unique filename: video{idx}_frame{num}.jpg
            let new_filename = format!("video{:02}_frame{:06}.jpg", video_idx, frame_idx);
            let dest_path = output_dir.join(new_filename);

            std::fs::copy(frame_path, &dest_path).with_context(|| {
                format!(
                    "Failed to copy frame from {} to {}",
                    frame_path.display(),
                    dest_path.display()
                )
            })?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_discover_videos_empty_folder() {
        let temp_dir = tempfile::tempdir().unwrap();
        let videos = discover_videos(temp_dir.path()).unwrap();
        assert_eq!(videos.len(), 0);
    }

    #[test]
    fn test_discover_videos_with_videos() {
        let temp_dir = tempfile::tempdir().unwrap();

        // Create dummy video files
        std::fs::write(temp_dir.path().join("video1.mp4"), b"fake video").unwrap();
        std::fs::write(temp_dir.path().join("video2.mov"), b"fake video").unwrap();
        std::fs::write(temp_dir.path().join("not-a-video.txt"), b"text").unwrap();

        let videos = discover_videos(temp_dir.path()).unwrap();
        assert_eq!(videos.len(), 2);
    }

    #[test]
    fn test_discover_videos_nonexistent_folder() {
        let result = discover_videos(Path::new("/nonexistent/path"));
        assert!(result.is_err());
    }

    #[test]
    fn test_job_result_success() {
        let result = JobResult {
            job_id: "test-job".to_string(),
            status: JobStatus::Success,
            duration_secs: 123.45,
            outputs: Some(JobOutputs {
                ply_path: PathBuf::from("/output/model.ply"),
                splat_path: PathBuf::from("/output/model.splat"),
                manifest_path: PathBuf::from("/output/manifest.json"),
                colmap_sparse_path: PathBuf::from("/work/sparse"),
            }),
            error: None,
        };

        assert_eq!(result.status, JobStatus::Success);
        assert!(result.outputs.is_some());
        assert!(result.error.is_none());
    }

    #[test]
    fn test_job_result_failed() {
        let result = JobResult {
            job_id: "test-job".to_string(),
            status: JobStatus::Failed,
            duration_secs: 10.5,
            outputs: None,
            error: Some("Something went wrong".to_string()),
        };

        assert_eq!(result.status, JobStatus::Failed);
        assert!(result.outputs.is_none());
        assert!(result.error.is_some());
    }
}
