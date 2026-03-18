//! 3DGS Preflight Check
//!
//! Standalone binary that detects GPU capabilities and validates whether a
//! desired backend can run in the current environment. Designed to be run
//! before long-running training jobs to catch misconfigurations early.
//!
//! # Usage
//!
//! ```text
//! # Auto-detect and report GPU/backend info
//! 3dgs-preflight
//!
//! # Verify a specific backend is usable
//! 3dgs-preflight --expect gsplat
//!
//! # Check via environment variable
//! BACKEND=gsplat 3dgs-preflight
//! ```
//!
//! # Exit Codes
//!
//! - 0: Preflight passed (detected environment satisfies the expected backend)
//! - 1: Preflight failed (environment cannot satisfy the expected backend)
//! - 2: Invalid arguments

use std::process::ExitCode;
use three_dgs_processor::backends::{detect_gpu, gpu_status_string, BackendRegistry, GpuInfo};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let expected_backend = parse_expected_backend(&args);

    if args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("3dgs-preflight {VERSION}");
        return ExitCode::SUCCESS;
    }

    println!("╔══════════════════════════════════════════════════════════╗");
    println!("║           3DGS Preflight Environment Check              ║");
    println!("╚══════════════════════════════════════════════════════════╝");
    println!();

    // --- GPU detection ---
    let gpu_info = detect_gpu();
    print_gpu_report(&gpu_info);

    // --- Backend resolution ---
    let resolved = BackendRegistry::resolve_backend_name(None);
    println!("Backend Resolution");
    println!("──────────────────");
    println!("  Resolved backend : {resolved}");
    if let Ok(val) = std::env::var("BACKEND") {
        println!("  BACKEND env var  : {val}");
    }
    if std::env::var("FORCE_CPU_BACKEND").is_ok() {
        println!("  FORCE_CPU_BACKEND: set (forcing mock/CPU)");
    }
    if std::env::var("COLMAP_USE_CPU").is_ok() {
        println!("  COLMAP_USE_CPU   : set (COLMAP forced to CPU-only, headless-safe)");
    }
    println!();

    // --- External tool checks ---
    print_tool_checks();

    // --- Preflight verdict ---
    match expected_backend {
        Some(expected) => evaluate_expected(&expected, &gpu_info, &resolved),
        None => {
            println!("ℹ  No --expect flag or BACKEND env var set. Reporting detection only.");
            println!("   Recommended backend: {resolved}");
            ExitCode::SUCCESS
        }
    }
}

/// Parse the expected backend from CLI args or BACKEND env var.
fn parse_expected_backend(args: &[String]) -> Option<String> {
    // --expect <backend>
    for (i, arg) in args.iter().enumerate() {
        if (arg == "--expect" || arg == "-e") && i + 1 < args.len() {
            return Some(args[i + 1].clone());
        }
        if let Some(val) = arg.strip_prefix("--expect=") {
            return Some(val.to_string());
        }
    }

    // Fall back to BACKEND env var
    std::env::var("BACKEND").ok()
}

fn print_usage() {
    println!(
        "\
3dgs-preflight {VERSION} — GPU & backend preflight check

USAGE:
    3dgs-preflight [OPTIONS]

OPTIONS:
    -e, --expect <BACKEND>  Assert that this backend is usable (exit 1 if not)
    -h, --help              Print this help message
    -V, --version           Print version

ENVIRONMENT:
    BACKEND               Same as --expect (CLI flag takes precedence)
    FORCE_CPU_BACKEND     If set, forces mock/CPU backend selection
    COLMAP_USE_CPU        If set, forces COLMAP to CPU-only mode (headless-safe)

BACKENDS:
    gsplat                Requires CUDA GPU + Python + gsplat package
    gaussian-splatting    Requires CUDA, Metal, or ROCm GPU
    3dgs-cpp              Requires CUDA GPU
    mock                  No GPU required (testing only)

EXIT CODES:
    0  Preflight passed
    1  Preflight failed (environment cannot satisfy expected backend)
    2  Invalid arguments

EXAMPLES:
    3dgs-preflight                        # detect and report
    3dgs-preflight --expect gsplat        # fail if gsplat can't run
    BACKEND=gsplat 3dgs-preflight         # same via env var
"
    );
}

fn print_gpu_report(info: &GpuInfo) {
    println!("GPU Detection");
    println!("─────────────");
    println!("  {}", gpu_status_string(info));
    println!("  Platform   : {}", info.platform);
    if let Some(ref name) = info.device_name {
        println!("  Device     : {name}");
    }
    if let Some(vram) = info.vram_gb {
        println!("  VRAM       : {vram:.1} GB");
    }
    println!("  Usable     : {}", if info.is_usable { "yes" } else { "no" });
    println!("  Recommended: {}", info.recommend_backend());
    println!();
}

fn print_tool_checks() {
    println!("External Tools");
    println!("──────────────");
    check_tool("nvidia-smi", &["--version"]);
    check_tool("python3", &["--version"]);
    check_tool("ffmpeg", &["-version"]);
    check_tool("colmap", &["help"]);
    check_gsplat_package();
    println!();
}

fn check_tool(name: &str, args: &[&str]) {
    match std::process::Command::new(name).args(args).output() {
        Ok(output) if output.status.success() => {
            let ver = String::from_utf8_lossy(&output.stdout);
            let first_line = ver.lines().next().unwrap_or("").trim();
            let display = if first_line.len() > 60 {
                &first_line[..60]
            } else {
                first_line
            };
            println!("  ✓ {name:<14} {display}");
        }
        _ => {
            println!("  ✗ {name:<14} not found");
        }
    }
}

fn check_gsplat_package() {
    let python = std::env::var("GSPLAT_PYTHON").unwrap_or_else(|_| "python3".to_string());
    match std::process::Command::new(&python)
        .args(["-c", "import gsplat; print(gsplat.__version__)"])
        .output()
    {
        Ok(output) if output.status.success() => {
            let ver = String::from_utf8_lossy(&output.stdout);
            println!("  ✓ gsplat         {}", ver.trim());
        }
        _ => {
            println!("  ✗ gsplat         not installed (python: {python})");
        }
    }
}

/// Evaluate whether the environment satisfies the expected backend.
fn evaluate_expected(expected: &str, gpu_info: &GpuInfo, resolved: &str) -> ExitCode {
    println!("Preflight Verdict");
    println!("─────────────────");
    println!("  Expected backend: {expected}");
    println!("  Resolved backend: {resolved}");
    println!();

    let mut failures: Vec<String> = Vec::new();

    match expected {
        "gsplat" => {
            if !gpu_info.has_cuda() {
                failures.push(format!(
                    "gsplat requires a CUDA GPU, but detected platform is: {}",
                    gpu_info.platform
                ));
            }
            if !is_tool_available("python3") {
                failures.push("gsplat requires python3, which is not found in PATH".to_string());
            } else if !is_gsplat_importable() {
                failures.push(
                    "gsplat Python package is not installed (pip install gsplat)".to_string(),
                );
            }
        }
        "gaussian-splatting" => {
            if !gpu_info.has_gpu() {
                failures.push(format!(
                    "gaussian-splatting requires a GPU (CUDA/Metal/ROCm), but detected: {}",
                    gpu_info.platform
                ));
            }
        }
        "3dgs-cpp" => {
            if !gpu_info.has_cuda() {
                failures.push(format!(
                    "3dgs-cpp requires a CUDA GPU, but detected platform is: {}",
                    gpu_info.platform
                ));
            }
        }
        "mock" => {
            // Mock always works
        }
        other => {
            // Unknown backend — check if it's a registered plugin
            let registry = BackendRegistry::default();
            if !registry.is_backend_available(other) {
                failures.push(format!(
                    "Backend '{other}' is not a known built-in or available plugin"
                ));
            }
        }
    }

    // Check FORCE_CPU_BACKEND conflict
    if std::env::var("FORCE_CPU_BACKEND").is_ok() && expected != "mock" {
        failures.push(format!(
            "FORCE_CPU_BACKEND is set, which forces 'mock' backend, \
             but you expect '{expected}'. Unset FORCE_CPU_BACKEND to use a real backend."
        ));
    }

    if failures.is_empty() {
        println!("  ✅ PREFLIGHT PASSED");
        println!("     Environment can run backend '{expected}'.");
        ExitCode::SUCCESS
    } else {
        println!("  ❌ PREFLIGHT FAILED");
        println!();
        for (i, reason) in failures.iter().enumerate() {
            println!("  {}. {reason}", i + 1);
        }
        println!();
        println!("  The environment cannot satisfy backend '{expected}'.");
        println!("  Resolve the issues above before starting training.");
        ExitCode::from(1)
    }
}

fn is_tool_available(name: &str) -> bool {
    std::process::Command::new(name)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn is_gsplat_importable() -> bool {
    let python = std::env::var("GSPLAT_PYTHON").unwrap_or_else(|_| "python3".to_string());
    std::process::Command::new(&python)
        .args(["-c", "import gsplat"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
