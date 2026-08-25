use std::env;
#[cfg(windows)]
use std::ffi::{OsStr, OsString};
use std::fs;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chrono::{SecondsFormat, Utc};
#[cfg(any(windows, test))]
use postgresql_commands::initdb::InitDbBuilder;
use postgresql_commands::pg_dump::PgDumpBuilder;
use postgresql_commands::pg_restore::PgRestoreBuilder;
use postgresql_commands::psql::PsqlBuilder;
use postgresql_commands::{AsyncCommandExecutor, CommandBuilder};
use postgresql_embedded::{PostgreSQL, Settings, Status as PostgresStatus};
use serde::Deserialize;
use tokio::io::AsyncWriteExt;
use tokio::process::{Child, Command};
use tracing::{info, warn};

use crate::cli::LogSource;
use crate::config::{
    bundled_postgres_dir, create_admin_command_path, release_command_path, resolve_app_dir,
    AppPaths, LauncherConfig, CONFIG_VERSION, PG_VERSION,
};
use crate::fs_utils::{
    append_log_line, atomic_write, copy_dir_all, is_empty_dir, open_log_file, open_path, open_url,
    remove_file_if_exists, tail_file, timestamp,
};
use crate::status::{PathsPayload, RuntimeStatus, ServiceState, ServiceStatus, StatusPayload};

const LOCAL_RESPONSES_HTTP_POOL_SIZE: &str = "500";

#[cfg(windows)]
const POSTGRES_SERVER_FILE: &str = "postgres.exe";
#[cfg(not(windows))]
const POSTGRES_SERVER_FILE: &str = "postgres";
#[cfg(windows)]
const INITDB_FILE: &str = "initdb.exe";
#[cfg(not(windows))]
const INITDB_FILE: &str = "initdb";
#[cfg(windows)]
const LIBPQ_SEGMENTS: &[&str] = &["bin", "libpq.dll"];
#[cfg(not(windows))]
const LIBPQ_SEGMENTS: &[&str] = &["lib", "libpq.5.dylib"];

#[derive(Clone, Copy, Debug)]
enum AppRequest {
    Start,
    Stop,
    Restart,
}

impl AppRequest {
    fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Stop => "stop",
            Self::Restart => "restart",
        }
    }
}

pub async fn start_command(paths: &AppPaths, config: &LauncherConfig, open: bool) -> Result<()> {
    paths.ensure_dirs()?;
    let current = read_status(&paths.status_path).ok();
    if let Some(status) = current
        .as_ref()
        .filter(|status| process_alive(status.daemon_pid))
    {
        let payload = build_status_payload(paths, config).await;
        if !payload.app.healthy {
            write_app_request(paths, AppRequest::Start)?;
            wait_for_application(paths, config, true, Duration::from_secs(90)).await?;
        }
        println!("Already running: {}", status.app_url);
        if open {
            open_url(&status.app_url)?;
        }
        return Ok(());
    }

    remove_file_if_exists(&paths.stop_request_path)?;
    remove_file_if_exists(&paths.app_request_path)?;
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

fn configure_background_release_process(cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.as_std_mut().creation_flags(CREATE_NO_WINDOW);
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

#[derive(Debug, Deserialize)]
struct CreateAdminResponse {
    ok: bool,
    username: Option<String>,
    message: Option<String>,
}

pub async fn create_admin_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    paths.ensure_dirs()?;
    let admin = ensure_postgres_for_admin(paths, config).await?;
    ensure_database(admin.postgres(), config).await?;
    let database_url = config.database_url(admin.settings());

    let result = async {
        let mut command = create_admin_release_command(config, &database_url)?;
        let status = command
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .await
            .context("failed to run create-admin release command")?;

        if status.success() {
            Ok(())
        } else {
            bail!("create-admin release command exited with {status}")
        }
    }
    .await;

    admin.finish().await;
    result
}

pub async fn create_admin_with_credentials(
    paths: &AppPaths,
    config: &LauncherConfig,
    username: &str,
    password: &str,
    password_confirmation: &str,
) -> Result<String> {
    paths.ensure_dirs()?;
    let admin = ensure_postgres_for_admin(paths, config).await?;
    ensure_database(admin.postgres(), config).await?;
    let database_url = config.database_url(admin.settings());

    let result = async {
        let payload = serde_json::to_vec(&serde_json::json!({
            "username": username,
            "password": password,
            "password_confirmation": password_confirmation,
        }))?;
        let mut command = create_admin_release_command(config, &database_url)?;
        let mut child = command
            .arg("--json-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("failed to run create-admin release command")?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("failed to open create-admin stdin"))?;
        stdin.write_all(&payload).await?;
        stdin.shutdown().await?;
        drop(stdin);

        let output = child.wait_with_output().await?;
        let response = parse_create_admin_response(&output.stdout, &output.stderr);

        if output.status.success() {
            let response = response.context("create-admin returned no JSON response")?;
            if !response.ok {
                bail!(
                    "{}",
                    response
                        .message
                        .unwrap_or_else(|| "create-admin failed".to_string())
                );
            }
            Ok(response.username.unwrap_or_else(|| username.to_string()))
        } else {
            let message = response
                .and_then(|response| response.message)
                .unwrap_or_else(|| command_output_message(&output.stderr, &output.stdout));
            bail!("{message}")
        }
    }
    .await;

    admin.finish().await;
    result
}

fn create_admin_release_command(config: &LauncherConfig, database_url: &str) -> Result<Command> {
    let app_dir = resolve_app_dir(config)?;
    let command_path = create_admin_command_path(&app_dir);
    if !command_path.exists() {
        bail!(
            "create-admin release command not found: {}",
            command_path.display()
        );
    }

    let mut command = Command::new(command_path);
    command
        .current_dir(&app_dir)
        .env("DATABASE_URL", database_url)
        .env("FILE_STORAGE_PATH", &config.files_data_dir)
        .env("PORT", config.app_port.to_string())
        .env("POOL_SIZE", "10")
        .env("RESPONSES_HTTP_POOL_SIZE", LOCAL_RESPONSES_HTTP_POOL_SIZE)
        .env("SECRET_KEY_BASE", &config.secret_key_base)
        .env("TOKEN_SIGNING_SECRET", &config.token_signing_secret);
    configure_background_release_process(&mut command);
    Ok(command)
}

fn parse_create_admin_response(stdout: &[u8], stderr: &[u8]) -> Option<CreateAdminResponse> {
    [stdout, stderr]
        .into_iter()
        .flat_map(|stream| {
            String::from_utf8_lossy(stream)
                .lines()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .rev()
        .find_map(|line| serde_json::from_str(&line).ok())
}

fn command_output_message(primary: &[u8], secondary: &[u8]) -> String {
    for output in [primary, secondary] {
        let message = String::from_utf8_lossy(output).trim().to_string();
        if !message.is_empty() {
            return message;
        }
    }
    "create-admin release command failed".to_string()
}

pub async fn start_application_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if !payload.daemon.healthy {
        start_command(paths, config, false).await?;
        return Ok(());
    }
    if payload.app.healthy {
        return Ok(());
    }

    write_app_request(paths, AppRequest::Start)?;
    wait_for_application(paths, config, true, Duration::from_secs(90)).await
}

pub async fn stop_application_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if !payload.daemon.healthy || matches!(payload.app.state, ServiceState::Stopped) {
        return Ok(());
    }

    write_app_request(paths, AppRequest::Stop)?;
    wait_for_application(paths, config, false, Duration::from_secs(30)).await
}

pub async fn restart_application_command(paths: &AppPaths, config: &LauncherConfig) -> Result<()> {
    let payload = build_status_payload(paths, config).await;
    if !payload.daemon.healthy {
        start_command(paths, config, false).await?;
        return Ok(());
    }
    let previous_pid = payload.app.pid;

    write_app_request(paths, AppRequest::Restart)?;
    wait_for_application_restart(paths, config, previous_pid, Duration::from_secs(90)).await
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
    let files_backup_path = files_backup_path_for(&backup_path);
    if files_backup_path.exists() {
        bail!(
            "files backup already exists: {}",
            files_backup_path.display()
        );
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
        "files": files_backup_path.file_name().and_then(|name| name.to_str()).unwrap_or_default(),
    });
    backup_files_dir(&config.files_data_dir, &files_backup_path)?;
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
    restore_files_dir_if_present(&files_backup_path_for(dump_path), &config.files_data_dir)?;

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

pub async fn move_files_data_command(
    paths: &AppPaths,
    config: &mut LauncherConfig,
    target: &Path,
    delete_source: bool,
) -> Result<()> {
    let source = config.files_data_dir.clone();
    if source == target {
        bail!("target files directory is already active");
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

    if source.exists() {
        copy_dir_all(&source, target)?;
    } else {
        fs::create_dir_all(target)
            .with_context(|| format!("failed to create {}", target.display()))?;
    }

    let previous = config.files_data_dir.clone();
    config.files_data_dir = target.to_path_buf();
    config.save(&paths.config_path)?;

    match start_command(paths, config, false).await {
        Ok(()) => {
            if delete_source && previous.exists() {
                fs::remove_dir_all(&previous)
                    .with_context(|| format!("failed to delete {}", previous.display()))?;
            }
            println!("Moved files to {}", target.display());
            Ok(())
        }
        Err(error) => {
            config.files_data_dir = previous;
            config.save(&paths.config_path)?;
            fs::remove_dir_all(target).ok();
            Err(error).context("moved files failed validation; restored previous config")
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
        println!("files_data_dir: {}", payload.files_data_dir.display());
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
    println!("files_data_dir: {}", config.files_data_dir.display());
    println!("postgres_version: {}", PG_VERSION);
    let admin = ensure_postgres_for_admin(paths, config).await?;
    println!("postgres_setup: ok");
    admin.finish().await;
    Ok(())
}

pub async fn daemon_command(paths: AppPaths, config: LauncherConfig, open: bool) -> Result<()> {
    paths.ensure_dirs()?;
    remove_file_if_exists(&paths.stop_request_path)?;
    remove_file_if_exists(&paths.app_request_path)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] daemon starting", timestamp()),
    )?;

    let pg = postgres_from_config(&paths, &config)?;
    let database_url = config.database_url(pg.settings());
    write_status(
        &paths.status_path,
        &RuntimeStatus {
            version: CONFIG_VERSION,
            daemon_pid: std::process::id(),
            app_pid: None,
            app_url: config.app_url(),
            database_url: database_url.clone(),
            postgres_data_dir: config.postgres_data_dir.clone(),
            files_data_dir: config.files_data_dir.clone(),
            started_at: timestamp(),
            updated_at: timestamp(),
            state: "starting".to_string(),
            last_error: None,
        },
    )?;

    let result = run_daemon(&paths, &config, open, pg, database_url).await;
    if let Err(error) = &result {
        let detail = format!("{error:#}");
        write_status_state(&paths.status_path, "error", Some(detail.clone())).ok();
        append_log_line(
            &paths.launcher_log_path,
            &format!("[{}] daemon error: {detail}", timestamp()),
        )
        .ok();
    }
    result
}

async fn run_daemon(
    paths: &AppPaths,
    config: &LauncherConfig,
    open: bool,
    mut pg: PostgreSQL,
    database_url: String,
) -> Result<()> {
    setup_postgres(&mut pg)
        .await
        .context("failed to setup embedded postgres")?;
    pg.start()
        .await
        .context("failed to start embedded postgres")?;
    ensure_database(&pg, config).await?;

    let mut app = Some(start_app(config, &database_url, &paths.app_log_path).await?);
    let app_pid = app.as_ref().and_then(|child| child.id());
    write_status(
        &paths.status_path,
        &RuntimeStatus {
            version: CONFIG_VERSION,
            daemon_pid: std::process::id(),
            app_pid,
            app_url: config.app_url(),
            database_url: database_url.clone(),
            postgres_data_dir: config.postgres_data_dir.clone(),
            files_data_dir: config.files_data_dir.clone(),
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

    let exit_result = daemon_loop(paths, config, &database_url, &mut app).await;
    let app_stop = stop_release_app(config, &mut app).await;
    let pg_stop = pg.stop().await.map_err(|error| anyhow!(error.to_string()));
    remove_file_if_exists(&paths.status_path)?;
    remove_file_if_exists(&paths.stop_request_path)?;
    remove_file_if_exists(&paths.app_request_path)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] daemon stopped", timestamp()),
    )?;

    exit_result?;
    app_stop?;
    pg_stop?;
    Ok(())
}

async fn daemon_loop(
    paths: &AppPaths,
    config: &LauncherConfig,
    database_url: &str,
    app: &mut Option<Child>,
) -> Result<()> {
    loop {
        if paths.stop_request_path.exists() {
            return Ok(());
        }

        if paths.app_request_path.exists() {
            handle_app_request(paths, config, database_url, app).await?;
        }

        if let Some(status) = poll_app_exit(app).context("failed to inspect app process")? {
            let message = format!("application exited with status {status}");
            write_status_app(&paths.status_path, None, "error", Some(message.clone())).ok();
            append_log_line(
                &paths.launcher_log_path,
                &format!("[{}] app error: {message}", timestamp()),
            )
            .ok();
        } else if let Some(pid) = app.as_ref().and_then(|child| child.id()) {
            write_status_app(&paths.status_path, Some(pid), "running", None).ok();
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn handle_app_request(
    paths: &AppPaths,
    config: &LauncherConfig,
    database_url: &str,
    app: &mut Option<Child>,
) -> Result<()> {
    let request = fs::read_to_string(&paths.app_request_path)
        .with_context(|| format!("failed to read {}", paths.app_request_path.display()))?;
    remove_file_if_exists(&paths.app_request_path)?;

    match request.trim() {
        "start" => start_daemon_app(paths, config, database_url, app).await,
        "stop" => stop_daemon_app(paths, config, app).await,
        "restart" => {
            stop_daemon_app(paths, config, app).await?;
            start_daemon_app(paths, config, database_url, app).await
        }
        value => {
            append_log_line(
                &paths.launcher_log_path,
                &format!("[{}] ignored unknown app request: {value}", timestamp()),
            )
            .ok();
            Ok(())
        }
    }
}

async fn start_daemon_app(
    paths: &AppPaths,
    config: &LauncherConfig,
    database_url: &str,
    app: &mut Option<Child>,
) -> Result<()> {
    if let Some(child) = app.as_mut() {
        if child.try_wait()?.is_none() {
            if let Some(pid) = child.id() {
                write_status_app(&paths.status_path, Some(pid), "running", None)?;
            }
            return Ok(());
        }
    }

    *app = None;
    write_status_app(&paths.status_path, None, "starting", None)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] app starting", timestamp()),
    )
    .ok();

    let child = start_app(config, database_url, &paths.app_log_path).await?;
    let app_pid = child.id();
    *app = Some(child);
    write_status_app(&paths.status_path, app_pid, "starting", None)?;
    wait_for_http(&config.app_url(), Duration::from_secs(90)).await?;
    write_status_app(&paths.status_path, app_pid, "running", None)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] app running", timestamp()),
    )
    .ok();
    Ok(())
}

async fn stop_daemon_app(
    paths: &AppPaths,
    config: &LauncherConfig,
    app: &mut Option<Child>,
) -> Result<()> {
    let app_pid = app.as_ref().and_then(|child| child.id());
    write_status_app(&paths.status_path, app_pid, "app_stopping", None).ok();
    stop_release_app(config, app).await?;
    write_status_app(&paths.status_path, None, "app_stopped", None)?;
    append_log_line(
        &paths.launcher_log_path,
        &format!("[{}] app stopped", timestamp()),
    )
    .ok();
    Ok(())
}

fn poll_app_exit(app: &mut Option<Child>) -> Result<Option<std::process::ExitStatus>> {
    let Some(child) = app.as_mut() else {
        return Ok(None);
    };
    let status = child.try_wait()?;
    if status.is_some() {
        *app = None;
    }
    Ok(status)
}

async fn start_app(config: &LauncherConfig, database_url: &str, log_path: &Path) -> Result<Child> {
    let app_dir = resolve_app_dir(config)?;
    let bin_path = release_command_path(&app_dir);
    if !bin_path.exists() {
        bail!("Phoenix release binary not found: {}", bin_path.display());
    }
    fs::create_dir_all(&config.files_data_dir)
        .with_context(|| format!("failed to create {}", config.files_data_dir.display()))?;
    let public_host = launcher_public_host();

    let log = open_log_file(log_path)?;
    let log_err = log.try_clone().context("failed to clone app log handle")?;

    let mut cmd = Command::new(bin_path);
    cmd.arg("start")
        .current_dir(&app_dir)
        .env("PHX_SERVER", "true")
        .env("PHX_IP", "127.0.0.1")
        .env("DATABASE_URL", database_url)
        .env("FILE_STORAGE_PATH", &config.files_data_dir)
        .env("PORT", config.app_port.to_string())
        .env("PHX_HOST", public_host)
        .env("PHX_SCHEME", "http")
        .env("PHX_PORT", config.app_port.to_string())
        .env("POOL_SIZE", "10")
        .env("RESPONSES_HTTP_POOL_SIZE", LOCAL_RESPONSES_HTTP_POOL_SIZE)
        .env("SECRET_KEY_BASE", &config.secret_key_base)
        .env("TOKEN_SIGNING_SECRET", &config.token_signing_secret)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    configure_background_release_process(&mut cmd);

    cmd.spawn().context("failed to start Phoenix release")
}

pub fn postgres_from_config(paths: &AppPaths, config: &LauncherConfig) -> Result<PostgreSQL> {
    Ok(PostgreSQL::new(postgres_settings_from_config(
        paths, config,
    )?))
}

fn postgres_settings_from_config(paths: &AppPaths, config: &LauncherConfig) -> Result<Settings> {
    let mut settings = Settings::default();
    settings.version = postgresql_embedded::VersionReq::parse(PG_VERSION)?;
    let (installation_dir, trust_installation_dir) =
        if let Some(installation_dir) = bundled_postgres_dir() {
            (installation_dir, true)
        } else {
            (paths.installations_dir.clone(), false)
        };
    settings.installation_dir = postgres_runtime_directory(&installation_dir)?;
    if trust_installation_dir {
        settings.trust_installation_dir = true;
    }
    settings.data_dir = postgres_runtime_directory(&config.postgres_data_dir)?;
    settings.password_file = postgres_runtime_directory(&paths.runtime_dir)?.join("pgpass");
    settings.host = "127.0.0.1".to_string();
    settings.port = config.postgres_port;
    settings.username = config.postgres_user.clone();
    settings.password = config.postgres_password.clone();
    settings.temporary = false;
    settings.timeout = Some(Duration::from_secs(120));
    settings
        .configuration
        .insert("listen_addresses".to_string(), "127.0.0.1".to_string());
    settings
        .configuration
        .insert("max_connections".to_string(), "100".to_string());
    Ok(settings)
}

#[cfg(windows)]
fn postgres_runtime_directory(path: &Path) -> Result<PathBuf> {
    fs::create_dir_all(path).with_context(|| {
        format!(
            "failed to create PostgreSQL data directory {}",
            path.display()
        )
    })?;

    let short_path = windows_short_path(path)?;
    if short_path.to_string_lossy().is_ascii() {
        return Ok(short_path);
    }

    // GetShortPathNameW returns the original Unicode path on volumes where
    // 8.3 names are disabled. PostgreSQL 16 still needs an ASCII path on
    // Windows, so use a session-scoped DOS drive alias as the fallback.
    postgres_ascii_drive_alias(path)
}

#[cfg(windows)]
fn windows_short_path(path: &Path) -> Result<PathBuf> {
    use std::ffi::OsString;
    use std::iter;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};

    use windows_sys::Win32::Storage::FileSystem::GetShortPathNameW;

    let wide = path
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    let required = unsafe { GetShortPathNameW(wide.as_ptr(), std::ptr::null_mut(), 0) };
    if required == 0 {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!(
                "failed to resolve the Windows short path for {}",
                path.display()
            )
        });
    }

    let mut buffer = vec![0_u16; required as usize];
    let written =
        unsafe { GetShortPathNameW(wide.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32) };
    if written == 0 || written as usize >= buffer.len() {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!(
                "failed to resolve the Windows short path for {}",
                path.display()
            )
        });
    }

    buffer.truncate(written as usize);
    Ok(PathBuf::from(OsString::from_wide(&buffer)))
}

#[cfg(windows)]
fn postgres_ascii_drive_alias(target: &Path) -> Result<PathBuf> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;

    use windows_sys::Win32::Storage::FileSystem::{
        DefineDosDeviceW, DDD_NO_BROADCAST_SYSTEM, DDD_RAW_TARGET_PATH,
    };

    let canonical = fs::canonicalize(target)
        .with_context(|| format!("failed to canonicalize {}", target.display()))?;
    let leaf = canonical
        .file_name()
        .filter(|value| value.to_string_lossy().is_ascii())
        .ok_or_else(|| {
            anyhow!(
                "PostgreSQL requires an ASCII final path component: {}",
                canonical.display()
            )
        })?;
    let parent = canonical.parent().ok_or_else(|| {
        anyhow!(
            "PostgreSQL cannot use a drive root as its runtime directory: {}",
            canonical.display()
        )
    })?;
    let device_target = windows_dos_device_target(parent)?;
    let target_text = OsString::from_wide(&device_target[..device_target.len() - 1]);
    let mut available = None;
    for letter in ('D'..='Z').rev() {
        let device = format!("{letter}:");
        match query_windows_dos_device(&device)? {
            Some(targets) => {
                if targets
                    .iter()
                    .any(|existing| windows_paths_equal(existing, &target_text))
                {
                    return Ok(PathBuf::from(format!("{device}\\")).join(leaf));
                }
            }
            None if available.is_none() => available = Some((letter, device)),
            None => {}
        }
    }

    let (letter, device) = available.ok_or_else(|| {
        anyhow!(
            "PostgreSQL requires an ASCII path, but no drive letter is available for {}",
            target_text.to_string_lossy()
        )
    })?;
    let device_wide = wide_null(OsStr::new(&device))?;
    let defined = unsafe {
        DefineDosDeviceW(
            DDD_RAW_TARGET_PATH | DDD_NO_BROADCAST_SYSTEM,
            device_wide.as_ptr(),
            device_target.as_ptr(),
        )
    };
    if defined == 0 {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!(
                "failed to create PostgreSQL drive alias {device} for {}",
                target_text.to_string_lossy()
            )
        });
    }

    let mapped = query_windows_dos_device(&device)?.is_some_and(|targets| {
        targets
            .iter()
            .any(|value| windows_paths_equal(value, &target_text))
    });
    if !mapped {
        remove_windows_dos_device(letter, device_target.as_slice())?;
        bail!(
            "PostgreSQL drive alias {device} did not resolve to {}",
            target_text.to_string_lossy()
        );
    }
    Ok(PathBuf::from(format!("{device}\\")).join(leaf))
}

#[cfg(windows)]
fn windows_dos_device_target(path: &Path) -> Result<Vec<u16>> {
    let canonical = fs::canonicalize(path)
        .with_context(|| format!("failed to canonicalize {}", path.display()))?;
    let canonical = canonical.to_string_lossy();
    let target = if let Some(path) = canonical.strip_prefix(r"\\?\UNC\") {
        format!(r"\??\UNC\{path}")
    } else if let Some(path) = canonical.strip_prefix(r"\\?\") {
        format!(r"\??\{path}")
    } else if let Some(path) = canonical.strip_prefix(r"\\") {
        format!(r"\??\UNC\{path}")
    } else {
        format!(r"\??\{canonical}")
    };
    wide_null(OsStr::new(&target))
}

#[cfg(windows)]
fn query_windows_dos_device(device: &str) -> Result<Option<Vec<OsString>>> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;

    use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows_sys::Win32::Storage::FileSystem::QueryDosDeviceW;

    let device_wide = wide_null(OsStr::new(device))?;
    let mut buffer = vec![0_u16; 32_768];
    let written = unsafe {
        QueryDosDeviceW(
            device_wide.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
        )
    };
    if written == 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_FILE_NOT_FOUND as i32) {
            return Ok(None);
        }
        return Err(error)
            .with_context(|| format!("failed to inspect Windows DOS device {device}"));
    }
    buffer.truncate(written as usize);
    Ok(Some(
        buffer
            .split(|unit| *unit == 0)
            .filter(|value| !value.is_empty())
            .map(OsString::from_wide)
            .collect(),
    ))
}

#[cfg(windows)]
fn remove_windows_dos_device(letter: char, target: &[u16]) -> Result<()> {
    use windows_sys::Win32::Storage::FileSystem::{
        DefineDosDeviceW, DDD_EXACT_MATCH_ON_REMOVE, DDD_NO_BROADCAST_SYSTEM, DDD_RAW_TARGET_PATH,
        DDD_REMOVE_DEFINITION,
    };

    let device = format!("{letter}:");
    let device_wide = wide_null(OsStr::new(&device))?;
    let removed = unsafe {
        DefineDosDeviceW(
            DDD_RAW_TARGET_PATH
                | DDD_REMOVE_DEFINITION
                | DDD_EXACT_MATCH_ON_REMOVE
                | DDD_NO_BROADCAST_SYSTEM,
            device_wide.as_ptr(),
            target.as_ptr(),
        )
    };
    if removed == 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("failed to remove Windows DOS device {device}"));
    }
    Ok(())
}

#[cfg(windows)]
fn windows_paths_equal(left: &OsStr, right: &OsStr) -> bool {
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

#[cfg(windows)]
fn wide_null(value: &OsStr) -> Result<Vec<u16>> {
    use std::os::windows::ffi::OsStrExt;

    let mut wide = value.encode_wide().collect::<Vec<_>>();
    if wide.contains(&0) {
        bail!("Windows path contains a NUL character");
    }
    wide.push(0);
    Ok(wide)
}

#[cfg(not(windows))]
fn postgres_runtime_directory(path: &Path) -> Result<PathBuf> {
    Ok(path.to_path_buf())
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
    if let Err(error) = setup_postgres(&mut pg).await {
        if pg.status() == PostgresStatus::Started {
            std::mem::forget(pg);
        }
        return Err(error).context("failed to setup embedded postgres");
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

async fn setup_postgres(postgres: &mut PostgreSQL) -> Result<()> {
    prepare_postgres_cluster(postgres.settings()).await?;
    postgres
        .setup()
        .await
        .map_err(|error| anyhow!(error.to_string()))
}

#[cfg(windows)]
async fn prepare_postgres_cluster(settings: &Settings) -> Result<()> {
    if !settings.trust_installation_dir || settings.data_dir.join("postgresql.conf").is_file() {
        return Ok(());
    }

    prepare_postgres_data_directory_for_initdb(&settings.data_dir)?;
    if let Some(parent) = settings.password_file.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    fs::write(&settings.password_file, settings.password.as_bytes()).with_context(|| {
        format!(
            "failed to write PostgreSQL password file {}",
            settings.password_file.display()
        )
    })?;

    let mut command = windows_initdb_command(settings);
    execute_pg_command(&mut command, settings.timeout)
        .await
        .context("failed to initialize PostgreSQL with the ICU locale")
}

#[cfg(windows)]
fn prepare_postgres_data_directory_for_initdb(path: &Path) -> Result<()> {
    let mut entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| {
                format!(
                    "failed to inspect PostgreSQL data directory {}",
                    path.display()
                )
            });
        }
    };

    match entries.next() {
        None => fs::remove_dir(path).with_context(|| {
            format!(
                "failed to remove empty PostgreSQL data directory {} before initialization",
                path.display()
            )
        })?,
        Some(Ok(_)) => {}
        Some(Err(error)) => {
            return Err(error).with_context(|| {
                format!(
                    "failed to inspect PostgreSQL data directory {}",
                    path.display()
                )
            });
        }
    }
    Ok(())
}

#[cfg(not(windows))]
async fn prepare_postgres_cluster(_settings: &Settings) -> Result<()> {
    Ok(())
}

#[cfg(any(windows, test))]
fn windows_initdb_command(settings: &Settings) -> Command {
    InitDbBuilder::from(settings)
        .pgdata(&settings.data_dir)
        .username("postgres")
        .auth("password")
        .pwfile(&settings.password_file)
        .encoding("UTF8")
        .locale("C")
        .locale_provider("icu")
        .icu_locale("en-US")
        .build_tokio()
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
        if let Some(status) = daemon
            .try_wait()
            .context("failed to inspect launcher daemon")?
        {
            bail!("launcher daemon exited before becoming ready: {status}");
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

async fn wait_for_application(
    paths: &AppPaths,
    config: &LauncherConfig,
    should_run: bool,
    timeout: Duration,
) -> Result<()> {
    let started = Instant::now();
    while started.elapsed() < timeout {
        let payload = build_status_payload(paths, config).await;
        if should_run {
            if payload.app.healthy {
                return Ok(());
            }
        } else if matches!(payload.app.state, ServiceState::Stopped) {
            return Ok(());
        }

        if !payload.daemon.healthy {
            bail!("launcher daemon stopped while waiting for application");
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    if should_run {
        bail!("application did not start within {:?}", timeout)
    } else {
        bail!("application did not stop within {:?}", timeout)
    }
}

async fn wait_for_application_restart(
    paths: &AppPaths,
    config: &LauncherConfig,
    previous_pid: Option<u32>,
    timeout: Duration,
) -> Result<()> {
    let started = Instant::now();
    let mut saw_restart = previous_pid.is_none();
    while started.elapsed() < timeout {
        let payload = build_status_payload(paths, config).await;
        if previous_pid.is_some() && payload.app.pid != previous_pid {
            saw_restart = true;
        }
        if saw_restart && payload.app.healthy {
            return Ok(());
        }
        if !payload.daemon.healthy {
            bail!("launcher daemon stopped while waiting for application restart");
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    bail!("application did not restart within {:?}", timeout)
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
    let runtime_state = status.as_ref().map(|status| status.state.as_str());
    let app_state = if app_healthy {
        ServiceState::Running
    } else if matches!(runtime_state, Some("error")) {
        ServiceState::Error
    } else if matches!(runtime_state, Some("app_stopped")) {
        ServiceState::Stopped
    } else if app_process_alive || daemon_alive {
        match runtime_state {
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
    let postgres_installed = postgres_settings_from_config(paths, config)
        .map(|settings| postgres_installation_ready(&settings))
        .unwrap_or(false);
    let postgres_state = if postgres_process_alive && postgres_tcp_open {
        ServiceState::Running
    } else if postgres_process_alive {
        ServiceState::Starting
    } else if !postgres_installed {
        ServiceState::NotInstalled
    } else if config.postgres_data_dir.join("postgresql.conf").exists() {
        ServiceState::Stopped
    } else {
        ServiceState::Installed
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

fn postgres_installation_ready(settings: &Settings) -> bool {
    let binary_dir = settings.binary_dir();
    binary_dir.join(POSTGRES_SERVER_FILE).is_file()
        && binary_dir.join(INITDB_FILE).is_file()
        && LIBPQ_SEGMENTS
            .iter()
            .fold(settings.installation_dir.clone(), |path, segment| {
                path.join(segment)
            })
            .is_file()
}

pub fn paths_payload(paths: &AppPaths, config: &LauncherConfig) -> PathsPayload {
    let postgres_installation_dir =
        bundled_postgres_dir().unwrap_or_else(|| paths.installations_dir.clone());
    PathsPayload {
        config_path: paths.config_path.clone(),
        postgres_data_dir: config.postgres_data_dir.clone(),
        files_data_dir: config.files_data_dir.clone(),
        backups_dir: paths.backups_dir.clone(),
        installations_dir: postgres_installation_dir,
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

fn files_backup_path_for(dump_path: &Path) -> PathBuf {
    dump_path.with_extension("files")
}

fn backup_files_dir(source: &Path, target: &Path) -> Result<()> {
    if source.exists() {
        copy_dir_all(source, target)
    } else {
        fs::create_dir_all(target).with_context(|| format!("failed to create {}", target.display()))
    }
}

fn restore_files_dir_if_present(source: &Path, target: &Path) -> Result<()> {
    if !source.exists() {
        return Ok(());
    }
    if !source.is_dir() {
        bail!("files backup is not a directory: {}", source.display());
    }
    if target.exists() {
        fs::remove_dir_all(target)
            .with_context(|| format!("failed to remove {}", target.display()))?;
    }
    copy_dir_all(source, target)
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
    let contents = serde_json::to_string_pretty(status)? + "\n";
    atomic_write(path, contents.as_bytes())
}

fn write_status_state(path: &Path, state: &str, last_error: Option<String>) -> Result<()> {
    let mut status = read_status(path)?;
    status.state = state.to_string();
    status.updated_at = timestamp();
    status.last_error = last_error;
    write_status(path, &status)
}

fn write_status_app(
    path: &Path,
    app_pid: Option<u32>,
    state: &str,
    last_error: Option<String>,
) -> Result<()> {
    let mut status = read_status(path)?;
    status.app_pid = app_pid;
    status.state = state.to_string();
    status.updated_at = timestamp();
    status.last_error = last_error;
    write_status(path, &status)
}

fn write_app_request(paths: &AppPaths, request: AppRequest) -> Result<()> {
    paths.ensure_dirs()?;
    fs::write(&paths.app_request_path, request.as_str())
        .with_context(|| format!("failed to write {}", paths.app_request_path.display()))
}

async fn stop_app_child(app: &mut Option<Child>) -> Result<()> {
    if let Some(child) = app.as_mut() {
        stop_child(child).await?;
    }
    *app = None;
    Ok(())
}

async fn stop_release_app(config: &LauncherConfig, app: &mut Option<Child>) -> Result<()> {
    #[cfg(not(windows))]
    let _ = config;

    let Some(child) = app.as_mut() else {
        return Ok(());
    };
    if child.try_wait()?.is_some() {
        *app = None;
        return Ok(());
    }

    #[cfg(windows)]
    {
        if let Err(error) = request_windows_release_stop(config).await {
            warn!("graceful Windows release stop failed: {error:#}");
        } else {
            let stopped = tokio::time::timeout(Duration::from_secs(15), child.wait())
                .await
                .is_ok();
            if stopped {
                *app = None;
                return Ok(());
            }
            warn!("Windows release did not exit after its stop command; killing its process tree");
        }
    }

    stop_app_child(app).await
}

#[cfg(windows)]
async fn request_windows_release_stop(config: &LauncherConfig) -> Result<()> {
    let app_dir = resolve_app_dir(config)?;
    let bin_path = release_command_path(&app_dir);
    let mut command = Command::new(&bin_path);
    command
        .arg("stop")
        .current_dir(&app_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    configure_background_release_process(&mut command);

    let status = tokio::time::timeout(Duration::from_secs(15), command.status())
        .await
        .context("timed out while stopping the Windows BEAM release")?
        .with_context(|| format!("failed to execute {} stop", bin_path.display()))?;
    if !status.success() {
        bail!("{} stop exited with status {status}", bin_path.display());
    }
    Ok(())
}

async fn stop_child(child: &mut Child) -> Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }

    #[cfg(windows)]
    if let Some(pid) = child.id() {
        let taskkill = Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
        if let Err(error) = taskkill {
            warn!("failed to invoke taskkill for application process tree {pid}: {error}");
        }
        if tokio::time::timeout(Duration::from_secs(10), child.wait())
            .await
            .is_ok()
        {
            return Ok(());
        }
    }

    child.start_kill().context("failed to stop app process")?;
    let _ = child.wait().await;
    Ok(())
}

pub fn process_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let result = unsafe { libc::kill(pid as i32, 0) };
        let errno = (result != 0)
            .then(|| std::io::Error::last_os_error().raw_os_error())
            .flatten();
        process_alive_from_kill_result(result, errno)
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
        use windows_sys::Win32::System::Threading::{
            GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        };

        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if handle.is_null() {
            return false;
        }

        let mut exit_code = 0u32;
        let queried = unsafe { GetExitCodeProcess(handle, &mut exit_code) } != 0;
        unsafe {
            CloseHandle(handle);
        }
        queried && exit_code == STILL_ACTIVE as u32
    }
}

#[cfg(unix)]
fn process_alive_from_kill_result(result: i32, errno: Option<i32>) -> bool {
    result == 0 || errno == Some(libc::EPERM)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Locale;

    #[cfg(unix)]
    #[test]
    fn process_probe_treats_permission_denied_as_alive() {
        assert!(process_alive_from_kill_result(0, None));
        assert!(process_alive_from_kill_result(-1, Some(libc::EPERM)));
        assert!(!process_alive_from_kill_result(-1, Some(libc::ESRCH)));
    }

    #[cfg(windows)]
    #[test]
    fn process_probe_tracks_windows_process_lifecycle() {
        let mut child = std::process::Command::new("ping.exe")
            .args(["-n", "30", "127.0.0.1"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();

        assert!(process_alive(pid));
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!process_alive(pid));
        assert!(!process_alive(u32::MAX));
    }

    #[test]
    fn files_backup_path_replaces_dump_extension() {
        assert_eq!(
            files_backup_path_for(Path::new("/tmp/intellectual-club.dump")),
            PathBuf::from("/tmp/intellectual-club.files")
        );
    }

    #[test]
    fn empty_postgres_directory_is_not_an_installation() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-empty-postgres-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();

        let mut settings = Settings::default();
        settings.installation_dir = root.clone();
        settings.trust_installation_dir = true;
        assert!(!postgres_installation_ready(&settings));

        fs::create_dir_all(root.join("bin")).unwrap();
        let libpq_path = LIBPQ_SEGMENTS
            .iter()
            .fold(root.clone(), |path, segment| path.join(segment));
        fs::create_dir_all(libpq_path.parent().unwrap()).unwrap();
        fs::write(root.join("bin").join(POSTGRES_SERVER_FILE), b"postgres").unwrap();
        fs::write(root.join("bin").join(INITDB_FILE), b"initdb").unwrap();
        fs::write(libpq_path, b"libpq").unwrap();
        assert!(postgres_installation_ready(&settings));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn windows_initdb_command_uses_utf8_and_icu() {
        let mut settings = Settings::default();
        settings.installation_dir = PathBuf::from(r"C:\portable\postgresql");
        settings.data_dir = PathBuf::from(r"C:\profile with spaces\postgres\data");
        settings.password_file = PathBuf::from(r"C:\profile with spaces\runtime\pgpass");

        let command = windows_initdb_command(&settings);
        let command = command.as_std();
        let args = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        assert_eq!(command.get_program(), settings.binary_dir().join("initdb"));
        assert!(args.windows(2).any(|pair| pair == ["--encoding", "UTF8"]));
        assert!(args.windows(2).any(|pair| pair == ["--locale", "C"]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--locale-provider", "icu"]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--icu-locale", "en-US"]));
        assert!(args.windows(2).any(|pair| {
            pair[0] == "--pgdata" && pair[1] == settings.data_dir.to_string_lossy()
        }));
    }

    #[cfg(windows)]
    #[test]
    fn initdb_preparation_removes_only_an_empty_aliased_data_directory() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-initdb-directory-test-{}",
            std::process::id()
        ));
        let target = root.join("кириллица").join("data");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&target).unwrap();
        let alias = postgres_ascii_drive_alias(&target).unwrap();

        prepare_postgres_data_directory_for_initdb(&alias).unwrap();
        assert!(!target.exists());

        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("PG_VERSION"), "16").unwrap();
        prepare_postgres_data_directory_for_initdb(&alias).unwrap();
        assert!(target.join("PG_VERSION").is_file());

        let target_device = windows_dos_device_target(target.parent().unwrap()).unwrap();
        let letter = alias.to_string_lossy().chars().next().unwrap();
        remove_windows_dos_device(letter, &target_device).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn postgres_runtime_directory_uses_an_ascii_alias_for_unicode_paths() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-кириллица-{}",
            std::process::id()
        ));
        let data_dir = root.join("postgres").join("data");
        let _ = fs::remove_dir_all(&root);

        let runtime_dir = postgres_runtime_directory(&data_dir).unwrap();
        assert!(runtime_dir.to_string_lossy().is_ascii());
        assert_eq!(
            fs::canonicalize(&runtime_dir).unwrap(),
            fs::canonicalize(&data_dir).unwrap()
        );

        let _ = fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn postgres_ascii_drive_alias_is_stable_and_resolves_to_its_target() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-drive-alias-test-{}",
            std::process::id()
        ));
        let target = root.join("кириллица").join("postgres");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&target).unwrap();

        let alias = postgres_ascii_drive_alias(&target).unwrap();
        assert!(alias.to_string_lossy().is_ascii());
        assert_eq!(alias.file_name(), Some(OsStr::new("postgres")));
        fs::write(target.join("probe.txt"), "drive alias").unwrap();
        assert_eq!(
            fs::read_to_string(alias.join("probe.txt")).unwrap(),
            "drive alias"
        );
        assert_eq!(postgres_ascii_drive_alias(&target).unwrap(), alias);

        let target_device = windows_dos_device_target(target.parent().unwrap()).unwrap();
        let letter = alias.to_string_lossy().chars().next().unwrap();
        remove_windows_dos_device(letter, &target_device).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn failed_daemon_status_is_reported_to_the_interface() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-error-status-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let runtime_dir = root.join("runtime");
        fs::create_dir_all(&runtime_dir).unwrap();
        let paths = AppPaths {
            config_path: root.join("launcher.json"),
            default_data_dir: root.join("postgres").join("data"),
            default_files_data_dir: root.join("files"),
            backups_dir: root.join("backups"),
            installations_dir: root.join("installations"),
            runtime_dir: runtime_dir.clone(),
            status_path: runtime_dir.join("status.json"),
            stop_request_path: runtime_dir.join("stop-request"),
            app_request_path: runtime_dir.join("app-request"),
            launcher_log_path: runtime_dir.join("launcher.log"),
            app_log_path: runtime_dir.join("app.log"),
        };
        let mut config = LauncherConfig::default_for(&paths);
        config.app_port = 1;
        config.postgres_port = 1;
        let error = "failed to setup embedded postgres: Library not loaded";
        write_status(
            &paths.status_path,
            &RuntimeStatus {
                version: CONFIG_VERSION,
                daemon_pid: u32::MAX,
                app_pid: None,
                app_url: config.app_url(),
                database_url: "postgresql://localhost/postgres".to_string(),
                postgres_data_dir: config.postgres_data_dir.clone(),
                files_data_dir: config.files_data_dir.clone(),
                started_at: timestamp(),
                updated_at: timestamp(),
                state: "error".to_string(),
                last_error: Some(error.to_string()),
            },
        )
        .unwrap();

        let payload = build_status_payload(&paths, &config).await;
        assert_eq!(payload.app.state, ServiceState::Error);
        assert_eq!(payload.app.detail.as_deref(), Some(error));
        assert_eq!(payload.daemon.detail.as_deref(), Some(error));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn create_admin_release_command_uses_release_path_and_database_environment() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-create-admin-command-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("bin")).unwrap();
        let create_admin_path = create_admin_command_path(&root);
        fs::write(&create_admin_path, b"release command\n").unwrap();

        let config = LauncherConfig {
            version: CONFIG_VERSION,
            app_dir: Some(root.clone()),
            postgres_data_dir: root.join("postgres"),
            files_data_dir: root.join("files"),
            postgres_port: 55432,
            app_port: 4000,
            database_name: "intellectual_club".to_string(),
            postgres_user: "postgres".to_string(),
            postgres_password: "postgres-password".to_string(),
            secret_key_base: "secret-key-base".to_string(),
            token_signing_secret: "token-signing-secret".to_string(),
            locale: Locale::En,
        };
        let database_url = "postgresql://postgres:password@127.0.0.1:55432/intellectual_club";

        let command = create_admin_release_command(&config, database_url).unwrap();
        let command = command.as_std();
        assert_eq!(command.get_program(), create_admin_path);
        assert_eq!(command.get_current_dir(), Some(root.as_path()));
        assert!(command.get_envs().any(|(key, value)| {
            key == "DATABASE_URL" && value == Some(std::ffi::OsStr::new(database_url))
        }));
        assert!(command.get_envs().any(|(key, value)| {
            key == "FILE_STORAGE_PATH" && value == Some(config.files_data_dir.as_os_str())
        }));
        assert!(command.get_envs().any(|(key, value)| {
            key == "RESPONSES_HTTP_POOL_SIZE"
                && value == Some(std::ffi::OsStr::new(LOCAL_RESPONSES_HTTP_POOL_SIZE))
        }));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn create_admin_response_is_parsed_from_command_output() {
        let response = parse_create_admin_response(
            b"migration log\n{\"ok\":true,\"username\":\"admin\"}\n",
            b"",
        )
        .unwrap();

        assert!(response.ok);
        assert_eq!(response.username.as_deref(), Some("admin"));
    }

    #[test]
    fn file_backup_and_restore_copy_directories() {
        let root = std::env::temp_dir().join(format!(
            "intellectual-club-launcher-files-backup-{}",
            std::process::id()
        ));
        let source = root.join("source");
        let backup = root.join("backup.files");
        let target = root.join("target");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(source.join("aa").join("bb")).unwrap();
        fs::write(
            source.join("aa").join("bb").join("payload.blob"),
            b"payload",
        )
        .unwrap();

        backup_files_dir(&source, &backup).unwrap();
        assert_eq!(
            fs::read(backup.join("aa").join("bb").join("payload.blob")).unwrap(),
            b"payload"
        );

        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("stale.blob"), b"stale").unwrap();
        restore_files_dir_if_present(&backup, &target).unwrap();

        assert!(!target.join("stale.blob").exists());
        assert_eq!(
            fs::read(target.join("aa").join("bb").join("payload.blob")).unwrap(),
            b"payload"
        );

        let _ = fs::remove_dir_all(root);
    }
}
