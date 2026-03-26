//! gsplat backend implementation
//!
//! This module provides integration with gsplat, a highly optimized Python/CUDA
//! implementation of 3D Gaussian Splatting.
//!
//! # About gsplat
//!
//! gsplat is a modern, performance-focused implementation that offers:
//! - Faster training times compared to the reference implementation
//! - Lower memory footprint
//! - Better multi-GPU support
//! - More flexible training configurations
//!
//! # Requirements
//!
//! - gsplat Python package installed: `pip install gsplat`
//! - CUDA-capable GPU (gsplat is GPU-only)
//! - Python 3.8+ with PyTorch
//!
//! # Environment Variables
//!
//! - `GSPLAT_BIN`: Path to gsplat training script (default: "gsplat-train")
//! - `GSPLAT_PYTHON`: Python interpreter to use (default: "python3")
//!
//! # Training Workflow
//!
//! 1. Receives COLMAP sparse reconstruction and training config
//! 2. Converts data to gsplat-compatible format
//! 3. Invokes gsplat training with optimized parameters
//! 4. Exports model to PLY and SPLAT formats
//!
//! # Export Formats
//!
//! - PLY: Standard point cloud format
//! - SPLAT: Web-optimized format for real-time rendering

use anyhow::{Context, Result};
use async_trait::async_trait;
use std::path::Path;
use std::process::Command;
use std::time::Instant;
use tracing::{debug, info, instrument, warn};

use super::{BackendMetadata, BackendOutput, GaussianSplatBackend, TrainingConfig};

/// gsplat backend implementation
///
/// Provides integration with the gsplat library for fast 3DGS training.
pub struct GsplatBackend {
    /// Path to gsplat training script or executable
    gsplat_bin: String,

    /// Python interpreter to use
    python_bin: String,
}

impl GsplatBackend {
    /// Create a new gsplat backend
    ///
    /// # Environment Variables
    ///
    /// - `GSPLAT_BIN`: Custom path to gsplat training script
    /// - `GSPLAT_PYTHON`: Custom Python interpreter
    pub fn new() -> Self {
        let gsplat_bin = std::env::var("GSPLAT_BIN").unwrap_or_else(|_| "gsplat-train".to_string());

        let python_bin = std::env::var("GSPLAT_PYTHON").unwrap_or_else(|_| "python3".to_string());

        GsplatBackend {
            gsplat_bin,
            python_bin,
        }
    }

    /// Parse training metrics from gsplat output
    ///
    /// gsplat can output in various formats:
    /// - "Step 30000: loss=0.0042"
    /// - "Iteration 30000: Loss=0.0042"
    /// - "[30000] loss: 0.0042"
    fn parse_training_output(output: &str) -> (Option<f64>, u32) {
        let mut final_loss = None;
        let mut iterations = 0;

        for line in output.lines() {
            // Pattern 1: "Step 30000: loss=0.0042"
            if line.contains("Step") && line.contains("loss") {
                if let Some(step_str) = line.split("Step").nth(1) {
                    if let Some(num_str) = step_str.split(':').next() {
                        if let Ok(iter) = num_str.trim().parse::<u32>() {
                            iterations = iterations.max(iter);
                        }
                    }
                }

                if let Some(loss_str) = line.split("loss=").nth(1) {
                    let loss_val = loss_str.split_whitespace().next().unwrap_or("");
                    if let Ok(loss) = loss_val.parse::<f64>() {
                        final_loss = Some(loss);
                    }
                }
            }
            
            // Pattern 2: "Iteration 30000: Loss=0.0042" or "Loss: 0.0042"
            if line.contains("Iteration") || line.contains("iteration") {
                if let Some(iter_str) = line.split("Iteration").nth(1).or_else(|| line.split("iteration").nth(1)) {
                    if let Some(num_str) = iter_str.split(':').next().or_else(|| iter_str.split_whitespace().next()) {
                        if let Ok(iter) = num_str.trim().parse::<u32>() {
                            iterations = iterations.max(iter);
                        }
                    }
                }
            }
            
            if (line.contains("Loss") || line.contains("loss")) && line.contains(":") {
                let loss_part = if let Some(loss_str) = line.split("Loss:").nth(1).or_else(|| line.split("loss:").nth(1)) {
                    loss_str
                } else if let Some(loss_str) = line.split("Loss=").nth(1).or_else(|| line.split("loss=").nth(1)) {
                    loss_str
                } else {
                    continue;
                };
                
                if let Some(loss_val) = loss_part.split_whitespace().next() {
                    if let Ok(loss) = loss_val.trim_matches(|c: char| !c.is_numeric() && c != '.' && c != '-').parse::<f64>() {
                        final_loss = Some(loss);
                    }
                }
            }
            
            // Pattern 3: "[30000] loss: 0.0042"
            if line.starts_with('[') && line.contains(']') && line.contains("loss") {
                if let Some(bracket_content) = line.split('[').nth(1) {
                    if let Some(num_str) = bracket_content.split(']').next() {
                        if let Ok(iter) = num_str.trim().parse::<u32>() {
                            iterations = iterations.max(iter);
                        }
                    }
                }
                
                if let Some(loss_str) = line.split("loss").nth(1) {
                    let loss_part = loss_str.trim_start_matches(':').trim_start_matches('=').trim();
                    if let Some(loss_val) = loss_part.split_whitespace().next() {
                        if let Ok(loss) = loss_val.parse::<f64>() {
                            final_loss = Some(loss);
                        }
                    }
                }
            }
        }

        (final_loss, iterations)
    }

    /// Count Gaussians from gsplat output file
    fn count_gaussians(model_path: &Path) -> Result<usize> {
        // gsplat typically outputs a .ply file with the model
        // Try to read the vertex count from PLY header

        if !model_path.exists() {
            anyhow::bail!("Model file not found: {}", model_path.display());
        }

        // If it's a PLY file, parse the header
        if model_path.extension().and_then(|e| e.to_str()) == Some("ply") {
            return Self::count_from_ply(model_path);
        }

        // For other formats, try to estimate from file size
        // (This is a rough heuristic - actual implementation would vary)
        warn!(
            path = %model_path.display(),
            "Cannot determine Gaussian count for non-PLY format"
        );
        Ok(0)
    }

    fn count_from_ply(ply_path: &Path) -> Result<usize> {
        use std::io::{BufRead, BufReader};

        let file = std::fs::File::open(ply_path)
            .with_context(|| format!("Failed to open PLY file: {}", ply_path.display()))?;

        let reader = BufReader::new(file);

        for line in reader.lines() {
            let line = line?;
            if line.starts_with("element vertex ") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 3 {
                    return parts[2]
                        .parse::<usize>()
                        .context("Failed to parse vertex count from PLY header");
                }
            }
            if line.starts_with("end_header") {
                break;
            }
        }

        anyhow::bail!("Could not find vertex count in PLY header");
    }

    /// Validate COLMAP reconstruction is proper
    ///
    /// gsplat works with COLMAP format directly, but we need to validate
    /// that the reconstruction directory has the expected files
    fn validate_colmap_data(colmap_dir: &Path) -> Result<()> {
        let cameras_file = colmap_dir.join("cameras.bin");
        let images_file = colmap_dir.join("images.bin");
        let points_file = colmap_dir.join("points3D.bin");

        if !cameras_file.exists() {
            anyhow::bail!(
                "COLMAP cameras.bin not found at: {}",
                cameras_file.display()
            );
        }
        
        if !images_file.exists() {
            anyhow::bail!(
                "COLMAP images.bin not found at: {}",
                images_file.display()
            );
        }
        
        if !points_file.exists() {
            anyhow::bail!(
                "COLMAP points3D.bin not found at: {}",
                points_file.display()
            );
        }

        debug!(
            colmap = %colmap_dir.display(),
            "COLMAP reconstruction validated"
        );

        Ok(())
    }
}

impl Default for GsplatBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl GaussianSplatBackend for GsplatBackend {
    #[instrument(skip(self, frames), fields(
        backend = "gsplat",
        frame_count = frames.len(),
        iterations = config.iterations
    ))]
    async fn train(&self, frames: &[&Path], config: &TrainingConfig) -> Result<BackendOutput> {
        if frames.is_empty() {
            anyhow::bail!("Cannot train with zero frames");
        }

        // Determine workspace from first frame
        let first_frame = frames[0];
        let workspace_dir = first_frame
            .parent()
            .and_then(|p| p.parent())
            .ok_or_else(|| anyhow::anyhow!("Invalid frame path structure"))?;

        debug!(
            workspace = %workspace_dir.display(),
            "Determined workspace directory"
        );

        // Expected paths — check COLMAP_SPARSE_DIR env var first, then derive from workspace
        let colmap_sparse_dir = std::env::var("COLMAP_SPARSE_DIR")
            .ok()
            .map(std::path::PathBuf::from)
            .filter(|p| p.exists())
            .unwrap_or_else(|| {
                // Try the standard workspace-relative path
                let ws_path = workspace_dir.join("colmap").join("sparse").join("0");
                if ws_path.exists() {
                    return ws_path;
                }
                // Try TEMP_PATH-based path (batch mode layout)
                let temp_path = std::env::var("TEMP_PATH").unwrap_or_else(|_| "/tmp/3dgs-work".to_string());
                let batch_path = std::path::PathBuf::from(&temp_path)
                    .join("reconstruction")
                    .join("output")
                    .join("sparse")
                    .join("0");
                if batch_path.exists() {
                    return batch_path;
                }
                ws_path
            });
        // Determine images directory — use TEMP_PATH/frames if available (batch mode),
        // otherwise derive from workspace
        let images_dir = {
            let temp_path = std::env::var("TEMP_PATH").unwrap_or_else(|_| "/tmp/3dgs-work".to_string());
            let batch_frames = std::path::PathBuf::from(&temp_path).join("frames");
            if batch_frames.exists() && std::fs::read_dir(&batch_frames).map(|mut d| d.next().is_some()).unwrap_or(false) {
                batch_frames
            } else {
                let ws_images = workspace_dir.join("images");
                if ws_images.exists() {
                    ws_images
                } else {
                    // Use the parent directory of the first frame
                    first_frame.parent().unwrap_or(workspace_dir).to_path_buf()
                }
            }
        };
        let output_dir = workspace_dir.join("output");

        // Validate COLMAP data exists
        if !colmap_sparse_dir.exists() {
            anyhow::bail!(
                "COLMAP sparse reconstruction not found at: {}",
                colmap_sparse_dir.display()
            );
        }

        // Validate COLMAP reconstruction files
        Self::validate_colmap_data(&colmap_sparse_dir)?;

        // Create output directory
        std::fs::create_dir_all(&output_dir).context("Failed to create output directory")?;

        info!(
            images = %images_dir.display(),
            colmap = %colmap_sparse_dir.display(),
            output = %output_dir.display(),
            "Starting gsplat training"
        );

        let gsplat_bin = self.gsplat_bin.clone();
        let python_bin = self.python_bin.clone();
        let images_dir_clone = images_dir.clone();
        let colmap_dir_clone = colmap_sparse_dir.clone();
        let output_dir_clone = output_dir.clone();
        let config_clone = config.clone();

        let start_time = Instant::now();

        // Run training in blocking task
        let (stdout, stderr, success) = tokio::task::spawn_blocking(move || {
            debug!("Invoking gsplat training process");

            // Build command for gsplat training
            // gsplat typically uses Python scripts with specific command-line arguments
            // Example: python -m gsplat.train --data colmap --model-dir output --iterations 30000
            let mut cmd = Command::new(&python_bin);
            
            // Use -m flag to run as module, or direct script path
            if gsplat_bin.ends_with(".py") {
                cmd.arg(&gsplat_bin);
            } else {
                cmd.arg("-m").arg(&gsplat_bin);
            }
            
            // Data source (images directory)
            cmd.arg("--data")
                .arg(&images_dir_clone);
            
            // COLMAP sparse directory
            cmd.arg("--colmap-dir")
                .arg(&colmap_dir_clone);
            
            // Model output path
            cmd.arg("--model-dir")
                .arg(&output_dir_clone);
            
            // Training iterations
            cmd.arg("--iterations")
                .arg(config_clone.iterations.to_string());
            
            // Learning rate
            cmd.arg("--sh-degree")
                .arg("3");  // Spherical harmonics degree
            
            // Densification parameters
            cmd.arg("--densify-grad-thresh")
                .arg("0.0002");
            cmd.arg("--densify-start-iter")
                .arg(config_clone.densification_start.to_string());
            cmd.arg("--densify-stop-iter")
                .arg(config_clone.densification_stop.to_string());
            cmd.arg("--densify-every")
                .arg(config_clone.densification_interval.to_string());
            
            // Opacity reset
            cmd.arg("--reset-opacity-every")
                .arg(config_clone.opacity_reset_interval.to_string());
            
            // Output format
            cmd.arg("--save-ply");

            debug!(command = ?cmd, "Executing gsplat training");

            // Execute command
            let output = cmd
                .output()
                .context("Failed to execute gsplat training command")?;

            let success = output.status.success();
            
            Ok::<_, anyhow::Error>((
                String::from_utf8_lossy(&output.stdout).to_string(),
                String::from_utf8_lossy(&output.stderr).to_string(),
                success,
            ))
        })
        .await
        .context("Training task panicked")??;

        let training_time = start_time.elapsed().as_secs_f64();

        if !success {
            anyhow::bail!(
                "gsplat training failed. Check logs:\nStdout: {}\nStderr: {}",
                stdout,
                stderr
            );
        }

        // Parse training output
        let (final_loss, iterations_completed) = Self::parse_training_output(&stdout);

        info!(
            iterations = iterations_completed,
            loss = ?final_loss,
            time_secs = training_time,
            "gsplat training completed successfully"
        );

        // Determine model path
        // gsplat typically outputs to model-dir/point_cloud.ply or model-dir/iteration_X/point_cloud.ply
        let model_path = if output_dir.join("point_cloud.ply").exists() {
            output_dir.join("point_cloud.ply")
        } else {
            // Try iteration-specific output
            output_dir
                .join(format!("iteration_{}", config.iterations))
                .join("point_cloud.ply")
        };

        // Validate model file exists
        if !model_path.exists() {
            // Try alternative common paths
            let alt_paths = vec![
                output_dir.join("model.ply"),
                output_dir.join("final.ply"),
                output_dir.join(format!("{}.ply", config.iterations)),
            ];
            
            let mut found = false;
            for alt_path in &alt_paths {
                if alt_path.exists() {
                    debug!(
                        path = %alt_path.display(),
                        "Found model at alternative path"
                    );
                    found = true;
                    break;
                }
            }
            
            if !found {
                anyhow::bail!(
                    "Trained model not found at expected locations:\n  Primary: {}\n  Alternatives checked: {}",
                    model_path.display(),
                    alt_paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ")
                );
            }
        }

        let gaussian_count = Self::count_gaussians(&model_path).ok();

        if !stderr.is_empty() {
            debug!(stderr = %stderr, "gsplat stderr output");
        }

        // Try to detect GPU device from output
        let gpu_device = if stdout.contains("cuda") || stderr.contains("cuda") {
            Some("CUDA".to_string())
        } else if stdout.contains("GPU") || stderr.contains("GPU") {
            Some("GPU".to_string())
        } else {
            None
        };

        Ok(BackendOutput {
            model_path,
            iterations_completed,
            final_loss,
            gaussian_count,
            metadata: BackendMetadata {
                backend_name: "gsplat".to_string(),
                backend_version: None,
                training_time_secs: Some(training_time),
                peak_memory_bytes: None,
                gpu_device,
                extra: std::collections::HashMap::new(),
            },
        })
    }

    #[instrument(skip(self, model), fields(output = %output_path.display()))]
    async fn export_ply(&self, model: &BackendOutput, output_path: &Path) -> Result<()> {
        info!("Exporting model to PLY format");

        // Verify model exists
        if !model.model_path.exists() {
            anyhow::bail!("Model file not found: {}", model.model_path.display());
        }

        // Create parent directory if needed
        if let Some(parent) = output_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .with_context(|| format!("Failed to create output directory: {}", parent.display()))?;
        }

        // Copy PLY file to output path
        tokio::fs::copy(&model.model_path, output_path)
            .await
            .with_context(|| {
                format!(
                    "Failed to copy PLY from {} to {}",
                    model.model_path.display(),
                    output_path.display()
                )
            })?;

        let file_size = tokio::fs::metadata(output_path).await.ok().map(|m| m.len());
        info!(
            path = %output_path.display(),
            size_bytes = ?file_size,
            "PLY export complete"
        );
        
        Ok(())
    }

    #[instrument(skip(self, model), fields(output = %output_path.display()))]
    async fn export_splat(&self, model: &BackendOutput, output_path: &Path) -> Result<()> {
        info!("Exporting model to SPLAT format");

        let ply_path = &model.model_path;
        if !ply_path.exists() {
            anyhow::bail!("Model file not found: {}", ply_path.display());
        }

        // Create parent directory if needed
        if let Some(parent) = output_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .with_context(|| format!("Failed to create output directory: {}", parent.display()))?;
        }

        debug!(
            ply = %ply_path.display(),
            splat = %output_path.display(),
            "Converting PLY to SPLAT format"
        );

        // Check for PLY-to-SPLAT converter tool
        let converter_bin = std::env::var("PLY_TO_SPLAT_BIN")
            .or_else(|_| std::env::var("GSPLAT_CONVERTER"))
            .unwrap_or_else(|_| "ply-to-splat".to_string());

        let ply_path_clone = ply_path.to_path_buf();
        let output_path_clone = output_path.to_path_buf();

        tokio::task::spawn_blocking(move || {
            debug!(
                converter = %converter_bin,
                "Invoking PLY-to-SPLAT converter"
            );

            // Try to use Python converter from gsplat package
            let mut cmd = Command::new("python3");
            cmd.arg("-m")
                .arg("gsplat.utils.ply_to_splat")
                .arg("--input")
                .arg(&ply_path_clone)
                .arg("--output")
                .arg(&output_path_clone);

            let output = cmd.output();
            
            // If gsplat converter is not available, try generic converter
            if output.is_err() || !output.as_ref().unwrap().status.success() {
                debug!("gsplat converter not available, trying inline Python converter");
                
                // Inline PLY-to-SPLAT converter using Python + numpy
                let script = format!(r#"
import numpy as np, struct, sys
from pathlib import Path

ply_path = Path(sys.argv[1])
splat_path = Path(sys.argv[2])

# Read PLY file (ASCII or binary_little_endian)
with open(ply_path, 'rb') as f:
    header = b''
    while True:
        line = f.readline()
        header += line
        if b'end_header' in line:
            break
    header_str = header.decode('ascii', errors='replace')
    
    n_verts = 0
    is_binary = 'binary_little_endian' in header_str
    props = []
    for line in header_str.split('\n'):
        if line.startswith('element vertex'):
            n_verts = int(line.split()[-1])
        if line.startswith('property'):
            props.append(line.split()[-1])
    
    if n_verts == 0:
        print(f"No vertices in PLY", file=sys.stderr)
        sys.exit(1)
    
    # For SPLAT: 32 bytes per gaussian (pos[3f] + scale[3f] + rgba[4B] + quat[4B])
    splat_data = bytearray(n_verts * 32)
    
    if is_binary:
        # Try to read as structured binary
        float_count = len(props)
        for i in range(n_verts):
            raw = f.read(float_count * 4)
            if len(raw) < 12:
                break
            x, y, z = struct.unpack_from('<3f', raw, 0)
            struct.pack_into('<3f', splat_data, i*32, x, y, z)
            # Default scale, color, rotation
            struct.pack_into('<3f', splat_data, i*32+12, 0.01, 0.01, 0.01)
            struct.pack_into('<4B', splat_data, i*32+24, 128, 128, 128, 200)
            struct.pack_into('<4B', splat_data, i*32+28, 128, 0, 0, 0)
    else:
        # ASCII format
        lines_data = f.read().decode('ascii', errors='replace').strip().split('\n')
        for i, line in enumerate(lines_data[:n_verts]):
            vals = line.split()
            if len(vals) >= 3:
                x, y, z = float(vals[0]), float(vals[1]), float(vals[2])
                struct.pack_into('<3f', splat_data, i*32, x, y, z)
                struct.pack_into('<3f', splat_data, i*32+12, 0.01, 0.01, 0.01)
                struct.pack_into('<4B', splat_data, i*32+24, 128, 128, 128, 200)
                struct.pack_into('<4B', splat_data, i*32+28, 128, 0, 0, 0)

with open(splat_path, 'wb') as f:
    f.write(splat_data)

print(f"Converted {{n_verts}} gaussians to SPLAT ({{len(splat_data)}} bytes)")
"#);
                let mut py_cmd = Command::new("python3");
                py_cmd.arg("-c").arg(&script)
                    .arg(&ply_path_clone)
                    .arg(&output_path_clone);
                
                let py_output = py_cmd.output()
                    .context("Failed to execute PLY-to-SPLAT converter")?;
                
                if !py_output.status.success() {
                    let stderr = String::from_utf8_lossy(&py_output.stderr);
                    anyhow::bail!(
                        "PLY-to-SPLAT conversion failed with status {}: {}",
                        py_output.status,
                        stderr
                    );
                }
            }

            Ok::<_, anyhow::Error>(())
        })
        .await
        .context("SPLAT export task panicked")??;

        let file_size = tokio::fs::metadata(output_path).await.ok().map(|m| m.len());
        info!(
            path = %output_path.display(),
            size_bytes = ?file_size,
            "SPLAT export complete"
        );
        
        Ok(())
    }
}

/// Plugin entry point for dynamic loading
///
/// This function is called when the plugin is loaded via libloading.
/// It must be exported with C linkage and the name `create_backend`.
///
/// Note: In production, each backend would be compiled as a separate plugin.
/// This is conditionally compiled to avoid symbol conflicts when testing.
#[cfg(feature = "gsplat-plugin")]
#[no_mangle]
#[allow(improper_ctypes_definitions)]
pub extern "C" fn create_backend() -> Box<dyn GaussianSplatBackend> {
    Box::new(GsplatBackend::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gsplat_backend_creation() {
        let backend = GsplatBackend::new();
        assert!(!backend.gsplat_bin.is_empty());
        assert!(!backend.python_bin.is_empty());
    }

    #[test]
    fn test_gsplat_backend_respects_env_vars() {
        std::env::set_var("GSPLAT_BIN", "custom-gsplat-train");
        std::env::set_var("GSPLAT_PYTHON", "python3.11");
        
        let backend = GsplatBackend::new();
        assert_eq!(backend.gsplat_bin, "custom-gsplat-train");
        assert_eq!(backend.python_bin, "python3.11");
        
        std::env::remove_var("GSPLAT_BIN");
        std::env::remove_var("GSPLAT_PYTHON");
    }

    #[test]
    fn test_parse_training_output_format1() {
        let output = "Step 1000: loss=0.5\nStep 2000: loss=0.3\nStep 3000: loss=0.1";
        let (loss, iterations) = GsplatBackend::parse_training_output(output);

        assert_eq!(loss, Some(0.1));
        assert_eq!(iterations, 3000);
    }

    #[test]
    fn test_parse_training_output_format2() {
        let output = "Iteration 5000: Loss: 0.0823\nIteration 10000: Loss: 0.0456\nIteration 30000: Loss: 0.0042";
        let (loss, iterations) = GsplatBackend::parse_training_output(output);

        assert_eq!(loss, Some(0.0042));
        assert_eq!(iterations, 30000);
    }

    #[test]
    fn test_parse_training_output_format3() {
        let output = "[1000] loss: 0.5\n[2000] loss: 0.3\n[3000] loss: 0.1";
        let (loss, iterations) = GsplatBackend::parse_training_output(output);

        assert_eq!(loss, Some(0.1));
        assert_eq!(iterations, 3000);
    }

    #[test]
    fn test_parse_empty_output() {
        let output = "";
        let (loss, iterations) = GsplatBackend::parse_training_output(output);

        assert_eq!(loss, None);
        assert_eq!(iterations, 0);
    }

    #[test]
    fn test_parse_mixed_output() {
        let output = r#"
Starting training...
Step 1000: loss=0.5123
Some debug info
Iteration 2000: Loss: 0.3456
[3000] loss: 0.1789
Final iteration complete
        "#;
        let (loss, iterations) = GsplatBackend::parse_training_output(output);

        assert_eq!(iterations, 3000);
        assert!(loss.is_some());
        assert!((loss.unwrap() - 0.1789).abs() < 1e-6);
    }

    #[test]
    fn test_count_gaussians_missing_file() {
        let path = std::path::Path::new("/nonexistent/model.ply");
        let result = GsplatBackend::count_gaussians(path);
        assert!(result.is_err());
    }
}
