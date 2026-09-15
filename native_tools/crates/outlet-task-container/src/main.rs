use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use bollard::{Docker, API_DEFAULT_VERSION};
use clap::Parser;
use outlet_core::{OutletRunner, PairingClient, RunnerConfig};
use outlet_task_container::manager::{ContainerConfig, ContainerManager};
use outlet_task_container::ContainerOutlet;
use serde::{Deserialize, Serialize};
use serde_json::Map;
use tokio_util::sync::CancellationToken;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(
    name = "outlet-task-container",
    about = "One persistent Linux container per chat family, connected as an Intellectual Club outlet"
)]
struct Args {
    #[arg(long, env = "OUTLET_SERVER_URL")]
    server_url: Option<String>,
    #[arg(long, env = "OUTLET_TOKEN", hide_env_values = true)]
    token: Option<String>,
    #[arg(
        long,
        help = "Pair interactively and save the connection in the private data directory"
    )]
    pair: bool,
    #[arg(long, env = "OUTLET_DATA_DIR", default_value = "./outlet-task-data")]
    data_dir: PathBuf,
    #[arg(
        long,
        env = "OUTLET_DOCKER_SOCKET",
        default_value = "/var/run/docker.sock"
    )]
    docker_socket: String,
    #[arg(long, env = "OUTLET_IMAGE", default_value = "python:3.12-bookworm")]
    image: String,
    #[arg(
        long,
        env = "OUTLET_MAX_CONTAINERS",
        default_value_t = 32,
        help = "Soft retained-container target; never evicts active or TTL-protected work"
    )]
    max_containers: usize,
    #[arg(long, env = "OUTLET_MAX_DISK_BYTES", default_value_t = 20 * 1024 * 1024 * 1024, help = "Soft sum of managed writable layers, not a filesystem quota")]
    max_disk_bytes: u64,
    #[arg(long, env = "OUTLET_GUARANTEED_TTL_SECONDS", default_value_t = 86400)]
    guaranteed_ttl_seconds: u64,
    #[arg(long, env = "OUTLET_MEMORY_BYTES", default_value_t = 2 * 1024 * 1024 * 1024, help = "Per-container emergency memory bound; 0 disables")]
    memory_bytes: i64,
    #[arg(long, env = "OUTLET_PIDS_LIMIT", default_value_t = 256)]
    pids_limit: i64,
    #[arg(long, env = "OUTLET_CPUS", default_value_t = 2.0)]
    cpus: f64,
    #[arg(long, env = "OUTLET_COMMAND_TIMEOUT_SECONDS", default_value_t = 300)]
    command_timeout_seconds: u64,
    #[arg(long, env = "OUTLET_MAX_FILE_BYTES", default_value_t = 512 * 1024 * 1024, help = "Streaming file-transfer safety bound")]
    max_file_bytes: u64,
    #[arg(long, env = "OUTLET_MAX_CONCURRENCY", default_value_t = 20)]
    max_concurrency: usize,
    #[arg(
        long,
        env = "OUTLET_BACKGROUND_TERMINAL_TTL_SECONDS",
        default_value_t = 86400
    )]
    background_terminal_ttl_seconds: u64,
    #[arg(long, env = "OUTLET_LOG_LEVEL", default_value = "info")]
    log_level: String,
}

#[derive(Deserialize, Serialize)]
struct Connection {
    server_url: String,
    token: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    validate_args(&args)?;
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .or_else(|_| EnvFilter::try_new(&args.log_level))
                .unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .compact()
        .init();
    private_directory(&args.data_dir)?;
    let cancel = CancellationToken::new();
    let signal_cancel = cancel.clone();
    tokio::spawn(async move {
        wait_for_shutdown().await;
        signal_cancel.cancel();
    });
    let connection = load_connection(&args, &cancel).await?;
    let docker = connect_docker(&args.docker_socket)?;
    let docker = docker.negotiate_version().await.context(
        "Cannot connect to Docker Engine; install/start Docker and check socket permissions",
    )?;
    let manager = ContainerManager::open(
        docker,
        ContainerConfig {
            data_dir: args.data_dir,
            image: args.image,
            max_containers: args.max_containers,
            max_disk_bytes: args.max_disk_bytes,
            guaranteed_ttl: Duration::from_secs(args.guaranteed_ttl_seconds),
            memory_bytes: args.memory_bytes,
            pids_limit: args.pids_limit,
            nano_cpus: (args.cpus * 1_000_000_000.0) as i64,
        },
        &connection.server_url,
        &connection.token,
    )
    .await?;
    let provider = ContainerOutlet::new(
        manager.clone(),
        Duration::from_secs(args.command_timeout_seconds),
        args.max_file_bytes,
    )?;
    let mut config = RunnerConfig::new(connection.server_url, connection.token);
    config.runner_id = manager.runner_id().to_string();
    config.max_concurrency = args.max_concurrency;
    config.background_terminal_ttl_seconds = args.background_terminal_ttl_seconds as f64;
    let runner = OutletRunner::new(provider, config)?;
    info!(runner_id = manager.runner_id(), "Container outlet ready");
    let result = runner.serve(cancel).await;
    // Stop orphaned execs from foreground calls too; idle files survive a clean restart.
    manager.shutdown().await?;
    result
}

fn validate_args(args: &Args) -> Result<()> {
    if args.image.trim().is_empty()
        || args.max_concurrency == 0
        || args.command_timeout_seconds == 0
        || args.max_file_bytes == 0
        || args.background_terminal_ttl_seconds == 0
        || args.memory_bytes < 0
        || args.pids_limit < 1
        || !args.cpus.is_finite()
        || args.cpus <= 0.0
        || args.cpus > 1_000_000.0
    {
        bail!("Invalid configuration: image, concurrency, timeout, transfer limit, retention, pids and CPUs must be positive; memory must be non-negative");
    }
    Ok(())
}

fn connect_docker(socket: &str) -> Result<Docker> {
    #[cfg(unix)]
    {
        Ok(Docker::connect_with_unix(socket, 120, API_DEFAULT_VERSION)?)
    }
    #[cfg(not(unix))]
    {
        let _ = socket;
        let _ = API_DEFAULT_VERSION;
        bail!("This runner requires a Unix host and a Linux Docker Engine")
    }
}

fn private_directory(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

async fn load_connection(args: &Args, cancel: &CancellationToken) -> Result<Connection> {
    let path = args.data_dir.join("connection.json");
    let stored: Option<Connection> = if path.exists() {
        Some(
            serde_json::from_slice(&std::fs::read(&path)?)
                .context("Invalid saved pairing connection")?,
        )
    } else {
        None
    };
    let server_url = args
        .server_url
        .as_deref()
        .or_else(|| stored.as_ref().map(|s| s.server_url.as_str()))
        .unwrap_or("")
        .trim()
        .trim_end_matches('/')
        .to_string();
    let url = reqwest::Url::parse(&server_url)
        .context("--server-url or OUTLET_SERVER_URL is required")?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        bail!("Server URL must be an HTTP(S) URL without credentials, query, or fragment");
    }
    if args.pair {
        if stored.is_some() || args.token.is_some() {
            bail!("Already configured: pairing will not overwrite credentials. Use a new data directory for another outlet.");
        }
        let client = PairingClient::new(&server_url);
        let pairing = client
            .start("task-container", "Task containers", Map::new())
            .await?;
        eprintln!(
            "Approve this outlet at {}\nCode: {}",
            pairing.verification_url, pairing.user_code
        );
        let deadline = Instant::now() + Duration::from_secs(pairing.expires_in.min(3600));
        loop {
            tokio::select! {
                _ = cancel.cancelled() => bail!("Pairing canceled"),
                _ = tokio::time::sleep(Duration::from_secs_f64(if pairing.interval.is_finite() { pairing.interval.clamp(1.0, 30.0) } else { 5.0 })) => {},
            }
            if Instant::now() > deadline {
                bail!("Pairing expired; run --pair again");
            }
            let response = client.poll(&pairing.device_code).await?;
            if response.status == "approved" && !response.token.trim().is_empty() {
                let connection = Connection {
                    server_url,
                    token: response.token,
                };
                let mut options = std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                let mut file = options.open(&path)?;
                use std::io::Write;
                file.write_all(&serde_json::to_vec(&connection)?)?;
                file.sync_all()?;
                eprintln!("Connection saved to {}", path.display());
                return Ok(connection);
            }
            if !matches!(response.status.as_str(), "pending" | "ok") {
                bail!("Pairing failed: {} {}", response.status, response.error);
            }
        }
    }
    if let Some(saved) = &stored {
        if args.token.is_none() && saved.server_url != server_url {
            bail!("Saved pairing belongs to a different server; use a separate data directory");
        }
    }
    let token = args
        .token
        .as_deref()
        .or_else(|| stored.as_ref().map(|s| s.token.as_str()))
        .unwrap_or("")
        .trim()
        .to_string();
    if token.is_empty() {
        bail!("--token / OUTLET_TOKEN is required, or use --pair once");
    }
    Ok(Connection { server_url, token })
}

async fn wait_for_shutdown() {
    #[cfg(unix)]
    {
        if let Ok(mut terminate) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
            return;
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cli_defaults_are_valid() {
        validate_args(&Args::parse_from(["outlet-task-container"])).unwrap();
    }
    #[test]
    fn reject_invalid_resource_settings() {
        assert!(validate_args(&Args::parse_from([
            "outlet-task-container",
            "--cpus",
            "NaN"
        ]))
        .is_err());
        assert!(validate_args(&Args::parse_from([
            "outlet-task-container",
            "--max-concurrency",
            "0"
        ]))
        .is_err());
    }
}
