//! COLMAP command execution
//!
//! This module handles running COLMAP commands for feature extraction,
//! matching, and sparse reconstruction. All commands are wrapped in
//! spawn_blocking since COLMAP does synchronous I/O.

use anyhow::{Context, Result};
use std::path::Path;
use std::process::Command;
use tracing::{debug, info, instrument};

use super::models::MatcherType;

/// COLMAP command runner
pub struct ColmapRunner {
    /// Path to COLMAP executable
    colmap_bin: String,
    /// Whether to use GPU for SIFT extraction and matching.
    /// When false, passes `--SiftExtraction.use_gpu 0` and `--SiftMatching.use_gpu 0`
    /// to force CPU-only operation (headless-safe, no OpenGL context required).
    use_gpu: bool,
}

impl ColmapRunner {
    /// Create a new COLMAP runner
    ///
    /// Reads `COLMAP_BIN` env var for the executable path (default: `"colmap"`).
    /// Reads `COLMAP_USE_CPU` env var: if set to any value, forces CPU-only mode
    /// for SIFT feature extraction and matching (no GPU/OpenGL required).
    /// This is independent of GPU detection for the rest of the pipeline.
    pub fn new() -> Self {
        let colmap_bin = std::env::var("COLMAP_BIN").unwrap_or_else(|_| "colmap".to_string());
        let use_gpu = std::env::var("COLMAP_USE_CPU").is_err();

        if !use_gpu {
            info!("COLMAP_USE_CPU is set — COLMAP will run in CPU-only mode (headless-safe)");
        }

        ColmapRunner {
            colmap_bin,
            use_gpu,
        }
    }

    /// Extract features from images
    ///
    /// Runs: colmap feature_extractor --database_path X --image_path Y --ImageReader.camera_model Z
    #[instrument(skip(self), fields(colmap_bin = %self.colmap_bin, use_gpu = %self.use_gpu))]
    pub async fn extract_features(
        &self,
        image_dir: &Path,
        database_path: &Path,
        camera_model: &str,
    ) -> Result<()> {
        let colmap_bin = self.colmap_bin.clone();
        let image_dir = image_dir.to_path_buf();
        let database_path = database_path.to_path_buf();
        let camera_model = camera_model.to_string();
        let use_gpu = self.use_gpu;

        tokio::task::spawn_blocking(move || {
            debug!(
                "Running feature extraction: {} images, camera model {}, use_gpu={}",
                image_dir.display(),
                camera_model,
                use_gpu
            );

            let mut cmd = Command::new(&colmap_bin);
            cmd.arg("feature_extractor")
                .arg("--database_path")
                .arg(&database_path)
                .arg("--image_path")
                .arg(&image_dir)
                .arg("--ImageReader.camera_model")
                .arg(&camera_model)
                .arg("--SiftExtraction.use_gpu")
                .arg(if use_gpu { "1" } else { "0" });

            // Limit max features per image if configured (speeds up matching)
            if let Ok(max_features) = std::env::var("COLMAP_MAX_NUM_FEATURES") {
                cmd.arg("--SiftExtraction.max_num_features")
                    .arg(&max_features);
            }

            let output = cmd
                .output()
                .context("Failed to execute COLMAP feature_extractor")?;

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                anyhow::bail!(
                    "COLMAP feature extraction failed with status {}: {}",
                    output.status,
                    stderr
                );
            }

            info!("COLMAP feature extraction completed successfully");
            Ok(())
        })
        .await
        .context("Feature extraction task panicked")??;

        Ok(())
    }

    /// Match features between images
    ///
    /// Runs appropriate matcher based on MatcherType:
    /// - Exhaustive: colmap exhaustive_matcher --database_path X
    /// - Sequential: colmap sequential_matcher --database_path X
    /// - VocabTree: colmap vocab_tree_matcher --database_path X --VocabTreeMatching.vocab_tree_path Y
    #[instrument(skip(self), fields(colmap_bin = %self.colmap_bin, use_gpu = %self.use_gpu))]
    pub async fn match_features(&self, database_path: &Path, matcher: MatcherType) -> Result<()> {
        let colmap_bin = self.colmap_bin.clone();
        let database_path = database_path.to_path_buf();
        let use_gpu = self.use_gpu;

        tokio::task::spawn_blocking(move || {
            debug!("Running {:?} matcher, use_gpu={}", matcher, use_gpu);

            let matcher_command = match matcher {
                MatcherType::Exhaustive => "exhaustive_matcher",
                MatcherType::Sequential => "sequential_matcher",
                MatcherType::VocabTree => "vocab_tree_matcher",
            };

            let mut cmd = Command::new(&colmap_bin);
            cmd.arg(matcher_command)
                .arg("--database_path")
                .arg(&database_path)
                .arg("--SiftMatching.use_gpu")
                .arg(if use_gpu { "1" } else { "0" });

            // For vocab tree matcher, add vocab tree path if available
            if matcher == MatcherType::VocabTree {
                if let Ok(vocab_tree_path) = std::env::var("COLMAP_VOCAB_TREE_PATH") {
                    cmd.arg("--VocabTreeMatching.vocab_tree_path")
                        .arg(vocab_tree_path);
                }
            }

            let output = cmd
                .output()
                .context("Failed to execute COLMAP feature matcher")?;

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                anyhow::bail!(
                    "COLMAP {:?} matching failed with status {}: {}",
                    matcher,
                    output.status,
                    stderr
                );
            }

            info!(
                "COLMAP feature matching ({:?}) completed successfully",
                matcher
            );
            Ok(())
        })
        .await
        .context("Feature matching task panicked")??;

        Ok(())
    }

    /// Run sparse reconstruction (mapper)
    ///
    /// Runs: colmap mapper --database_path X --image_path Y --output_path Z
    #[instrument(skip(self), fields(colmap_bin = %self.colmap_bin))]
    pub async fn sparse_reconstruction(
        &self,
        database_path: &Path,
        image_dir: &Path,
        output_dir: &Path,
    ) -> Result<()> {
        let colmap_bin = self.colmap_bin.clone();
        let database_path = database_path.to_path_buf();
        let image_dir = image_dir.to_path_buf();
        let output_dir = output_dir.to_path_buf();

        tokio::task::spawn_blocking(move || {
            debug!(
                "Running sparse reconstruction, output to {}",
                output_dir.display()
            );

            // Ensure output directory exists
            std::fs::create_dir_all(&output_dir)
                .context("Failed to create COLMAP output directory")?;

            let output = Command::new(&colmap_bin)
                .arg("mapper")
                .arg("--database_path")
                .arg(&database_path)
                .arg("--image_path")
                .arg(&image_dir)
                .arg("--output_path")
                .arg(&output_dir)
                .output()
                .context("Failed to execute COLMAP mapper")?;

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                anyhow::bail!(
                    "COLMAP sparse reconstruction failed with status {}: {}",
                    output.status,
                    stderr
                );
            }

            info!("COLMAP sparse reconstruction completed successfully");
            Ok(())
        })
        .await
        .context("Sparse reconstruction task panicked")??;

        Ok(())
    }
}

impl Default for ColmapRunner {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_colmap_runner_creation() {
        let runner = ColmapRunner::new();
        assert!(!runner.colmap_bin.is_empty());
    }

    #[test]
    fn test_colmap_runner_respects_env_var() {
        std::env::set_var("COLMAP_BIN", "/custom/path/to/colmap");
        let runner = ColmapRunner::new();
        assert_eq!(runner.colmap_bin, "/custom/path/to/colmap");
        std::env::remove_var("COLMAP_BIN");
    }

    #[test]
    fn test_colmap_runner_gpu_default() {
        std::env::remove_var("COLMAP_USE_CPU");
        let runner = ColmapRunner::new();
        assert!(runner.use_gpu, "GPU should be enabled by default");
    }

    #[test]
    fn test_colmap_runner_cpu_mode() {
        std::env::set_var("COLMAP_USE_CPU", "1");
        let runner = ColmapRunner::new();
        assert!(!runner.use_gpu, "GPU should be disabled when COLMAP_USE_CPU is set");
        std::env::remove_var("COLMAP_USE_CPU");
    }
}
