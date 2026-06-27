use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};

pub const APP_NAME: &str = "intellectual_club";
pub const DATABASE_NAME: &str = "intellectual_club";
pub const PG_VERSION: &str = "=16.13.0";
pub const DEFAULT_PORT: u16 = 4000;
pub const DEFAULT_POSTGRES_PORT: u16 = 55432;
pub const CONFIG_VERSION: u32 = 1;

#[derive(Clone, Debug)]
pub struct AppPaths {
    pub config_path: PathBuf,
    pub default_data_dir: PathBuf,
    pub backups_dir: PathBuf,
    pub installations_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub status_path: PathBuf,
    pub stop_request_path: PathBuf,
    pub launcher_log_path: PathBuf,
    pub app_log_path: PathBuf,
}

impl AppPaths {
    pub fn discover() -> Result<Self> {
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
            launcher_log_path: runtime_dir.join("launcher.log"),
            app_log_path: runtime_dir.join("app.log"),
            runtime_dir,
        })
    }

    pub fn ensure_dirs(&self) -> Result<()> {
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
pub struct LauncherConfig {
    pub version: u32,
    pub app_dir: Option<PathBuf>,
    pub postgres_data_dir: PathBuf,
    pub postgres_port: u16,
    pub app_port: u16,
    pub database_name: String,
    pub postgres_user: String,
    pub postgres_password: String,
    pub secret_key_base: String,
    pub token_signing_secret: String,
    pub locale: Locale,
}

impl LauncherConfig {
    pub fn load_or_default(path: &Path, paths: &AppPaths) -> Result<Self> {
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

    pub fn default_for(paths: &AppPaths) -> Self {
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

    pub fn save(&self, path: &Path) -> Result<()> {
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

    pub fn app_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.app_port)
    }

    pub fn database_url(&self, settings: &postgresql_embedded::Settings) -> String {
        settings.url(&self.database_name)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Locale {
    En,
    Ru,
}

impl Locale {
    pub fn from_env() -> Self {
        let lang = env::var("LANG").unwrap_or_default().to_lowercase();
        if lang.starts_with("ru") {
            Self::Ru
        } else {
            Self::En
        }
    }

    pub fn text(self, key: TextKey) -> &'static str {
        match (self, key) {
            (Self::Ru, TextKey::Title) => "Intellectual Club",
            (Self::Ru, TextKey::Overview) => "Обзор",
            (Self::Ru, TextKey::BackupRestore) => "Бэкап / рестор",
            (Self::Ru, TextKey::Paths) => "Пути",
            (Self::Ru, TextKey::Logs) => "Логи",
            (Self::Ru, TextKey::Application) => "Приложение",
            (Self::Ru, TextKey::Postgres) => "Postgres",
            (Self::Ru, TextKey::Launcher) => "Лончер",
            (Self::Ru, TextKey::Start) => "Запустить",
            (Self::Ru, TextKey::Stop) => "Остановить",
            (Self::Ru, TextKey::Restart) => "Перезапустить",
            (Self::Ru, TextKey::Open) => "Открыть",
            (Self::Ru, TextKey::OpenApp) => "Открыть приложение",
            (Self::Ru, TextKey::Refresh) => "Обновить",
            (Self::Ru, TextKey::BackupNow) => "Создать бэкап",
            (Self::Ru, TextKey::RestoreSelected) => "Восстановить выбранный",
            (Self::Ru, TextKey::OpenBackups) => "Открыть бэкапы",
            (Self::Ru, TextKey::MoveData) => "Переместить данные",
            (Self::Ru, TextKey::Running) => "Запущено",
            (Self::Ru, TextKey::Starting) => "Запускается",
            (Self::Ru, TextKey::Stopped) => "Остановлено",
            (Self::Ru, TextKey::Installed) => "Установлено",
            (Self::Ru, TextKey::NotInstalled) => "Не установлено",
            (Self::Ru, TextKey::Error) => "Ошибка",
            (Self::Ru, TextKey::Unknown) => "Неизвестно",
            (Self::Ru, TextKey::Healthy) => "Доступно",
            (Self::Ru, TextKey::Unhealthy) => "Недоступно",
            (Self::Ru, TextKey::LastError) => "Последняя ошибка",
            (Self::Ru, TextKey::LastMessage) => "Последнее событие",
            (Self::Ru, TextKey::Url) => "URL",
            (Self::Ru, TextKey::Pid) => "PID",
            (Self::Ru, TextKey::Port) => "Порт",
            (Self::Ru, TextKey::DataDir) => "Данные Postgres",
            (Self::Ru, TextKey::AppDir) => "Приложение",
            (Self::Ru, TextKey::ConfigPath) => "Конфиг",
            (Self::Ru, TextKey::BackupsDir) => "Бэкапы",
            (Self::Ru, TextKey::RuntimeDir) => "Runtime",
            (Self::Ru, TextKey::InstallationsDir) => "Кэш Postgres",
            (Self::Ru, TextKey::LauncherLog) => "Лог лончера",
            (Self::Ru, TextKey::AppLog) => "Лог приложения",
            (Self::Ru, TextKey::PostgresLog) => "Лог Postgres",
            (Self::Ru, TextKey::NoBackups) => "Бэкапов пока нет",
            (Self::Ru, TextKey::Name) => "Имя",
            (Self::Ru, TextKey::Modified) => "Изменён",
            (Self::Ru, TextKey::Size) => "Размер",
            (Self::Ru, TextKey::Reveal) => "Показать",
            (Self::Ru, TextKey::Busy) => "Выполняется",
            (Self::Ru, TextKey::TargetPath) => "Новый путь",
            (Self::Ru, TextKey::AppLogEmpty) => "Лог пока пуст",
            (Self::En, TextKey::Title) => "Intellectual Club",
            (Self::En, TextKey::Overview) => "Overview",
            (Self::En, TextKey::BackupRestore) => "Backup / restore",
            (Self::En, TextKey::Paths) => "Paths",
            (Self::En, TextKey::Logs) => "Logs",
            (Self::En, TextKey::Application) => "Application",
            (Self::En, TextKey::Postgres) => "Postgres",
            (Self::En, TextKey::Launcher) => "Launcher",
            (Self::En, TextKey::Start) => "Start",
            (Self::En, TextKey::Stop) => "Stop",
            (Self::En, TextKey::Restart) => "Restart",
            (Self::En, TextKey::Open) => "Open",
            (Self::En, TextKey::OpenApp) => "Open app",
            (Self::En, TextKey::Refresh) => "Refresh",
            (Self::En, TextKey::BackupNow) => "Create backup",
            (Self::En, TextKey::RestoreSelected) => "Restore selected",
            (Self::En, TextKey::OpenBackups) => "Open backups",
            (Self::En, TextKey::MoveData) => "Move data",
            (Self::En, TextKey::Running) => "Running",
            (Self::En, TextKey::Starting) => "Starting",
            (Self::En, TextKey::Stopped) => "Stopped",
            (Self::En, TextKey::Installed) => "Installed",
            (Self::En, TextKey::NotInstalled) => "Not installed",
            (Self::En, TextKey::Error) => "Error",
            (Self::En, TextKey::Unknown) => "Unknown",
            (Self::En, TextKey::Healthy) => "Healthy",
            (Self::En, TextKey::Unhealthy) => "Unhealthy",
            (Self::En, TextKey::LastError) => "Last error",
            (Self::En, TextKey::LastMessage) => "Last event",
            (Self::En, TextKey::Url) => "URL",
            (Self::En, TextKey::Pid) => "PID",
            (Self::En, TextKey::Port) => "Port",
            (Self::En, TextKey::DataDir) => "Postgres data",
            (Self::En, TextKey::AppDir) => "Application",
            (Self::En, TextKey::ConfigPath) => "Config",
            (Self::En, TextKey::BackupsDir) => "Backups",
            (Self::En, TextKey::RuntimeDir) => "Runtime",
            (Self::En, TextKey::InstallationsDir) => "Postgres cache",
            (Self::En, TextKey::LauncherLog) => "Launcher log",
            (Self::En, TextKey::AppLog) => "App log",
            (Self::En, TextKey::PostgresLog) => "Postgres log",
            (Self::En, TextKey::NoBackups) => "No backups yet",
            (Self::En, TextKey::Name) => "Name",
            (Self::En, TextKey::Modified) => "Modified",
            (Self::En, TextKey::Size) => "Size",
            (Self::En, TextKey::Reveal) => "Reveal",
            (Self::En, TextKey::Busy) => "Running",
            (Self::En, TextKey::TargetPath) => "New path",
            (Self::En, TextKey::AppLogEmpty) => "Log is empty",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum TextKey {
    Title,
    Overview,
    BackupRestore,
    Paths,
    Logs,
    Application,
    Postgres,
    Launcher,
    Start,
    Stop,
    Restart,
    Open,
    OpenApp,
    Refresh,
    BackupNow,
    RestoreSelected,
    OpenBackups,
    MoveData,
    Running,
    Starting,
    Stopped,
    Installed,
    NotInstalled,
    Error,
    Unknown,
    Healthy,
    Unhealthy,
    LastError,
    LastMessage,
    Url,
    Pid,
    Port,
    DataDir,
    AppDir,
    ConfigPath,
    BackupsDir,
    RuntimeDir,
    InstallationsDir,
    LauncherLog,
    AppLog,
    PostgresLog,
    NoBackups,
    Name,
    Modified,
    Size,
    Reveal,
    Busy,
    TargetPath,
    AppLogEmpty,
}

pub fn default_app_dir() -> Option<PathBuf> {
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

pub fn resolve_app_dir(config: &LauncherConfig) -> Result<PathBuf> {
    if let Some(path) = &config.app_dir {
        return Ok(path.clone());
    }
    default_app_dir()
        .ok_or_else(|| anyhow!("app_dir is not configured and could not be discovered"))
}

pub fn random_secret(prefix: &str) -> String {
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

fn restrict_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod 0600 {}", path.display()))?;
    }
    Ok(())
}
