mod cli;
mod config;
mod fs_utils;
mod gui;
mod operations;
mod status;

use anyhow::{anyhow, Result};
use clap::Parser;
use tracing_subscriber::EnvFilter;

use crate::cli::{Args, CommandKind};
use crate::config::{AppPaths, LauncherConfig};
use crate::gui::run_gui;
use crate::operations::{
    backup_command, daemon_command, doctor_command, logs_command, move_data_command,
    move_files_data_command, open_command, paths_command, restore_command, start_command,
    status_command, stop_command,
};

fn main() -> Result<()> {
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

    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async move {
        match command {
            CommandKind::Start { open } => start_command(&paths, &config, open).await,
            CommandKind::Stop => stop_command(&paths, &config).await,
            CommandKind::Restart { open } => {
                stop_command(&paths, &config).await?;
                start_command(&paths, &config, open).await
            }
            CommandKind::Status { json } => status_command(&paths, &config, json).await,
            CommandKind::Logs { source, lines } => logs_command(&paths, &config, source, lines),
            CommandKind::Open => open_command(&paths, &config).await,
            CommandKind::Backup { output } => backup_command(&paths, &config, output)
                .await
                .map(|path| println!("{}", path.display())),
            CommandKind::Restore { path, force } => {
                restore_command(&paths, &config, &path, force).await
            }
            CommandKind::MoveData { to, delete_source } => {
                move_data_command(&paths, &mut config, &to, delete_source).await
            }
            CommandKind::MoveFiles { to, delete_source } => {
                move_files_data_command(&paths, &mut config, &to, delete_source).await
            }
            CommandKind::Paths { json } => paths_command(&paths, &config, json),
            CommandKind::Doctor => doctor_command(&paths, &config).await,
            CommandKind::Daemon { open } => daemon_command(paths, config, open).await,
        }
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{
        Locale, TextKey, CONFIG_VERSION, DATABASE_NAME, DEFAULT_PORT, DEFAULT_POSTGRES_PORT,
    };
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn app_url_uses_configured_port() {
        let paths = AppPaths::discover().unwrap();
        let mut config = LauncherConfig::default_for(&paths);
        config.app_port = 4999;
        assert_eq!(config.app_url(), "http://127.0.0.1:4999");
        assert_eq!(config.files_data_dir, paths.default_files_data_dir);
    }

    #[test]
    fn localized_labels_exist() {
        assert_eq!(Locale::Ru.text(TextKey::Start), "Запустить");
        assert_eq!(Locale::En.text(TextKey::Start), "Start");
        assert_eq!(Locale::Ru.text(TextKey::AppLog), "Лог приложения");
        assert_eq!(Locale::En.text(TextKey::PostgresLog), "Postgres log");
        assert_eq!(Locale::Ru.text(TextKey::FilesDataDir), "Файлы");
        assert_eq!(Locale::En.text(TextKey::MoveFilesData), "Move files");
    }

    #[test]
    fn old_config_is_migrated_with_files_data_dir() {
        let root = unique_temp_dir("config-migration");
        let _ = fs::remove_dir_all(&root);
        let paths = test_paths(&root);
        paths.ensure_dirs().unwrap();

        let old_config = serde_json::json!({
            "version": 1,
            "app_dir": null,
            "postgres_data_dir": paths.default_data_dir,
            "postgres_port": DEFAULT_POSTGRES_PORT,
            "app_port": DEFAULT_PORT,
            "database_name": DATABASE_NAME,
            "postgres_user": "postgres",
            "postgres_password": "pg-abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
            "secret_key_base": "sk-abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
            "token_signing_secret": "tok-abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
            "locale": "en"
        });
        fs::write(
            &paths.config_path,
            serde_json::to_string_pretty(&old_config).unwrap(),
        )
        .unwrap();

        let config = LauncherConfig::load_or_default(&paths.config_path, &paths).unwrap();
        assert_eq!(config.version, CONFIG_VERSION);
        assert_eq!(config.files_data_dir, paths.default_files_data_dir);

        let saved = fs::read_to_string(&paths.config_path).unwrap();
        assert!(saved.contains("files_data_dir"));

        let _ = fs::remove_dir_all(root);
    }

    fn unique_temp_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "intellectual-club-launcher-{name}-{}",
            std::process::id()
        ))
    }

    fn test_paths(root: &std::path::Path) -> AppPaths {
        let runtime_dir = root.join("runtime");
        AppPaths {
            config_path: root.join("config").join("launcher.json"),
            default_data_dir: root.join("postgres").join("data"),
            default_files_data_dir: root.join("files"),
            backups_dir: root.join("backups"),
            installations_dir: root.join("cache").join("postgres").join("installations"),
            status_path: runtime_dir.join("status.json"),
            stop_request_path: runtime_dir.join("stop-request"),
            app_request_path: runtime_dir.join("app-request"),
            launcher_log_path: runtime_dir.join("launcher.log"),
            app_log_path: runtime_dir.join("app.log"),
            runtime_dir,
        }
    }
}
