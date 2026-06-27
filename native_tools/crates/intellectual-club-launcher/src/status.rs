use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RuntimeStatus {
    pub version: u32,
    pub daemon_pid: u32,
    pub app_pid: Option<u32>,
    pub app_url: String,
    pub database_url: String,
    pub postgres_data_dir: PathBuf,
    pub started_at: String,
    pub updated_at: String,
    pub state: String,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct StatusPayload {
    pub running: bool,
    pub daemon: ServiceStatus,
    pub app: ServiceStatus,
    pub postgres: ServiceStatus,
    pub status: Option<RuntimeStatus>,
    pub app_healthy: bool,
    pub paths: PathsPayload,
}

#[derive(Clone, Debug, Serialize)]
pub struct ServiceStatus {
    pub state: ServiceState,
    pub pid: Option<u32>,
    pub healthy: bool,
    pub detail: Option<String>,
    pub url: Option<String>,
    pub port: Option<u16>,
}

impl ServiceStatus {
    pub fn new(state: ServiceState) -> Self {
        Self {
            state,
            pid: None,
            healthy: false,
            detail: None,
            url: None,
            port: None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceState {
    Running,
    Starting,
    Stopped,
    Installed,
    NotInstalled,
    Error,
    Unknown,
}

impl ServiceState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Starting => "starting",
            Self::Stopped => "stopped",
            Self::Installed => "installed",
            Self::NotInstalled => "not_installed",
            Self::Error => "error",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct PathsPayload {
    pub config_path: PathBuf,
    pub postgres_data_dir: PathBuf,
    pub backups_dir: PathBuf,
    pub installations_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub log_path: PathBuf,
    pub launcher_log_path: PathBuf,
    pub app_log_path: PathBuf,
    pub postgres_log_path: PathBuf,
    pub app_dir: Option<PathBuf>,
}
