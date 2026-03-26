mod metrics;
mod redact;

pub use metrics::{
    log_colmap_complete, log_export_complete, log_frame_extraction_complete, log_job_complete,
    log_job_started, log_training_complete,
};
pub use redact::{check_for_credentials, redact_credentials};

use anyhow::{Context, Result};
use std::fmt;
use std::io::IsTerminal;
use tracing_subscriber::fmt::format::Writer;
use tracing_subscriber::fmt::time::FormatTime;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

/// Custom time formatter that outputs [YYYY-MM-DDTHH:MM:SSZ] format to match PRD
struct BracketedUtcTime;

impl FormatTime for BracketedUtcTime {
    fn format_time(&self, w: &mut Writer<'_>) -> fmt::Result {
        let now = chrono::Utc::now();
        write!(w, "[{}]", now.format("%Y-%m-%dT%H:%M:%SZ"))
    }
}

/// Initialize tracing-subscriber with environment-based configuration
/// Output format matches PRD Section 12.2: [2026-02-11T20:15:00Z] INFO message field=value
///
/// Log level is configured via LOG_LEVEL environment variable (defaults to "info")
/// Supports values: trace, debug, info, warn, error
pub fn init() -> Result<()> {
    // Check LOG_LEVEL first (PRD requirement), then fall back to RUST_LOG, then default to "info"
    let log_level = std::env::var("LOG_LEVEL")
        .or_else(|_| std::env::var("RUST_LOG"))
        .unwrap_or_else(|_| "info".to_string());

    let filter = EnvFilter::try_new(&log_level).context("Invalid log level")?;

    // Disable ANSI color codes when stdout is not a terminal (e.g., containers, log aggregators)
    let use_ansi = std::io::stdout().is_terminal();

    tracing_subscriber::registry()
        .with(filter)
        .with(
            tracing_subscriber::fmt::layer()
                .with_target(false)
                .with_thread_ids(false)
                .with_file(false)
                .with_line_number(false)
                .with_timer(BracketedUtcTime)
                .with_ansi(use_ansi)
                .compact(),
        )
        .init();

    Ok(())
}
