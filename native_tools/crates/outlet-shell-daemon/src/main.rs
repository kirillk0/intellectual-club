use std::env;

use anyhow::{anyhow, Result};
use clap::Parser;
use outlet_core::{OutletRunner, RunnerConfig};
use outlet_shell::ShellOutlet;
use tokio_util::sync::CancellationToken;
use tracing::warn;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "outlet-shell-daemon")]
#[command(about = "Headless shell outlet runner for Intellectual Club")]
struct Args {
    #[arg(long, env = "OUTLET_SERVER_URL")]
    server_url: Option<String>,

    #[arg(long, env = "OUTLET_TOKEN")]
    token: Option<String>,

    #[arg(long, env = "OUTLET_RUNNER_ID")]
    runner_id: Option<String>,

    #[arg(long, env = "OUTLET_LOG_LEVEL", default_value = "INFO")]
    log_level: String,

    #[arg(long, env = "OUTLET_MAX_CONCURRENCY", default_value_t = 20)]
    max_concurrency: usize,

    #[arg(long, env = "OUTLET_POLL_MAX_WAIT_SECONDS", default_value_t = 25.0)]
    poll_max_wait: f64,

    #[arg(long, env = "OUTLET_COMPLETE_MAX_RETRIES", default_value_t = 100)]
    complete_max_retries: usize,

    #[arg(long, env = "OUTLET_COMPLETE_MAX_SECONDS", default_value_t = 300.0)]
    complete_max_seconds: f64,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    init_logging(&args.log_level);
    warn_about_ignored_legacy_env();

    let server_url = required(
        args.server_url,
        "--server-url or OUTLET_SERVER_URL is required",
    )?;
    let token = required(args.token, "--token or OUTLET_TOKEN is required")?;

    let mut config = RunnerConfig::new(server_url, token);
    if let Some(runner_id) = args
        .runner_id
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        config.runner_id = runner_id;
    }
    config.max_concurrency = args.max_concurrency.max(1);
    config.poll_max_wait_seconds = args.poll_max_wait.max(0.0);
    config.complete_max_retries = args.complete_max_retries.max(1);
    config.complete_max_seconds = args.complete_max_seconds.max(1.0);

    let runner = OutletRunner::new(ShellOutlet::new(), config)?;
    let cancel = CancellationToken::new();
    let signal_cancel = cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            signal_cancel.cancel();
        }
    });

    runner.serve(cancel).await
}

fn init_logging(level: &str) {
    let level = level.trim();
    let filter = EnvFilter::try_from_default_env()
        .or_else(|_| EnvFilter::try_new(level))
        .unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}

fn required(value: Option<String>, message: &str) -> Result<String> {
    let value = value.unwrap_or_default().trim().to_string();
    if value.is_empty() {
        Err(anyhow!(message.to_string()))
    } else {
        Ok(value)
    }
}

fn warn_about_ignored_legacy_env() {
    for key in [
        "OUTLET_CONFIG_DIR",
        "OUTLET_TOKEN_FILE",
        "OUTLET_NO_PAIRING",
    ] {
        if env::var_os(key).is_some() {
            warn!(
                key,
                "ignoring legacy outlet environment variable; daemon mode only uses explicit env/CLI connection settings"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn required_rejects_empty_values() {
        assert!(required(None, "missing").is_err());
        assert!(required(Some("  ".to_string()), "missing").is_err());
        assert_eq!(
            required(Some(" value ".to_string()), "missing").unwrap(),
            "value"
        );
    }

    #[test]
    fn args_have_expected_command_name() {
        use clap::CommandFactory;
        assert_eq!(Args::command().get_name(), "outlet-shell-daemon");
    }
}
