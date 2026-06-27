use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chrono::{SecondsFormat, Utc};
use clap::{Parser, Subcommand};
use directories::ProjectDirs;
use eframe::egui;
use postgresql_commands::pg_dump::PgDumpBuilder;
use postgresql_commands::pg_restore::PgRestoreBuilder;
use postgresql_commands::psql::PsqlBuilder;
use postgresql_commands::{AsyncCommandExecutor, CommandBuilder};
use postgresql_embedded::{PostgreSQL, Settings};
use serde::{Deserialize, Serialize};
use tokio::process::{Child, Command};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

const APP_NAME: &str = "intellectual_club";
const DATABASE_NAME: &str = "intellectual_club";
const PG_VERSION: &str = "=16.13.0";
const DEFAULT_PORT: u16 = 4000;
const DEFAULT_POSTGRES_PORT: u16 = 55432;
const CONFIG_VERSION: u32 = 1;

#[derive(Debug, Parser)]
#[command(name = "intellectual-club-launcher")]
#[command(about = "Desktop launcher for Intellectual Club with embedded PostgreSQL")]
struct Args {
    #[command(subcommand)]
    command: Option<CommandKind>,

    #[arg(long, global = true, value_name = "DIR")]
    app_dir: Option<PathBuf>,

    #[arg(
        long,
        global = true,
        env = "IC_LAUNCHER_LOG_LEVEL",
        default_value = "info"
    )]
    log_level: String,
}

#[derive(Debug, Subcommand)]
enum CommandKind {
    Start {
        #[arg(long)]
        open: bool,
    },
    Stop,
    Restart {
        #[arg(long)]
        open: bool,
    },
    Status {
        #[arg(long)]
        json: bool,
    },
    Logs {
        #[arg(long, default_value_t = 120)]
        lines: usize,
    },
    Open,
    Backup {
        #[arg(long, value_name = "PATH")]
        output: Option<PathBuf>,
    },
    Restore {
        #[arg(value_name = "PATH")]
        path: PathBuf,

        #[arg(long)]
        force: bool,
    },
    MoveData {
        #[arg(long, value_name = "PATH")]
        to: PathBuf,

        #[arg(long)]
        delete_source: bool,
    },
    Paths {
        #[arg(long)]
        json: bool,
    },
    Doctor,
    Daemon {
        #[arg(long)]
        open: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    init_logging(&args.log_level);

    let paths = AppPaths::discover()?;
    let mut config = LauncherConfig::load_or_default(&paths.config_path, &paths)?;
    if let Some(app_dir) = args.app_dir {
        config.app_dir = Some(app_dir);
        config.save(&paths.config_path)?;
    }

    let Some(command) = args.command else {
        return run_gui(paths, config).map_err(|error| anyhow!(error.to_string()));
    };

    match command {
        CommandKind::Start { open } => start_command(&paths, &config, open).await,
        CommandKind::Stop => stop_command(&paths, &config).await,
        CommandKind::Restart { open } => {
            stop_command(&paths, &config).await?;
            start_command(&paths, &config, open).await
        }
        CommandKind::Status { json } => status_command(&paths, &config, json).await,
        CommandKind::Logs { lines } => logs_command(&paths, lines),
        CommandKind::Open => open_command(&paths, &config).await,
        CommandKind::Backup { output } => {
            backup_command(&paths, &config, output).await.map(|path| {
                println!("{}", path.display());
            })
        }
        CommandKind::Restore { path, force } => {
            restore_command(&paths, &config, &path, force).await
        }
        CommandKind::MoveData { to, delete_source } => {
            move_data_command(&paths, &mut config, &to, delete_source).await
        }
        CommandKind::Paths { json } => paths_command(&paths, &config, json),
        CommandKind::Doctor => doctor_command(&paths, &config).await,
        CommandKind::Daemon { open } => daemon_command(paths, config, open).await,
    }
}

fn init_logging(level: &str) {
    let filter = EnvFilter::try_from_default_env()
        .or_else(|_| EnvFilter::try_new(level))
        .unwrap_or_else(|_| EnvFilter::new("info"));

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .try_init();
}

#[derive(Clone, Debug)]
struct AppPaths {
    config_path: PathBuf,
    default_data_dir: PathBuf,
    backups_dir: PathBuf,
    installations_dir: PathBuf,
    runtime_dir: PathBuf,
    status_path: PathBuf,
    stop_request_path: PathBuf,
    log_path: PathBuf,
}

impl AppPaths {
    fn discover() -> Result<Self> {
        let project_dirs = ProjectDirs::from("org", "IntellectualClub", "Intellectual Club")
            .ok_or_else(|| anyhow!("failed to resolve platform app directories"))?;
        let config_path = project_dirs.config_dir().join("launcher.json");
        let data_dir = project_dirs.data_dir();
        let runtime_dir = data_dir.join("runtime");
        Ok(Self {
            config_path,
            default_data_dir: data_dir.join("postgres").join("data"),
            backups_dir: data_dir.join("backups"),
            installations_dir: project_dirs
                .cache_dir()
                .join("postgres")
                .join("installations"),
            status_path: runtime_dir.join("status.json"),
            stop_request_path: runtime_dir.join("stop-request"),
            log_path: runtime_dir.join("launcher.log"),
            runtime_dir,
        })
    }

    fn ensure_dirs(&self) -> Result<()> {
        for dir in [
            self.config_path.parent(),
            Some(self.default_data_dir.as_path()),
            Some(self.backups_dir.as_path()),
            Some(self.installations_dir.as_path()),
            Some(self.runtime_dir.as_path()),
        ]
        .into_iter()
        .flatten()
        {
            fs::create_dir_all(dir)
                .with_context(|| format!("failed to create {}", dir.display()))?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct LauncherConfig {
    version: u32,
    app_dir: Option<PathBuf>,
    postgres_data_dir: PathBuf,
    postgres_port: u16,
    app_port: u16,
    database_name: String,
    postgres_user: String,
    postgres_password: String,
    secret_key_base: String,
    token_signing_secret: String,
    locale: Locale,
}

impl LauncherConfig {
    fn load_or_default(path: &Path, paths: &AppPaths) -> Result<Self> {
        if !path.exists() {
            let config = Self::default_for(paths);
            config.save(path)?;
            return Ok(config);
        }

        let text = fs::read_to_string(path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let mut config: Self = serde_json::from_str(&text).context("invalid launcher config")?;
        let mut changed = false;
        if config.version == 0 {
            config.version = CONFIG_VERSION;
            changed = true;
        }
        if config.secret_key_base.len() < 64 {
            config.secret_key_base = random_secret("sk");
            changed = true;
        }
        if config.token_signing_secret.len() < 64 {
            config.token_signing_secret = random_secret("tok");
            changed = true;
        }
        if changed {
            config.save(path)?;
        }
        Ok(config)
    }

    fn default_for(paths: &AppPaths) -> Self {
        Self {
            version: CONFIG_VERSION,
            app_dir: default_app_dir(),
            postgres_data_dir: paths.default_data_dir.clone(),
            postgres_port: DEFAULT_POSTGRES_PORT,
            app_port: DEFAULT_PORT,
            database_name: DATABASE_NAME.to_string(),
            postgres_user: "postgres".to_string(),
            postgres_password: random_secret("pg"),
            secret_key_base: random_secret("sk"),
            token_signing_secret: random_secret("tok"),
            locale: Locale::from_env(),
        }
    }

    fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let payload = serde_json::to_string_pretty(self)?;
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, payload + "\n")
            .with_context(|| format!("failed to write {}", tmp.display()))?;
        restrict_file_permissions(&tmp)?;
        fs::rename(&tmp, path).with_context(|| format!("failed to replace {}", path.display()))?;
        restrict_file_permissions(path)?;
        Ok(())
    }

    fn app_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.app_port)
    }

    fn database_url(&self, settings: &Settings) -> String {
        settings.url(&self.database_name)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Locale {
    En,
    Ru,
}

impl Locale {
    fn from_env() -> Self {
        let lang = env::var("LANG").unwrap_or_default().to_lowercase();
        if lang.starts_with("ru") {
            Self::Ru
        } else {
            Self::En
        }
    }

    fn text(self, key: TextKey) -> &'static str {
        match (self, key) {
            (Self::Ru, TextKey::Title) => "Intellectual Club",
            (Self::Ru, TextKey::Status) => "Статус",
            (Self::Ru, TextKey::Start) => "Запустить",
            (Self::Ru, TextKey::Stop) => "Остановить",
            (Self::Ru, TextKey::Restart) => "Перезапустить",
            (Self::Ru, TextKey::Open) => "Открыть",
            (Self::Ru, TextKey::Backup) => "Бэкап",
            (Self::Ru, TextKey::Restore) => "Рестор",
            (Self::Ru, TextKey::MoveData) => "Переместить данные",
            (Self::Ru, TextKey::Paths) => "Пути",
            (Self::Ru, TextKey::Logs) => "Логи",
            (Self::Ru, TextKey::Running) => "Запущено",
            (Self::Ru, TextKey::Stopped) => "Остановлено",
            (Self::Ru, TextKey::LastError) => "Последняя ошибка",
            (Self::En, TextKey::Title) => "Intellectual Club",
            (Self::En, TextKey::Status) => "Status",
            (Self::En, TextKey::Start) => "Start",
            (Self::En, TextKey::Stop) => "Stop",
            (Self::En, TextKey::Restart) => "Restart",
            (Self::En, TextKey::Open) => "Open",
            (Self::En, TextKey::Backup) => "Backup",
            (Self::En, TextKey::Restore) => "Restore",
            (Self::En, TextKey::MoveData) => "Move data",
            (Self::En, TextKey::Paths) => "Paths",
            (Self::En, TextKey::Logs) => "Logs",
            (Self::En, TextKey::Running) => "Running",
            (Self::En, TextKey::Stopped) => "Stopped",
            (Self::En, TextKey::LastError) => "Last error",
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum TextKey {
    Title,
    Status,
    Start,
    Stop,
    Restart,
    Open,
    Backup,
    Restore,
    MoveData,
    Paths,
    Logs,
    Running,
    Stopped,
    LastError,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct RuntimeStatus {
    version: u32,
    daemon_pid: u32,
    app_pid: Option<u32>,
    app_url: String,
    database_url: String,
    postgres_data_dir: PathBuf,
    started_at: String,
    updated_at: String,
    state: String,
    last_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct StatusPayload {
    running: bool,
    status: Option<RuntimeStatus>,
    app_healthy: bool,
    paths: PathsPayload,
}

#[derive(Clone, Debug, Serialize)]
struct PathsPayload {
    config_path: PathBuf,
    postgres_data_dir: PathBuf,
    backups_dir: PathBuf,
    installations_dir: PathBuf,
    runtime_dir: PathBuf,
    log_path: PathBuf,
    app_dir: Option<PathBuf>,
}

async fn start_command(paths: &AppPaths, config: &LauncherConfig, open: bool) -> Result<()> {
    paths.ensure_dirs()?;
    let current = read_status(&paths.status_path).ok();
    if let Some(status) = current
        .as_ref()
        .filter(|status| process_alive(status.daemon_pid))
    {
        println!("Already running: {}", status.app_url);
        if open {
            open_url(&status.app_url)?;
        }
        return Ok(());
    }

    remove_file_if_exists(&paths.stop_request_path)?;
    remove_file_if_exists(&paths.status_path)?;

    let exe = env::current_exe().context("failed to resolve current executable")?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("--log-level").arg("info").arg("daemon");
    if open {
        cmd.arg("--open");
    }
    if let Some(app_dir) = &config.app_dir {
        cmd.arg("--app-dir").arg(app_dir);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    configure_daemon_process(&mut cmd);
    let mut child = cmd.spawn().context("failed to spawn launcher daemon")?;
    println!("Started launcher daemon pid {}", child.id());

    wait_for_status(paths, &mut child, Duration::from_secs(90)).await?;
    Ok(())
}

fn configure_daemon_process(cmd: &mut std::process::Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        cmd.process_group(0);
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        cmd.creation_flags(CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS);
    }
}

async fn stop_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    paths.ensure_dirs()?;
    fs::write(&paths.stop_request_path, Utc::now().to_rfc3339())
        .with_context(|| format!("failed to write {}", paths.stop_request_path.display()))?;

    let status = read_status(&paths.status_path).ok();
    if let Some(status) = status {
        for _ in 0..80 {
            if !process_alive(status.daemon_pid) || !paths.status_path.exists() {
                println!("Stopped");
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        warn!("daemon did not stop after stop request; trying database stop directly");
    }

    let pg = postgres_from_config(paths, config)?;
    let _ = pg.stop().await;
    remove_file_if_exists(&paths.status_path)?;
    println!("Stopped");
    Ok(())
}

async fn status_command(paths: &AppPaths, config: &LauncherConfig, json: bool) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else if let Some(status) = &payload.status {
        println!("state: {}", status.state);
        println!("daemon_pid: {}", status.daemon_pid);
        println!(
            "app_pid: {}",
            status
                .app_pid
                .map_or("-".to_string(), |pid| pid.to_string())
        );
        println!("app_url: {}", status.app_url);
        println!("app_healthy: {}", payload.app_healthy);
        println!("postgres_data_dir: {}", status.postgres_data_dir.display());
        if let Some(error) = &status.last_error {
            println!("last_error: {error}");
        }
    } else {
        println!("state: stopped");
    }
    Ok(())
}

fn logs_command(paths: &AppPaths, lines: usize) -> Result<()> {
    if !paths.log_path.exists() {
        println!("Log file does not exist yet: {}", paths.log_path.display());
        return Ok(());
    }
    let text = fs::read_to_string(&paths.log_path)
        .with_context(|| format!("failed to read {}", paths.log_path.display()))?;
    for line in text
        .lines()
        .rev()
        .take(lines)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        println!("{line}");
    }
    Ok(())
}

async fn open_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if let Some(status) = payload.status {
        open_url(&status.app_url)
    } else {
        open_url(&config.app_url())
    }
}

async fn backup_command(
    paths: &AppPaths,
    config: &LauncherConfig,
    output: Option<PathBuf>,
) -> Result<PathBuf> {
    paths.ensure_dirs()?;
    let (pg, started_here) = ensure_postgres_for_admin(paths, config).await?;
    let settings = pg.settings().clone();
    ensure_database(&pg, config).await?;

    let backup_path = output.unwrap_or_else(|| {
        let stamp = Utc::now().format("%Y%m%d-%H%M%S").to_string();
        paths
            .backups_dir
            .join(format!("intellectual-club-{stamp}.dump"))
    });
    if let Some(parent) = backup_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut command = PgDumpBuilder::from(&settings)
        .dbname(&config.database_name)
        .format("custom")
        .file(backup_path.as_os_str())
        .no_owner()
        .build_tokio();
    execute_pg_command(&mut command, settings.timeout).await?;

    let meta = serde_json::json!({
        "version": 1,
        "created_at": Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        "database": config.database_name,
        "postgres_version": PG_VERSION,
        "dump": backup_path.file_name().and_then(|name| name.to_str()).unwrap_or_default(),
    });
    fs::write(
        backup_path.with_extension("dump.json"),
        serde_json::to_string_pretty(&meta)? + "\n",
    )?;
    if started_here {
        pg.stop().await.ok();
    }
    Ok(backup_path)
}

async fn restore_command(
    paths: &AppPaths,
    config: &LauncherConfig,
    dump_path: &Path,
    force: bool,
) -> Result<()> {
    if !force {
        bail!("restore requires --force");
    }
    if !dump_path.exists() {
        bail!("restore file does not exist: {}", dump_path.display());
    }

    stop_command(paths, config).await.ok();
    let safety = backup_command(paths, config, None).await?;
    println!("Safety backup: {}", safety.display());

    {
        let (pg, started_here) = ensure_postgres_for_admin(paths, config).await?;
        let settings = pg.settings().clone();
        recreate_database(&settings, config).await?;

        let mut command = PgRestoreBuilder::from(&settings)
            .dbname(&config.database_name)
            .format("custom")
            .exit_on_error()
            .no_owner()
            .build_tokio();
        command.arg(dump_path.as_os_str());
        execute_pg_command(&mut command, settings.timeout).await?;
        if started_here {
            pg.stop().await.ok();
        }
    }

    start_command(paths, config, false).await?;
    Ok(())
}

async fn move_data_command(
    paths: &AppPaths,
    config: &mut LauncherConfig,
    target: &Path,
    delete_source: bool,
) -> Result<()> {
    let source = config.postgres_data_dir.clone();
    if source == target {
        bail!("target data directory is already active");
    }

    stop_command(paths, config).await.ok();
    let safety = backup_command(paths, config, None).await?;
    println!("Safety backup: {}", safety.display());

    if target.exists() {
        if is_empty_dir(target)? {
            fs::remove_dir(target)
                .with_context(|| format!("failed to remove empty {}", target.display()))?;
        } else {
            bail!("target already exists: {}", target.display());
        }
    }
    copy_dir_all(&source, target)?;
    let previous = config.postgres_data_dir.clone();
    config.postgres_data_dir = target.to_path_buf();
    config.save(&paths.config_path)?;

    match start_command(paths, config, false).await {
        Ok(()) => {
            if delete_source {
                fs::remove_dir_all(&previous)
                    .with_context(|| format!("failed to delete {}", previous.display()))?;
            }
            println!("Moved data to {}", target.display());
            Ok(())
        }
        Err(error) => {
            config.postgres_data_dir = previous;
            config.save(&paths.config_path)?;
            fs::remove_dir_all(target).ok();
            Err(error).context("moved data failed validation; restored previous config")
        }
    }
}

fn is_empty_dir(path: &Path) -> Result<bool> {
    if !path.is_dir() {
        return Ok(false);
    }
    Ok(fs::read_dir(path)
        .with_context(|| format!("failed to read {}", path.display()))?
        .next()
        .is_none())
}

fn paths_command(paths: &AppPaths, config: &LauncherConfig, json: bool) -> Result<()> {
    let payload = paths_payload(paths, config);
    if json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("config_path: {}", payload.config_path.display());
        println!("postgres_data_dir: {}", payload.postgres_data_dir.display());
        println!("backups_dir: {}", payload.backups_dir.display());
        println!("installations_dir: {}", payload.installations_dir.display());
        println!("runtime_dir: {}", payload.runtime_dir.display());
        println!("log_path: {}", payload.log_path.display());
        println!(
            "app_dir: {}",
            payload
                .app_dir
                .as_ref()
                .map_or("-".to_string(), |path| path.display().to_string())
        );
    }
    Ok(())
}

async fn doctor_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    paths.ensure_dirs()?;
    println!("config: {}", paths.config_path.display());
    println!("app_dir: {}", resolve_app_dir(config)?.display());
    println!("postgres_data_dir: {}", config.postgres_data_dir.display());
    println!("postgres_version: {}", PG_VERSION);
    let mut pg = postgres_from_config(paths, config)?;
    pg.setup().await?;
    println!("postgres_setup: ok");
    pg.stop().await.ok();
    Ok(())
}

async fn daemon_command(paths: AppPaths, config: LauncherConfig, open: bool) -> Result<()> {
    paths.ensure_dirs()?;
    remove_file_if_exists(&paths.stop_request_path)?;
    let mut log_file = open_log_file(&paths.log_path)?;
    writeln!(log_file, "[{}] daemon starting", timestamp())?;

    let mut pg = postgres_from_config(&paths, &config)?;
    pg.setup()
        .await
        .context("failed to setup embedded postgres")?;
    pg.start()
        .await
        .context("failed to start embedded postgres")?;
    ensure_database(&pg, &config).await?;
    let database_url = config.database_url(pg.settings());

    let mut app = start_app(&config, &database_url, &paths.log_path).await?;
    let app_pid = app.id();
    write_status(
        &paths.status_path,
        &RuntimeStatus {
            version: CONFIG_VERSION,
            daemon_pid: std::process::id(),
            app_pid,
            app_url: config.app_url(),
            database_url,
            postgres_data_dir: config.postgres_data_dir.clone(),
            started_at: timestamp(),
            updated_at: timestamp(),
            state: "starting".to_string(),
            last_error: None,
        },
    )?;

    wait_for_http(&config.app_url(), Duration::from_secs(90)).await?;
    if open {
        open_url(&config.app_url()).ok();
    }
    write_status_state(&paths.status_path, "running", None)?;
    writeln!(log_file, "[{}] daemon running", timestamp())?;

    let exit_result = daemon_loop(&paths, &mut app).await;
    let app_stop = stop_child(&mut app).await;
    let pg_stop = pg.stop().await.map_err(|error| anyhow!(error.to_string()));
    remove_file_if_exists(&paths.status_path)?;
    remove_file_if_exists(&paths.stop_request_path)?;
    writeln!(log_file, "[{}] daemon stopped", timestamp())?;

    exit_result?;
    app_stop?;
    pg_stop?;
    Ok(())
}

async fn daemon_loop(paths: &AppPaths, app: &mut Child) -> Result<()> {
    loop {
        if paths.stop_request_path.exists() {
            return Ok(());
        }
        if let Some(status) = app.try_wait().context("failed to inspect app process")? {
            let message = format!("application exited with status {status}");
            write_status_state(&paths.status_path, "error", Some(message.clone())).ok();
            bail!(message);
        }
        write_status_state(&paths.status_path, "running", None).ok();
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn start_app(config: &LauncherConfig, database_url: &str, log_path: &Path) -> Result<Child> {
    let app_dir = resolve_app_dir(config)?;
    let bin_path = app_dir.join("bin").join(APP_NAME);
    if !bin_path.exists() {
        bail!("Phoenix release binary not found: {}", bin_path.display());
    }
    let public_host = launcher_public_host();

    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .with_context(|| format!("failed to open {}", log_path.display()))?;
    let log_err = log
        .try_clone()
        .context("failed to clone launcher log handle")?;

    let mut cmd = Command::new(bin_path);
    cmd.arg("start")
        .current_dir(&app_dir)
        .env("PHX_SERVER", "true")
        .env("DATABASE_URL", database_url)
        .env("PORT", config.app_port.to_string())
        .env("PHX_HOST", public_host)
        .env("PHX_SCHEME", "http")
        .env("PHX_PORT", config.app_port.to_string())
        .env("POOL_SIZE", "10")
        .env("SECRET_KEY_BASE", &config.secret_key_base)
        .env("TOKEN_SIGNING_SECRET", &config.token_signing_secret)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));

    cmd.spawn().context("failed to start Phoenix release")
}

fn postgres_from_config(paths: &AppPaths, config: &LauncherConfig) -> Result<PostgreSQL> {
    let mut settings = Settings::default();
    settings.version = postgresql_embedded::VersionReq::parse(PG_VERSION)?;
    settings.installation_dir = paths.installations_dir.clone();
    settings.data_dir = config.postgres_data_dir.clone();
    settings.password_file = paths.runtime_dir.join("pgpass");
    settings.host = "127.0.0.1".to_string();
    settings.port = config.postgres_port;
    settings.username = config.postgres_user.clone();
    settings.password = config.postgres_password.clone();
    settings.temporary = false;
    settings.timeout = Some(Duration::from_secs(120));
    settings
        .configuration
        .insert("listen_addresses".to_string(), "'127.0.0.1'".to_string());
    settings
        .configuration
        .insert("max_connections".to_string(), "100".to_string());
    Ok(PostgreSQL::new(settings))
}

async fn ensure_postgres_for_admin(
    paths: &AppPaths,
    config: &LauncherConfig,
) -> Result<(PostgreSQL, bool)> {
    let mut pg = postgres_from_config(paths, config)?;
    pg.setup().await?;
    let started_here = pg.status() != postgresql_embedded::Status::Started;
    if pg.status() != postgresql_embedded::Status::Started {
        pg.start().await?;
    }
    Ok((pg, started_here))
}

async fn ensure_database(pg: &PostgreSQL, config: &LauncherConfig) -> Result<()> {
    if !pg.database_exists(&config.database_name).await? {
        pg.create_database(&config.database_name).await?;
    }
    Ok(())
}

async fn recreate_database(settings: &Settings, config: &LauncherConfig) -> Result<()> {
    let db_literal = quote_sql_literal(&config.database_name);
    let db_identifier = quote_sql_identifier(&config.database_name);
    let statements = [
        format!(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = {db_literal} AND pid <> pg_backend_pid()"
        ),
        format!("DROP DATABASE IF EXISTS {db_identifier}"),
        format!("CREATE DATABASE {db_identifier}"),
    ];

    for statement in statements {
        let mut command = PsqlBuilder::from(settings)
            .dbname("postgres")
            .command(statement)
            .build_tokio();
        execute_pg_command(&mut command, settings.timeout).await?;
    }
    Ok(())
}

fn quote_sql_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn quote_sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

async fn execute_pg_command(
    command: &mut tokio::process::Command,
    timeout: Option<Duration>,
) -> Result<()> {
    let (stdout, stderr) = command.execute(timeout).await?;
    if !stdout.trim().is_empty() {
        info!(stdout = %stdout.trim(), "postgres command stdout");
    }
    if !stderr.trim().is_empty() {
        info!(stderr = %stderr.trim(), "postgres command stderr");
    }
    Ok(())
}

async fn wait_for_status(
    paths: &AppPaths,
    daemon: &mut std::process::Child,
    timeout: Duration,
) -> Result<()> {
    let started = Instant::now();
    while started.elapsed() < timeout {
        if let Some(status) = daemon
            .try_wait()
            .context("failed to inspect launcher daemon")?
        {
            bail!("launcher daemon exited before becoming ready: {status}");
        }
        if let Ok(status) = read_status(&paths.status_path) {
            if status.state == "running" {
                return Ok(());
            }
            if status.state == "error" {
                bail!(
                    "launcher daemon failed: {}",
                    status
                        .last_error
                        .unwrap_or_else(|| "unknown error".to_string())
                );
            }
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    bail!("launcher daemon did not become ready within {:?}", timeout)
}

async fn wait_for_http(url: &str, timeout: Duration) -> Result<()> {
    let started = Instant::now();
    let target = url::Url::parse(url).context("invalid app url")?;
    let host = target
        .host_str()
        .ok_or_else(|| anyhow!("missing app host"))?;
    let port = target.port().ok_or_else(|| anyhow!("missing app port"))?;
    let addr: SocketAddr = format!("{host}:{port}").parse()?;

    while started.elapsed() < timeout {
        if std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    bail!("application did not open {} within {:?}", url, timeout)
}

async fn build_status_payload(paths: &AppPaths, config: &LauncherConfig) -> StatusPayload {
    let status = read_status(&paths.status_path).ok();
    let running = status
        .as_ref()
        .map(|status| process_alive(status.daemon_pid))
        .unwrap_or(false);
    let app_healthy = if running {
        wait_for_http(&config.app_url(), Duration::from_millis(500))
            .await
            .is_ok()
    } else {
        false
    };
    StatusPayload {
        running,
        status: status.filter(|_| running),
        app_healthy,
        paths: paths_payload(paths, config),
    }
}

fn paths_payload(paths: &AppPaths, config: &LauncherConfig) -> PathsPayload {
    PathsPayload {
        config_path: paths.config_path.clone(),
        postgres_data_dir: config.postgres_data_dir.clone(),
        backups_dir: paths.backups_dir.clone(),
        installations_dir: paths.installations_dir.clone(),
        runtime_dir: paths.runtime_dir.clone(),
        log_path: paths.log_path.clone(),
        app_dir: config.app_dir.clone(),
    }
}

fn read_status(path: &Path) -> Result<RuntimeStatus> {
    let text =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    serde_json::from_str(&text).context("invalid launcher status")
}

fn write_status(path: &Path, status: &RuntimeStatus) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, serde_json::to_string_pretty(status)? + "\n")?;
    Ok(())
}

fn write_status_state(path: &Path, state: &str, last_error: Option<String>) -> Result<()> {
    let mut status = read_status(path)?;
    status.state = state.to_string();
    status.updated_at = timestamp();
    if last_error.is_some() {
        status.last_error = last_error;
    }
    write_status(path, &status)
}

async fn stop_child(child: &mut Child) -> Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    child.start_kill().context("failed to stop app process")?;
    let _ = child.wait().await;
    Ok(())
}

fn process_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
    #[cfg(not(unix))]
    {
        pid > 0
    }
}

fn default_app_dir() -> Option<PathBuf> {
    let exe = env::current_exe().ok()?;
    let bin_dir = exe.parent()?;
    let build_dev = bin_dir.parent()?;
    let release = build_dev.join(APP_NAME);
    if release.join("bin").join(APP_NAME).exists() {
        Some(release)
    } else {
        None
    }
}

fn resolve_app_dir(config: &LauncherConfig) -> Result<PathBuf> {
    if let Some(path) = &config.app_dir {
        return Ok(path.clone());
    }
    default_app_dir()
        .ok_or_else(|| anyhow!("app_dir is not configured and could not be discovered"))
}

fn launcher_public_host() -> String {
    env::var("IC_LAUNCHER_PUBLIC_HOST")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(local_lan_ipv4_host)
        .unwrap_or_else(|| "127.0.0.1".to_string())
}

fn local_lan_ipv4_host() -> Option<String> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    socket.connect((Ipv4Addr::new(8, 8, 8, 8), 80)).ok()?;

    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_loopback() && !ip.is_unspecified() => Some(ip.to_string()),
        _ => None,
    }
}

fn open_url(url: &str) -> Result<()> {
    webbrowser::open(url).with_context(|| format!("failed to open {url}"))?;
    Ok(())
}

fn random_secret(prefix: &str) -> String {
    use std::fmt::Write as _;

    let mut bytes = [0u8; 48];
    if getrandom::getrandom(&mut bytes).is_err() {
        let nanos = Utc::now().timestamp_nanos_opt().unwrap_or_default();
        let fallback = format!(
            "{prefix}-{:x}-{:x}-{:x}",
            nanos,
            std::process::id(),
            nanos.rotate_left(17)
        );
        return fallback.repeat(4);
    }

    let mut secret = String::with_capacity(prefix.len() + 1 + bytes.len() * 2);
    secret.push_str(prefix);
    secret.push('-');
    for byte in bytes {
        let _ = write!(&mut secret, "{byte:02x}");
    }
    secret
}

fn timestamp() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn open_log_file(path: &Path) -> Result<File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))
}

fn remove_file_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

fn restrict_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod 0600 {}", path.display()))?;
    }
    Ok(())
}

fn copy_dir_all(source: &Path, target: &Path) -> Result<()> {
    let source_metadata = fs::metadata(source)
        .with_context(|| format!("failed to read metadata for {}", source.display()))?;
    fs::create_dir_all(target).with_context(|| format!("failed to create {}", target.display()))?;
    fs::set_permissions(target, source_metadata.permissions())
        .with_context(|| format!("failed to set permissions for {}", target.display()))?;

    for entry in
        fs::read_dir(source).with_context(|| format!("failed to read {}", source.display()))?
    {
        let entry = entry?;
        let entry_source = entry.path();
        let entry_target = target.join(entry.file_name());
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_all(&entry_source, &entry_target)?;
        } else if file_type.is_file() {
            fs::copy(&entry_source, &entry_target).with_context(|| {
                format!(
                    "failed to copy {} to {}",
                    entry_source.display(),
                    entry_target.display()
                )
            })?;
            fs::set_permissions(&entry_target, entry.metadata()?.permissions()).with_context(
                || format!("failed to set permissions for {}", entry_target.display()),
            )?;
        }
    }
    Ok(())
}

struct LauncherGui {
    paths: AppPaths,
    config: LauncherConfig,
    runtime: tokio::runtime::Runtime,
    tx: mpsc::Sender<GuiEvent>,
    rx: mpsc::Receiver<GuiEvent>,
    status: Option<StatusPayload>,
    last_error: String,
    moving_to: String,
    restore_from: String,
}

#[derive(Debug)]
enum GuiEvent {
    Status(StatusPayload),
    Info(String),
    Error(String),
}

impl LauncherGui {
    fn new(paths: AppPaths, config: LauncherConfig) -> Self {
        let (tx, rx) = mpsc::channel();
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        let mut app = Self {
            paths,
            config,
            runtime,
            tx,
            rx,
            status: None,
            last_error: String::new(),
            moving_to: String::new(),
            restore_from: String::new(),
        };
        app.refresh_status();
        app
    }

    fn refresh_status(&mut self) {
        let tx = self.tx.clone();
        let paths = self.paths.clone();
        let config = self.config.clone();
        self.runtime.spawn(async move {
            let payload = build_status_payload(&paths, &config).await;
            let _ = tx.send(GuiEvent::Status(payload));
        });
    }

    fn run_task<F>(&self, task: F)
    where
        F: std::future::Future<Output = Result<String>> + Send + 'static,
    {
        let tx = self.tx.clone();
        self.runtime.spawn(async move {
            match task.await {
                Ok(message) => {
                    let _ = tx.send(GuiEvent::Info(message));
                }
                Err(error) => {
                    let _ = tx.send(GuiEvent::Error(error.to_string()));
                }
            }
        });
    }

    fn process_events(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                GuiEvent::Status(status) => self.status = Some(status),
                GuiEvent::Info(message) => {
                    self.last_error.clear();
                    info!("{message}");
                    self.refresh_status();
                }
                GuiEvent::Error(error) => {
                    self.last_error = error;
                    self.refresh_status();
                }
            }
        }
    }
}

impl eframe::App for LauncherGui {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_events();
        let locale = self.config.locale;
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading(locale.text(TextKey::Title));
            ui.separator();

            let running = self
                .status
                .as_ref()
                .map(|status| status.running)
                .unwrap_or(false);
            ui.horizontal(|ui| {
                ui.label(locale.text(TextKey::Status));
                ui.strong(if running {
                    locale.text(TextKey::Running)
                } else {
                    locale.text(TextKey::Stopped)
                });
            });
            ui.label(self.config.app_url());

            ui.horizontal(|ui| {
                if ui.button(locale.text(TextKey::Start)).clicked() {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    self.run_task(async move {
                        start_command(&paths, &config, true).await?;
                        Ok("started".to_string())
                    });
                }
                if ui.button(locale.text(TextKey::Stop)).clicked() {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    self.run_task(async move {
                        stop_command(&paths, &config).await?;
                        Ok("stopped".to_string())
                    });
                }
                if ui.button(locale.text(TextKey::Restart)).clicked() {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    self.run_task(async move {
                        stop_command(&paths, &config).await.ok();
                        start_command(&paths, &config, true).await?;
                        Ok("restarted".to_string())
                    });
                }
                if ui.button(locale.text(TextKey::Open)).clicked() {
                    open_url(&self.config.app_url()).ok();
                }
            });

            ui.separator();
            ui.horizontal(|ui| {
                if ui.button(locale.text(TextKey::Backup)).clicked() {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    self.run_task(async move {
                        let backup = backup_command(&paths, &config, None).await?;
                        Ok(format!("backup: {}", backup.display()))
                    });
                }
                ui.text_edit_singleline(&mut self.restore_from);
                if ui.button(locale.text(TextKey::Restore)).clicked() {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    let path = PathBuf::from(self.restore_from.trim());
                    self.run_task(async move {
                        restore_command(&paths, &config, &path, true).await?;
                        Ok("restored".to_string())
                    });
                }
            });

            ui.horizontal(|ui| {
                ui.text_edit_singleline(&mut self.moving_to);
                if ui.button(locale.text(TextKey::MoveData)).clicked() {
                    let paths = self.paths.clone();
                    let mut config = self.config.clone();
                    let target = PathBuf::from(self.moving_to.trim());
                    self.run_task(async move {
                        move_data_command(&paths, &mut config, &target, false).await?;
                        Ok("data moved".to_string())
                    });
                }
            });

            ui.separator();
            ui.collapsing(locale.text(TextKey::Paths), |ui| {
                ui.monospace(format!("config: {}", self.paths.config_path.display()));
                ui.monospace(format!("data: {}", self.config.postgres_data_dir.display()));
                ui.monospace(format!("backups: {}", self.paths.backups_dir.display()));
                ui.monospace(format!("log: {}", self.paths.log_path.display()));
            });
            ui.collapsing(locale.text(TextKey::Logs), |ui| {
                if let Ok(text) = fs::read_to_string(&self.paths.log_path) {
                    let mut tail = text
                        .lines()
                        .rev()
                        .take(20)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join("\n");
                    ui.add(egui::TextEdit::multiline(&mut tail).desired_rows(8));
                }
            });
            if !self.last_error.is_empty() {
                ui.separator();
                ui.label(locale.text(TextKey::LastError));
                ui.colored_label(egui::Color32::RED, &self.last_error);
            }
        });
        ctx.request_repaint_after(Duration::from_millis(500));
    }
}

fn run_gui(paths: AppPaths, config: LauncherConfig) -> eframe::Result<()> {
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "Intellectual Club",
        options,
        Box::new(|_cc| Ok(Box::new(LauncherGui::new(paths, config)))),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_url_uses_configured_port() {
        let paths = AppPaths::discover().unwrap();
        let mut config = LauncherConfig::default_for(&paths);
        config.app_port = 4999;
        assert_eq!(config.app_url(), "http://127.0.0.1:4999");
    }

    #[test]
    fn localized_labels_exist() {
        assert_eq!(Locale::Ru.text(TextKey::Start), "Запустить");
        assert_eq!(Locale::En.text(TextKey::Start), "Start");
    }
}
