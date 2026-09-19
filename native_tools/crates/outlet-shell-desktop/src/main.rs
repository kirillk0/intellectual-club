#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc;

mod history;
mod i18n;
mod ui;

use history::History;
use i18n::{Locale, Text};

use anyhow::{anyhow, Context, Result};
use chrono::{SecondsFormat, Utc};
use directories::ProjectDirs;
use eframe::egui;
use outlet_core::{
    base_runner_metadata, OutletMetadataClient, OutletRunner, PairingClient, RunnerConfig,
    RunnerEvent, ToolProvider,
};
use outlet_shell::ShellOutlet;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::{error, warn};
use tracing_subscriber::EnvFilter;
use uuid::Uuid;

const CONFIG_VERSION: u32 = 1;
const APP_DISPLAY_NAME: &str = "IC Shell Outlet";

fn main() -> eframe::Result<()> {
    init_logging();
    let options = native_options();
    eframe::run_native(
        APP_DISPLAY_NAME,
        options,
        Box::new(|cc| {
            ui::configure(&cc.egui_ctx);
            Ok(Box::new(OutletDesktopApp::new()))
        }),
    )
}

fn native_options() -> eframe::NativeOptions {
    #[cfg(target_os = "macos")]
    let viewport = egui::ViewportBuilder::default().with_icon(egui::IconData::default());
    #[cfg(not(target_os = "macos"))]
    let viewport = egui::ViewportBuilder::default().with_icon(app_icon());

    eframe::NativeOptions {
        viewport: viewport
            .with_inner_size([1060.0, 720.0])
            .with_min_inner_size([680.0, 480.0]),
        renderer: eframe::Renderer::Wgpu,
        ..Default::default()
    }
}

#[cfg(not(target_os = "macos"))]
fn app_icon() -> egui::IconData {
    eframe::icon_data::from_png_bytes(include_bytes!(
        "../../../../frontend/src/assets/icon_outlet_full.png"
    ))
    .expect("embedded outlet icon must be a valid PNG")
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct DesktopConfig {
    version: u32,
    profiles: Vec<Profile>,
    #[serde(default = "Locale::from_env")]
    locale: Locale,
}

impl Default for DesktopConfig {
    fn default() -> Self {
        Self {
            version: CONFIG_VERSION,
            profiles: Vec::new(),
            locale: Locale::from_env(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Profile {
    id: String,
    name: String,
    server_url: String,
    token: String,
    runner_id: String,
    auto_start: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone, Debug, Default)]
struct ProfileStatus {
    running: bool,
    online: bool,
    error: String,
}

impl ProfileStatus {
    fn label(&self) -> Text {
        if self.online {
            Text::Online
        } else if !self.running {
            Text::Stopped
        } else if !self.error.is_empty() {
            Text::Offline
        } else {
            Text::Connecting
        }
    }
}

#[derive(Debug)]
struct RunnerHandle {
    generation: String,
    cancel: CancellationToken,
    runner_join: JoinHandle<()>,
    event_join: JoinHandle<()>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum ConnectionMode {
    #[default]
    Browser,
    Secret,
}

#[derive(Default)]
struct ConnectionForm {
    profile_id: Option<String>,
    server_url: String,
    secret: String,
    show_secret: bool,
    copied: bool,
    mode: ConnectionMode,
    request_id: Option<String>,
    pairing: Option<PairingState>,
    error: String,
}

struct PairingState {
    user_code: String,
    verification_url: String,
}

#[derive(Debug)]
enum UiEvent {
    Runner {
        profile_id: String,
        generation: String,
        event: RunnerEvent,
    },
    EventsLost {
        profile_id: String,
        generation: String,
    },
    PairingStarted {
        request_id: String,
        user_code: String,
        verification_url: String,
    },
    ConnectionReady {
        request_id: String,
        server_url: String,
        tool_name: String,
        token: String,
    },
    ConnectionFailed {
        request_id: String,
        error: String,
    },
    MetadataRefreshed {
        profile_id: String,
        generation: String,
        name: String,
    },
}

#[derive(Debug)]
enum ProfileAction {
    Start(String),
    Stop(String),
    Delete(String),
    Repair(String),
    ToggleAutoStart(String, bool),
}

struct OutletDesktopApp {
    config_path: PathBuf,
    config: DesktopConfig,
    runtime: tokio::runtime::Runtime,
    ui_tx: mpsc::Sender<UiEvent>,
    ui_rx: mpsc::Receiver<UiEvent>,
    runners: HashMap<String, RunnerHandle>,
    statuses: HashMap<String, ProfileStatus>,
    histories: HashMap<String, History>,
    active_profile: Option<String>,
    scroll_to_active_tab: bool,
    connection: Option<ConnectionForm>,
    connection_task: Option<JoinHandle<()>>,
    remove_profile: Option<String>,
    last_error: String,
}

impl OutletDesktopApp {
    fn new() -> Self {
        let (ui_tx, ui_rx) = mpsc::channel();
        let config_path = config_path();
        let (config, last_error) = match load_config(&config_path) {
            Ok(config) => (config, String::new()),
            Err(error) => (DesktopConfig::default(), error.to_string()),
        };
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        let active_profile = config.profiles.first().map(|p| p.id.clone());
        let mut app = Self {
            config_path,
            config,
            runtime,
            ui_tx,
            ui_rx,
            active_profile,
            scroll_to_active_tab: true,
            runners: HashMap::new(),
            statuses: HashMap::new(),
            histories: HashMap::new(),
            connection: None,
            connection_task: None,
            remove_profile: None,
            last_error,
        };
        let auto_start_ids = app
            .config
            .profiles
            .iter()
            .filter(|p| p.auto_start)
            .map(|p| p.id.clone())
            .collect::<Vec<_>>();
        for id in auto_start_ids {
            app.start_profile(&id);
        }
        app
    }

    fn save(&mut self) {
        if let Err(error) = save_config(&self.config_path, &self.config) {
            self.last_error = error.to_string();
        }
    }

    fn current_request(&self, request_id: &str) -> bool {
        self.connection
            .as_ref()
            .and_then(|form| form.request_id.as_deref())
            == Some(request_id)
    }

    fn current_runner(&self, profile_id: &str, generation: &str) -> bool {
        self.runners
            .get(profile_id)
            .is_some_and(|handle| handle.generation == generation)
    }

    fn process_events(&mut self) {
        while let Ok(event) = self.ui_rx.try_recv() {
            match event {
                UiEvent::Runner {
                    profile_id,
                    generation,
                    event,
                } => {
                    if self.current_runner(&profile_id, &generation) {
                        let stopped = matches!(event, RunnerEvent::Stopped { .. });
                        self.apply_runner_event(&profile_id, event);
                        if stopped {
                            self.runners.remove(&profile_id);
                        }
                    }
                }
                UiEvent::EventsLost {
                    profile_id,
                    generation,
                } => {
                    if self.current_runner(&profile_id, &generation) {
                        self.histories
                            .entry(profile_id)
                            .or_default()
                            .notice(Text::EventsLost, String::new());
                    }
                }
                UiEvent::PairingStarted {
                    request_id,
                    user_code,
                    verification_url,
                } => {
                    if self.current_request(&request_id) {
                        if let Err(error) = webbrowser::open(&verification_url) {
                            warn!(%error, "could not open pairing page");
                        }
                        self.connection.as_mut().unwrap().pairing = Some(PairingState {
                            user_code,
                            verification_url,
                        });
                    }
                }
                UiEvent::ConnectionReady {
                    request_id,
                    server_url,
                    tool_name,
                    token,
                } => {
                    if self.current_request(&request_id) {
                        self.finish_connection(server_url, tool_name, token);
                    }
                }
                UiEvent::ConnectionFailed { request_id, error } => {
                    if self.current_request(&request_id) {
                        let form = self.connection.as_mut().unwrap();
                        form.request_id = None;
                        form.error = error;
                        form.pairing = None;
                    }
                }
                UiEvent::MetadataRefreshed {
                    profile_id,
                    generation,
                    name,
                } => {
                    if self.current_runner(&profile_id, &generation) && !name.trim().is_empty() {
                        if let Some(profile) =
                            self.config.profiles.iter_mut().find(|p| p.id == profile_id)
                        {
                            if profile.name != name {
                                profile.name = name;
                                profile.updated_at = now_timestamp();
                                self.save();
                            }
                        }
                    }
                }
            }
        }
    }

    fn apply_runner_event(&mut self, profile_id: &str, event: RunnerEvent) {
        let status = self.statuses.entry(profile_id.to_string()).or_default();
        let history = self.histories.entry(profile_id.to_string()).or_default();
        history.apply(&event);
        match event {
            RunnerEvent::Connected => {
                if !status.online {
                    history.notice(Text::Online, String::new());
                }
                status.running = true;
                status.online = true;
                status.error.clear();
            }
            RunnerEvent::Disconnected { reason } => {
                if status.online || status.error != reason {
                    history.notice(Text::Offline, reason.clone());
                }
                status.online = false;
                status.error = reason;
            }
            RunnerEvent::Stopped { reason } => {
                status.running = false;
                status.online = false;
                status.error = reason.clone();
                history.interrupt();
                history.notice(Text::Stopped, reason);
            }
            _ => {}
        }
    }

    fn open_connection(&mut self, profile_id: Option<String>) {
        self.close_connection();
        let server_url = profile_id
            .as_ref()
            .and_then(|id| self.config.profiles.iter().find(|p| &p.id == id))
            .map(|p| p.server_url.clone())
            .unwrap_or_else(|| "http://localhost:4000".into());
        self.connection = Some(ConnectionForm {
            profile_id,
            server_url,
            ..Default::default()
        });
    }

    fn close_connection(&mut self) {
        if let Some(task) = self.connection_task.take() {
            task.abort();
        }
        self.connection = None;
    }

    fn connect(&mut self) {
        let locale = self.config.locale;
        let Some(form) = &mut self.connection else {
            return;
        };
        let server_url = match validated_server_url(&form.server_url) {
            Ok(url) => url,
            Err(_) => {
                form.error = locale.text(Text::UrlRequired).into();
                return;
            }
        };
        let token = form.secret.trim().to_string();
        if form.mode == ConnectionMode::Secret && token.is_empty() {
            form.error = locale.text(Text::SecretRequired).into();
            return;
        }
        if form.mode == ConnectionMode::Secret
            && duplicate_profile(
                &self.config,
                form.profile_id.as_deref(),
                &server_url,
                &token,
            )
        {
            form.error = locale.text(Text::Duplicate).into();
            return;
        }
        if let Some(task) = self.connection_task.take() {
            task.abort();
        }
        let request_id = Uuid::new_v4().to_string();
        form.request_id = Some(request_id.clone());
        form.pairing = None;
        form.error.clear();
        let mode = form.mode;
        let ui_tx = self.ui_tx.clone();
        self.connection_task = Some(self.runtime.spawn(async move {
            let result = match mode {
                ConnectionMode::Secret => fetch_outlet_tool_name(&server_url, &token)
                    .await
                    .map(|name| (name, token)),
                ConnectionMode::Browser => {
                    pair_connection(&server_url, &request_id, &ui_tx, locale).await
                }
            };
            let event = match result {
                Ok((tool_name, token)) => UiEvent::ConnectionReady {
                    request_id,
                    server_url,
                    tool_name,
                    token,
                },
                Err(error) => UiEvent::ConnectionFailed {
                    request_id,
                    error: error.to_string(),
                },
            };
            let _ = ui_tx.send(event);
        }));
    }

    fn finish_connection(&mut self, server_url: String, tool_name: String, token: String) {
        let profile_id = self.connection.as_ref().and_then(|f| f.profile_id.clone());
        if duplicate_profile(&self.config, profile_id.as_deref(), &server_url, &token) {
            let form = self.connection.as_mut().unwrap();
            form.request_id = None;
            form.error = self.config.locale.text(Text::Duplicate).into();
            return;
        }
        let mut config = self.config.clone();
        let id = if let Some(profile) = config
            .profiles
            .iter_mut()
            .find(|p| Some(&p.id) == profile_id.as_ref())
        {
            profile.name = first_non_empty(&[&tool_name, &profile.name]);
            profile.server_url = server_url;
            profile.token = token;
            profile.updated_at = now_timestamp();
            profile.id.clone()
        } else {
            let id = Uuid::new_v4().to_string();
            config.profiles.push(Profile {
                id: id.clone(),
                name: first_non_empty(&[&tool_name, &server_url]),
                server_url,
                token,
                runner_id: Uuid::new_v4().simple().to_string(),
                auto_start: true,
                created_at: now_timestamp(),
                updated_at: now_timestamp(),
            });
            id
        };
        // Commit the connection only after it has been saved successfully.
        if let Err(error) = save_config(&self.config_path, &config) {
            let form = self.connection.as_mut().unwrap();
            form.request_id = None;
            form.error = error.to_string();
            return;
        }
        if self.runners.contains_key(&id) {
            self.stop_profile(&id);
        }
        self.config = config;
        self.active_profile = Some(id.clone());
        self.scroll_to_active_tab = true;
        self.close_connection();
        self.start_profile(&id);
    }

    fn start_profile(&mut self, profile_id: &str) {
        if self.runners.contains_key(profile_id) {
            return;
        }
        let Some(profile) = self
            .config
            .profiles
            .iter()
            .find(|p| p.id == profile_id)
            .cloned()
        else {
            return;
        };
        let mut config = RunnerConfig::new(&profile.server_url, &profile.token);
        if !profile.runner_id.trim().is_empty() {
            config.runner_id = profile.runner_id.clone();
        }
        let mut runner = match OutletRunner::new(ShellOutlet::new(), config) {
            Ok(runner) => runner,
            Err(error) => {
                self.last_error = error.to_string();
                return;
            }
        };
        let generation = Uuid::new_v4().to_string();
        let cancel = CancellationToken::new();
        let (event_tx, mut event_rx) = broadcast::channel(256);
        runner.set_event_sender(event_tx);
        let runner_cancel = cancel.clone();
        let runner_join = self.runtime.spawn(async move {
            if let Err(error) = runner.serve(runner_cancel).await {
                error!(%error, "desktop runner stopped with error");
            }
        });
        let ui_tx = self.ui_tx.clone();
        let event_profile_id = profile.id.clone();
        let event_generation = generation.clone();
        let event_join = self.runtime.spawn(async move {
            loop {
                let event = match event_rx.recv().await {
                    Ok(event) => UiEvent::Runner {
                        profile_id: event_profile_id.clone(),
                        generation: event_generation.clone(),
                        event,
                    },
                    Err(broadcast::error::RecvError::Lagged(_)) => UiEvent::EventsLost {
                        profile_id: event_profile_id.clone(),
                        generation: event_generation.clone(),
                    },
                    Err(broadcast::error::RecvError::Closed) => break,
                };
                if ui_tx.send(event).is_err() {
                    break;
                }
            }
        });
        self.statuses.insert(
            profile.id.clone(),
            ProfileStatus {
                running: true,
                ..Default::default()
            },
        );
        self.histories
            .entry(profile.id.clone())
            .or_default()
            .notice(Text::Connecting, String::new());
        self.runners.insert(
            profile.id.clone(),
            RunnerHandle {
                generation: generation.clone(),
                cancel,
                runner_join,
                event_join,
            },
        );
        let ui_tx = self.ui_tx.clone();
        self.runtime.spawn(async move {
            if let Ok(name) = fetch_outlet_tool_name(&profile.server_url, &profile.token).await {
                let _ = ui_tx.send(UiEvent::MetadataRefreshed {
                    profile_id: profile.id,
                    generation,
                    name,
                });
            }
        });
    }

    fn stop_profile(&mut self, profile_id: &str) {
        if let Some(handle) = self.runners.remove(profile_id) {
            handle.cancel.cancel();
            self.runtime.spawn(async move {
                let _ = handle.runner_join.await;
                handle.event_join.abort();
            });
        }
        self.statuses
            .insert(profile_id.to_string(), ProfileStatus::default());
        let history = self.histories.entry(profile_id.to_string()).or_default();
        history.interrupt();
        history.notice(Text::Stopped, String::new());
    }

    fn delete_profile(&mut self, profile_id: &str) {
        let mut config = self.config.clone();
        let index = config
            .profiles
            .iter()
            .position(|p| p.id == profile_id)
            .unwrap_or(0);
        config.profiles.retain(|p| p.id != profile_id);
        if let Err(error) = save_config(&self.config_path, &config) {
            self.last_error = error.to_string();
            return;
        }
        self.stop_profile(profile_id);
        self.config = config;
        self.statuses.remove(profile_id);
        self.histories.remove(profile_id);
        if self.active_profile.as_deref() == Some(profile_id) {
            self.scroll_to_active_tab = true;
            self.active_profile = self
                .config
                .profiles
                .get(index.min(self.config.profiles.len().saturating_sub(1)))
                .map(|p| p.id.clone());
        }
    }

    fn apply_action(&mut self, action: ProfileAction) {
        match action {
            ProfileAction::Start(id) => self.start_profile(&id),
            ProfileAction::Stop(id) => self.stop_profile(&id),
            ProfileAction::Delete(id) => self.remove_profile = Some(id),
            ProfileAction::Repair(id) => self.open_connection(Some(id)),
            ProfileAction::ToggleAutoStart(id, value) => {
                if let Some(profile) = self.config.profiles.iter_mut().find(|p| p.id == id) {
                    profile.auto_start = value;
                    profile.updated_at = now_timestamp();
                    self.save();
                }
            }
        }
    }
}

impl eframe::App for OutletDesktopApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_events();
        self.render(ctx);
        ctx.request_repaint_after(std::time::Duration::from_millis(250));
    }
}

impl Drop for OutletDesktopApp {
    fn drop(&mut self) {
        if let Some(task) = self.connection_task.take() {
            task.abort();
        }
        let handles = self
            .runners
            .drain()
            .map(|(_, handle)| handle)
            .collect::<Vec<_>>();
        for handle in &handles {
            handle.cancel.cancel();
        }
        self.runtime.block_on(async move {
            for handle in handles {
                let _ = handle.runner_join.await;
                handle.event_join.abort();
            }
        });
    }
}

async fn pair_connection(
    server_url: &str,
    request_id: &str,
    ui_tx: &mpsc::Sender<UiEvent>,
    locale: Locale,
) -> Result<(String, String)> {
    let mut metadata = base_runner_metadata();
    metadata.extend(ShellOutlet::new().metadata());
    let client = PairingClient::new(server_url);
    let started = client.start("shell-outlet", "", metadata).await?;
    let _ = ui_tx.send(UiEvent::PairingStarted {
        request_id: request_id.into(),
        user_code: started.user_code,
        verification_url: started.verification_url,
    });
    let deadline =
        tokio::time::Instant::now() + std::time::Duration::from_secs(started.expires_in.max(1));
    let interval = std::time::Duration::from_secs_f64(started.interval.max(0.5));
    loop {
        let response = tokio::time::timeout_at(deadline, client.poll(&started.device_code))
            .await
            .map_err(|_| anyhow!(locale.text(Text::PairExpired)))??;
        match response.status.as_str() {
            "approved" if !response.token.trim().is_empty() => {
                let name = fetch_outlet_tool_name(server_url, &response.token)
                    .await
                    .unwrap_or(started.suggested_tool_name);
                return Ok((name, response.token));
            }
            "expired" => return Err(anyhow!(locale.text(Text::PairExpired))),
            "consumed" => return Err(anyhow!(locale.text(Text::PairConsumed))),
            "error" => {
                return Err(anyhow!(first_non_empty(&[
                    &response.error,
                    locale.text(Text::PairFailed)
                ])))
            }
            _ => {}
        }
        tokio::time::sleep_until((tokio::time::Instant::now() + interval).min(deadline)).await;
    }
}

fn validated_server_url(value: &str) -> Result<String> {
    let url = url::Url::parse(value.trim())?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(anyhow!("invalid server URL"));
    }
    Ok(normalize_server_url(url.as_str()))
}

fn duplicate_profile(
    config: &DesktopConfig,
    exclude: Option<&str>,
    server_url: &str,
    token: &str,
) -> bool {
    config.profiles.iter().any(|profile| {
        Some(profile.id.as_str()) != exclude
            && normalize_server_url(&profile.server_url) == server_url
            && profile.token == token
    })
}

fn generate_secret() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|error| anyhow!("{error}"))?;
    Ok(hex::encode(bytes))
}
fn init_logging() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .try_init();
}

fn config_path() -> PathBuf {
    if let Some(project_dirs) = ProjectDirs::from("org", "IntellectualClub", "Outlet Shell") {
        return project_dirs.config_dir().join("profiles.json");
    }
    PathBuf::from("outlet-shell-profiles.json")
}

fn load_config(path: &PathBuf) -> Result<DesktopConfig> {
    if !path.exists() {
        return Ok(DesktopConfig::default());
    }
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    let mut config: DesktopConfig =
        serde_json::from_str(&text).context("invalid desktop outlet config")?;
    if config.version == 0 {
        config.version = CONFIG_VERSION;
    }
    Ok(config)
}

fn save_config(path: &PathBuf, config: &DesktopConfig) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let payload = serde_json::to_string_pretty(config)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, payload + "\n")
        .with_context(|| format!("failed to write {}", tmp.display()))?;
    restrict_file_permissions(&tmp)?;
    std::fs::rename(&tmp, path).with_context(|| format!("failed to replace {}", path.display()))?;
    restrict_file_permissions(path)?;
    Ok(())
}

fn restrict_file_permissions(_path: &PathBuf) -> Result<()> {
    #[cfg(unix)]
    {
        let path = _path;
        use std::os::unix::fs::PermissionsExt;
        let permissions = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, permissions)
            .with_context(|| format!("failed to chmod 0600 {}", path.display()))?;
    }
    Ok(())
}

fn now_timestamp() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn normalize_server_url(value: &str) -> String {
    value.trim().trim_end_matches('/').to_string()
}

async fn fetch_outlet_tool_name(server_url: &str, token: &str) -> Result<String> {
    let payload = OutletMetadataClient::new(server_url, token).fetch().await?;
    let name = payload.tool_instance_name().trim().to_string();
    if name.is_empty() {
        Err(anyhow!(
            "Outlet metadata does not include tool instance name."
        ))
    } else {
        Ok(name)
    }
}

fn first_non_empty(values: &[&str]) -> String {
    values
        .iter()
        .map(|value| value.trim())
        .find(|value| !value.is_empty())
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_options_use_wgpu_renderer() {
        let options = native_options();
        assert_eq!(options.renderer, eframe::Renderer::Wgpu);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_options_preserve_the_bundle_icon() {
        let icon = native_options().viewport.icon.expect("window icon");
        assert_eq!(icon.as_ref(), &egui::IconData::default());
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn native_options_use_embedded_outlet_icon_pixels() {
        let options = native_options();
        let icon = options.viewport.icon.expect("window icon");
        assert!(icon.width >= 256);
        assert!(icon.height >= 256);
        assert_eq!(icon.rgba.len(), (icon.width * icon.height * 4) as usize);
        assert!(icon.rgba.iter().any(|byte| *byte != 0));
    }
}

#[cfg(test)]
mod connection_tests;
