use std::env;
use std::fs;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chrono::{SecondsFormat, Utc};
use postgresql_commands::pg_dump::PgDumpBuilder;
use postgresql_commands::pg_restore::PgRestoreBuilder;
use postgresql_commands::psql::PsqlBuilder;
use postgresql_commands::{AsyncCommandExecutor, CommandBuilder};
use postgresql_embedded::{PostgreSQL, Settings, Status as PostgresStatus};
use tokio::process::{Child, Command};
use tracing::{info, warn};

use crate::cli::LogSource;
use crate::config::{
    resolve_app_dir, AppPaths, LauncherConfig, APP_NAME, CONFIG_VERSION, PG_VERSION,
};
use crate::fs_utils::{
    append_log_line, copy_dir_all, is_empty_dir, open_log_file, open_path, open_url,
    remove_file_if_exists, tail_file, timestamp,
};
use crate::status::{PathsPayload, RuntimeStatus, ServiceState, ServiceStatus, StatusPayload};

pub async fn start_command(paths: &AppPaths, config: &LauncherConfig, open: bool) -> Result<()> {
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

pub async fn stop_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
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

pub async fn status_command(paths: &AppPaths, config: &LauncherConfig, json: bool) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("daemon_state: {}", payload.daemon.state.as_str());
        println!(
            "daemon_pid: {}",
            payload
                .daemon
                .pid
                .map_or("-".to_string(), |pid| pid.to_string())
        );
        println!("app_state: {}", payload.app.state.as_str());
        println!(
            "app_pid: {}",
            payload
                .app
                .pid
                .map_or("-".to_string(), |pid| pid.to_string())
        );
        println!("app_url: {}", config.app_url());
        println!("app_healthy: {}", payload.app.healthy);
        println!("postgres_state: {}", payload.postgres.state.as_str());
        println!(
            "postgres_pid: {}",
            payload
                .postgres
                .pid
                .map_or("-".to_string(), |pid| pid.to_string())
        );
        println!("postgres_port: {}", config.postgres_port);
        println!("postgres_healthy: {}", payload.postgres.healthy);
        if let Some(error) = payload
            .app
            .detail
            .as_ref()
            .or(payload.daemon.detail.as_ref())
        {
            println!("last_error: {error}");
        }
    }
    Ok(())
}

pub fn logs_command(
    paths: &AppPaths,
    config: &LauncherConfig,
    source: LogSource,
    lines: usize,
) -> Result<()> {
    match source {
        LogSource::All => {
            for source in [LogSource::Launcher, LogSource::App, LogSource::Postgres] {
                println!("== {source} ==");
                print_log_tail(paths, config, source, lines)?;
            }
        }
        source => print_log_tail(paths, config, source, lines)?,
    }
    Ok(())
}

fn print_log_tail(
    paths: &AppPaths,
    config: &LauncherConfig,
    source: LogSource,
    lines: usize,
) -> Result<()> {
    let path = log_path_for(paths, config, source);
    if !path.exists() {
        println!("Log file does not exist yet: {}", path.display());
        return Ok(());
    }
    let text = tail_file(&path, lines)?;
    if !text.is_empty() {
        println!("{text}");
    }
    Ok(())
}

pub async fn open_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if let Some(status) = payload.status {
        open_url(&status.app_url)
    } else {
        open_url(&config.app_url())
    }
}

pub async fn backup_command(
    paths: &AppPaths,
    config: &LauncherConfig,
    output: Option<PathBuf>,
) -> Result<PathBuf> {
    paths.ensure_dirs()?;
    let admin = ensure_postgres_for_admin(paths, config).await?;
    let settings = admin.settings().clone();
    ensure_database(admin.postgres(), config).await?;

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
    admin.finish().await;
    Ok(backup_path)
}

pub async fn restore_command(
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
        let admin = ensure_postgres_for_admin(paths, config).await?;
        let settings = admin.settings().clone();
        recreate_database(&settings, config).await?;

        let mut command = PgRestoreBuilder::from(&settings)
            .dbname(&config.database_name)
            .format("custom")
            .exit_on_error()
            .no_owner()
            .build_tokio();
        command.arg(dump_path.as_os_str());
        execute_pg_command(&mut command, settings.timeout).await?;
        admin.finish().await;
    }

    start_command(paths, config, false).await?;
    Ok(())
}

pub async fn move_data_command(
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

pub fn paths_command(paths: &AppPaths, config: &LauncherConfig, json: bool) -> Result<()> {
    let payload = paths_payload(paths, config);
    if json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("config_path: {}", payload.config_path.display());
        println!("postgres_data_dir: {}", payload.postgres_data_dir.display());
        println!("backups_dir: {}", payload.backups_dir.display());
        println!("installations_dir: {}", payload.installations_dir.display());
        println!("runtime_dir: {}", payload.runtime_dir.display());
        println!("launcher_log_path: {}", payload.launcher_log_path.display());
        println!("app_log_path: {}", payload.app_log_path.display());
        println!("postgres_log_path: {}", payload.postgres_log_path.display());
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

pub async fn doctor_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    paths.ensure_dirs()?;
    println!("config: {}", paths.config_path.display());
    println!("app_dir: {}", resolve_app_dir(config)?.display());
    println!("postgres_data_dir: {}", config.postgres_data_dir.display());
    println!("postgres_version: {}", PG_VERSION);
    let admin = ensure_postgres_for_admin(paths, config).await?;
    println!("postgres_setup: ok");
    admin.finish().await;
    Ok(())
}

pub async fn daemon_command(paths: AppPaths, config: LauncherConfig, open: bool) -> Result<()> {
    paths.ensure_dirs()?;
    remove_file_if_exists(&paths.stop_request_path)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] daemon starting", timestamp()),
    )?;

    let mut pg = postgres_from_config(&paths, &config)?;
    if let Err(error) = pg
        .setup()
        .await
        .context("failed to setup embedded postgres")
    {
        append_log_line(
            &paths.launcher_log_path,
            &format!("[{}] daemon error: {error:#}", timestamp()),
        )
        .ok();
        return Err(error);
    }
    if let Err(error) = pg
        .start()
        .await
        .context("failed to start embedded postgres")
    {
        append_log_line(
            &paths.launcher_log_path,
            &format!("[{}] daemon error: {error:#}", timestamp()),
        )
        .ok();
        return Err(error);
    }
    ensure_database(&pg, &config).await?;
    let database_url = config.database_url(pg.settings());

    let mut app = start_app(&config, &database_url, &paths.app_log_path).await?;
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
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] daemon running", timestamp()),
    )?;

    let exit_result = daemon_loop(&paths, &mut app).await;
    let app_stop = stop_child(&mut app).await;
    let pg_stop = pg.stop().await.map_err(|error| anyhow!(error.to_string()));
    remove_file_if_exists(&paths.status_path)?;
    remove_file_if_exists(&paths.stop_request_path)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] daemon stopped", timestamp()),
    )?;

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

    let log = open_log_file(log_path)?;
    let log_err = log.try_clone().context("failed to clone app log handle")?;

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

pub fn postgres_from_config(paths: &AppPaths, config: &LauncherConfig) -> Result<PostgreSQL> {
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

struct AdminPostgres {
    postgres: Option<PostgreSQL>,
    started_here: bool,
}

impl AdminPostgres {
    fn postgres(&self) -> &PostgreSQL {
        self.postgres.as_ref().expect("postgres handle")
    }

    fn settings(&self) -> &Settings {
        self.postgres().settings()
    }

    async fn finish(mut self) {
        if let Some(postgres) = self.postgres.take() {
            if self.started_here {
                postgres.stop().await.ok();
            } else {
                std::mem::forget(postgres);
            }
        }
    }
}

impl Drop for AdminPostgres {
    fn drop(&mut self) {
        if !self.started_here {
            if let Some(postgres) = self.postgres.take() {
                std::mem::forget(postgres);
            }
        }
    }
}

async fn ensure_postgres_for_admin(
    paths: &AppPaths,
    config: &LauncherConfig,
) -> Result<AdminPostgres> {
    let mut pg = postgres_from_config(paths, config)?;
    if let Err(error) = pg.setup().await {
        if pg.status() == PostgresStatus::Started {
            std::mem::forget(pg);
        }
        return Err(anyhow!(error.to_string())).context("failed to setup embedded postgres");
    }
    let started_here = pg.status() != PostgresStatus::Started;
    if pg.status() != PostgresStatus::Started {
        pg.start().await?;
    }
    Ok(AdminPostgres {
        postgres: Some(pg),
        started_here,
    })
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
    let target = url::Url::parse(url).context("invalid app url")?;
    let host = target
        .host_str()
        .ok_or_else(|| anyhow!("missing app host"))?;
    let port = target.port().ok_or_else(|| anyhow!("missing app port"))?;
    let addr: SocketAddr = format!("{host}:{port}").parse()?;

    wait_for_tcp(addr, timeout)
        .await
        .with_context(|| format!("application did not open {url} within {timeout:?}"))
}

async fn wait_for_tcp(addr: SocketAddr, timeout: Duration) -> Result<()> {
    let started = Instant::now();
    while started.elapsed() < timeout {
        if std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    bail!("tcp port did not open within {:?}", timeout)
}

pub async fn build_status_payload(paths: &AppPaths, config: &LauncherConfig) -> StatusPayload {
    let status = read_status(&paths.status_path).ok();
    let daemon_alive = status
        .as_ref()
        .map(|status| process_alive(status.daemon_pid))
        .unwrap_or(false);
    let last_error = status.as_ref().and_then(|status| status.last_error.clone());

    let daemon = ServiceStatus {
        state: if daemon_alive {
            ServiceState::Running
        } else {
            ServiceState::Stopped
        },
        pid: status.as_ref().map(|status| status.daemon_pid),
        healthy: daemon_alive,
        detail: last_error.clone(),
        url: None,
        port: None,
    };

    let app_pid = status.as_ref().and_then(|status| status.app_pid);
    let app_process_alive = app_pid.map(process_alive).unwrap_or(false);
    let app_healthy = if app_process_alive || daemon_alive {
        wait_for_http(&config.app_url(), Duration::from_millis(500))
            .await
            .is_ok()
    } else {
        false
    };
    let app_state = if app_healthy {
        ServiceState::Running
    } else if app_process_alive || daemon_alive {
        match status.as_ref().map(|status| status.state.as_str()) {
            Some("error") => ServiceState::Error,
            _ => ServiceState::Starting,
        }
    } else {
        ServiceState::Stopped
    };

    let app = ServiceStatus {
        state: app_state,
        pid: app_pid,
        healthy: app_healthy,
        detail: if matches!(app_state, ServiceState::Error) {
            last_error.clone()
        } else {
            None
        },
        url: Some(config.app_url()),
        port: Some(config.app_port),
    };

    let postgres_pid =
        read_postgres_pid(&config.postgres_data_dir).filter(|pid| process_alive(*pid));
    let postgres_process_alive = postgres_pid.is_some();
    let postgres_tcp_open = tcp_port_open(("127.0.0.1", config.postgres_port));
    let postgres_state = if postgres_process_alive && postgres_tcp_open {
        ServiceState::Running
    } else if postgres_process_alive {
        ServiceState::Starting
    } else if config.postgres_data_dir.join("postgresql.conf").exists() {
        ServiceState::Stopped
    } else if paths.installations_dir.exists() {
        ServiceState::Installed
    } else {
        ServiceState::NotInstalled
    };
    let postgres_healthy = matches!(postgres_state, ServiceState::Running);

    let postgres = ServiceStatus {
        state: postgres_state,
        pid: postgres_pid,
        healthy: postgres_healthy,
        detail: None,
        url: None,
        port: Some(config.postgres_port),
    };

    StatusPayload {
        running: daemon_alive,
        daemon,
        app,
        postgres,
        status: status.filter(|_| daemon_alive),
        app_healthy,
        paths: paths_payload(paths, config),
    }
}

pub fn paths_payload(paths: &AppPaths, config: &LauncherConfig) -> PathsPayload {
    PathsPayload {
        config_path: paths.config_path.clone(),
        postgres_data_dir: config.postgres_data_dir.clone(),
        backups_dir: paths.backups_dir.clone(),
        installations_dir: paths.installations_dir.clone(),
        runtime_dir: paths.runtime_dir.clone(),
        log_path: paths.launcher_log_path.clone(),
        launcher_log_path: paths.launcher_log_path.clone(),
        app_log_path: paths.app_log_path.clone(),
        postgres_log_path: postgres_log_path(config),
        app_dir: config.app_dir.clone(),
    }
}

pub fn postgres_log_path(config: &LauncherConfig) -> PathBuf {
    config.postgres_data_dir.join("start.log")
}

pub fn log_path_for(paths: &AppPaths, config: &LauncherConfig, source: LogSource) -> PathBuf {
    match source {
        LogSource::All | LogSource::Launcher => paths.launcher_log_path.clone(),
        LogSource::App => paths.app_log_path.clone(),
        LogSource::Postgres => postgres_log_path(config),
    }
}

pub fn read_log(paths: &AppPaths, config: &LauncherConfig, source: LogSource) -> Result<String> {
    tail_file(&log_path_for(paths, config, source), 300)
}

pub fn open_log(paths: &AppPaths, config: &LauncherConfig, source: LogSource) -> Result<()> {
    open_path(&log_path_for(paths, config, source))
}

pub fn read_status(path: &Path) -> Result<RuntimeStatus> {
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

pub fn process_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
    #[cfg(not(unix))]
    {
        pid > 0
    }
}

fn read_postgres_pid(data_dir: &Path) -> Option<u32> {
    let pid_file = data_dir.join("postmaster.pid");
    let text = fs::read_to_string(pid_file).ok()?;
    text.lines().next()?.trim().parse().ok()
}

fn tcp_port_open(addr: (&str, u16)) -> bool {
    let Ok(socket_addr) = format!("{}:{}", addr.0, addr.1).parse::<SocketAddr>() else {
        return false;
    };
    std::net::TcpStream::connect_timeout(&socket_addr, Duration::from_millis(200)).is_ok()
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
