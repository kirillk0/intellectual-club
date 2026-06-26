use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc;

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

fn main() -> eframe::Result<()> {
    init_logging();
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "Outlet Shell",
        options,
        Box::new(|_cc| Ok(Box::new(OutletDesktopApp::new()))),
    )
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct DesktopConfig {
    version: u32,
    profiles: Vec<Profile>,
}

impl Default for DesktopConfig {
    fn default() -> Self {
        Self {
            version: CONFIG_VERSION,
            profiles: Vec::new(),
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
    text: String,
    error: String,
    last_call: String,
}

#[derive(Debug)]
struct RunnerHandle {
    cancel: CancellationToken,
    runner_join: JoinHandle<()>,
    event_join: JoinHandle<()>,
}

#[derive(Clone, Debug)]
struct PairingState {
    session_id: String,
    profile_id: Option<String>,
    server_url: String,
    requested_name: String,
    user_code: String,
    verification_url: String,
    suggested_tool_name: String,
    status: String,
    error: String,
}

#[derive(Debug)]
enum UiEvent {
    Runner {
        profile_id: String,
        event: RunnerEvent,
    },
    PairingStarted {
        session_id: String,
        profile_id: Option<String>,
        server_url: String,
        requested_name: String,
        user_code: String,
        verification_url: String,
        suggested_tool_name: String,
    },
    PairingApproved {
        session_id: String,
        profile_id: Option<String>,
        server_url: String,
        tool_name: String,
        token: String,
    },
    PairingFailed {
        session_id: String,
        error: String,
    },
    MetadataRefreshed {
        profile_id: String,
        name: String,
    },
    MetadataRefreshFailed {
        profile_id: String,
        error: String,
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
    new_server_url: String,
    pairing: Option<PairingState>,
    last_error: String,
}

impl OutletDesktopApp {
    fn new() -> Self {
        let (ui_tx, ui_rx) = mpsc::channel();
        let config_path = config_path();
        let config = load_config(&config_path).unwrap_or_else(|error| {
            warn!(error = %error, path = %config_path.display(), "failed to load desktop outlet config");
            DesktopConfig::default()
        });
        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");

        let mut app = Self {
            config_path,
            config,
            runtime,
            ui_tx,
            ui_rx,
            runners: HashMap::new(),
            statuses: HashMap::new(),
            new_server_url: "http://localhost:4000".to_string(),
            pairing: None,
            last_error: String::new(),
        };

        let auto_start_ids = app
            .config
            .profiles
            .iter()
            .filter(|profile| profile.auto_start)
            .map(|profile| profile.id.clone())
            .collect::<Vec<_>>();
        for id in auto_start_ids {
            app.start_profile(&id);
        }

        app
    }

    fn process_events(&mut self) {
        while let Ok(event) = self.ui_rx.try_recv() {
            match event {
                UiEvent::Runner { profile_id, event } => {
                    self.apply_runner_event(&profile_id, event)
                }
                UiEvent::PairingStarted {
                    session_id,
                    profile_id,
                    server_url,
                    requested_name,
                    user_code,
                    verification_url,
                    suggested_tool_name,
                } => {
                    self.pairing = Some(PairingState {
                        session_id,
                        profile_id,
                        server_url,
                        requested_name,
                        user_code,
                        verification_url,
                        suggested_tool_name,
                        status: "Waiting for approval".to_string(),
                        error: String::new(),
                    });
                }
                UiEvent::PairingApproved {
                    session_id,
                    profile_id,
                    server_url,
                    tool_name,
                    token,
                } => {
                    if self
                        .pairing
                        .as_ref()
                        .map(|pairing| pairing.session_id.as_str())
                        == Some(session_id.as_str())
                    {
                        self.finish_pairing(profile_id, server_url, tool_name, token);
                    }
                }
                UiEvent::PairingFailed { session_id, error } => {
                    if let Some(pairing) = &mut self.pairing {
                        if pairing.session_id == session_id {
                            pairing.status = "Pairing failed".to_string();
                            pairing.error = error;
                        }
                    }
                }
                UiEvent::MetadataRefreshed { profile_id, name } => {
                    self.apply_profile_name(&profile_id, name);
                }
                UiEvent::MetadataRefreshFailed { profile_id, error } => {
                    if self
                        .config
                        .profiles
                        .iter()
                        .any(|profile| profile.id == profile_id)
                    {
                        let status = self.statuses.entry(profile_id).or_default();
                        status.error = format!("Metadata refresh failed: {error}");
                    }
                }
            }
        }
    }

    fn apply_runner_event(&mut self, profile_id: &str, event: RunnerEvent) {
        let status = self.statuses.entry(profile_id.to_string()).or_default();
        match event {
            RunnerEvent::Connected => {
                status.running = true;
                status.online = true;
                status.text = "Online".to_string();
                status.error.clear();
            }
            RunnerEvent::Disconnected { reason } => {
                status.running = true;
                status.online = false;
                status.text = "Connection problem".to_string();
                status.error = reason;
            }
            RunnerEvent::CallStarted { function_name, .. } => {
                status.last_call = format!("Calling {function_name}");
            }
            RunnerEvent::CallFinished {
                function_name,
                status: call_status,
                error_text,
                ..
            } => {
                status.last_call = format!("{function_name}: {call_status}");
                if !error_text.trim().is_empty() {
                    status.error = error_text;
                }
            }
            RunnerEvent::Stopped { reason } => {
                status.running = false;
                status.online = false;
                status.text = "Stopped".to_string();
                status.error = reason;
            }
        }
    }

    fn finish_pairing(
        &mut self,
        profile_id: Option<String>,
        server_url: String,
        tool_name: String,
        token: String,
    ) {
        let now = now_timestamp();
        let final_name = first_non_empty(&[&tool_name, "Shell Outlet"]);
        let profile_id = if let Some(profile_id) = profile_id {
            if let Some(profile) = self
                .config
                .profiles
                .iter_mut()
                .find(|profile| profile.id == profile_id)
            {
                if !tool_name.trim().is_empty() {
                    profile.name = final_name;
                }
                profile.server_url = normalize_server_url(&server_url);
                profile.token = token;
                profile.updated_at = now;
                profile.id.clone()
            } else {
                self.create_profile(final_name, server_url, token, now)
            }
        } else {
            self.create_profile(final_name, server_url, token, now)
        };

        if let Err(error) = save_config(&self.config_path, &self.config) {
            self.last_error = error.to_string();
        }
        self.pairing = None;
        self.start_profile(&profile_id);
    }

    fn apply_profile_name(&mut self, profile_id: &str, name: String) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }

        let mut changed = false;
        if let Some(profile) = self
            .config
            .profiles
            .iter_mut()
            .find(|profile| profile.id == profile_id)
        {
            if profile.name != name {
                profile.name = name.to_string();
                profile.updated_at = now_timestamp();
                changed = true;
            }
        }

        if changed {
            if let Err(error) = save_config(&self.config_path, &self.config) {
                self.last_error = error.to_string();
            }
        }
    }

    fn create_profile(
        &mut self,
        name: String,
        server_url: String,
        token: String,
        now: String,
    ) -> String {
        let id = Uuid::new_v4().to_string();
        self.config.profiles.push(Profile {
            id: id.clone(),
            name,
            server_url: normalize_server_url(&server_url),
            token,
            runner_id: Uuid::new_v4().simple().to_string(),
            auto_start: true,
            created_at: now.clone(),
            updated_at: now,
        });
        id
    }

    fn start_pairing(&mut self, profile_id: Option<String>, server_url: String) {
        let server_url = normalize_server_url(&server_url);
        if server_url.is_empty() {
            self.last_error = "Server URL is required.".to_string();
            return;
        }

        let session_id = Uuid::new_v4().to_string();
        let requested_name = String::new();
        self.pairing = Some(PairingState {
            session_id: session_id.clone(),
            profile_id: profile_id.clone(),
            server_url: server_url.clone(),
            requested_name: requested_name.clone(),
            user_code: String::new(),
            verification_url: String::new(),
            suggested_tool_name: String::new(),
            status: "Starting pairing".to_string(),
            error: String::new(),
        });

        let ui_tx = self.ui_tx.clone();
        self.runtime.spawn(async move {
            let mut metadata = base_runner_metadata();
            for (key, value) in ShellOutlet::new().metadata() {
                metadata.insert(key, value);
            }

            let client = PairingClient::new(&server_url);
            let started = match client
                .start("shell-outlet", &requested_name, metadata)
                .await
            {
                Ok(started) => started,
                Err(error) => {
                    let _ = ui_tx.send(UiEvent::PairingFailed {
                        session_id,
                        error: error.to_string(),
                    });
                    return;
                }
            };

            let _ = ui_tx.send(UiEvent::PairingStarted {
                session_id: session_id.clone(),
                profile_id: profile_id.clone(),
                server_url: server_url.clone(),
                requested_name: requested_name.clone(),
                user_code: started.user_code.clone(),
                verification_url: started.verification_url.clone(),
                suggested_tool_name: started.suggested_tool_name.clone(),
            });
            let _ = webbrowser::open(&started.verification_url);

            let deadline = std::time::Instant::now()
                + std::time::Duration::from_secs(started.expires_in.max(1));
            let interval = std::time::Duration::from_secs_f64(started.interval.max(0.5));
            while std::time::Instant::now() < deadline {
                match client.poll(&started.device_code).await {
                    Ok(response)
                        if response.status == "approved" && !response.token.trim().is_empty() =>
                    {
                        let token = response.token;
                        let tool_name = match fetch_outlet_tool_name(&server_url, &token).await {
                            Ok(name) => name,
                            Err(error) => {
                                warn!(error = %error, "failed to fetch outlet metadata after pairing");
                                String::new()
                            }
                        };

                        let _ = ui_tx.send(UiEvent::PairingApproved {
                            session_id,
                            profile_id,
                            server_url,
                            tool_name,
                            token,
                        });
                        return;
                    }
                    Ok(response) if response.status == "expired" => {
                        let _ = ui_tx.send(UiEvent::PairingFailed {
                            session_id,
                            error: "Pairing code expired.".to_string(),
                        });
                        return;
                    }
                    Ok(response) if response.status == "consumed" => {
                        let _ = ui_tx.send(UiEvent::PairingFailed {
                            session_id,
                            error: "Pairing token already consumed. Please restart pairing."
                                .to_string(),
                        });
                        return;
                    }
                    Ok(response) if response.status == "error" => {
                        let _ = ui_tx.send(UiEvent::PairingFailed {
                            session_id,
                            error: first_non_empty(&[&response.error, "Pairing failed."]),
                        });
                        return;
                    }
                    Ok(_) => tokio::time::sleep(interval).await,
                    Err(error) => {
                        let _ = ui_tx.send(UiEvent::PairingFailed {
                            session_id,
                            error: error.to_string(),
                        });
                        return;
                    }
                }
            }

            let _ = ui_tx.send(UiEvent::PairingFailed {
                session_id,
                error: "Pairing timed out. Please retry.".to_string(),
            });
        });
    }

    fn start_profile(&mut self, profile_id: &str) {
        if self.runners.contains_key(profile_id) {
            return;
        }
        let Some(profile) = self
            .config
            .profiles
            .iter()
            .find(|profile| profile.id == profile_id)
            .cloned()
        else {
            return;
        };
        if profile.token.trim().is_empty() || profile.server_url.trim().is_empty() {
            self.last_error = "Profile is missing server URL or token.".to_string();
            return;
        }

        let mut config = RunnerConfig::new(&profile.server_url, &profile.token);
        config.runner_id = if profile.runner_id.trim().is_empty() {
            Uuid::new_v4().simple().to_string()
        } else {
            profile.runner_id.clone()
        };

        let mut runner = match OutletRunner::new(ShellOutlet::new(), config) {
            Ok(runner) => runner,
            Err(error) => {
                self.last_error = error.to_string();
                return;
            }
        };

        let cancel = CancellationToken::new();
        let (event_tx, mut event_rx) = broadcast::channel(64);
        runner.set_event_sender(event_tx);

        let runner_cancel = cancel.clone();
        let runner_join = self.runtime.spawn(async move {
            if let Err(error) = runner.serve(runner_cancel).await {
                error!(error = %error, "desktop runner stopped with error");
            }
        });

        let ui_tx = self.ui_tx.clone();
        let event_profile_id = profile.id.clone();
        let event_join = self.runtime.spawn(async move {
            while let Ok(event) = event_rx.recv().await {
                let _ = ui_tx.send(UiEvent::Runner {
                    profile_id: event_profile_id.clone(),
                    event,
                });
            }
        });

        self.statuses.insert(
            profile.id.clone(),
            ProfileStatus {
                running: true,
                online: false,
                text: "Starting".to_string(),
                error: String::new(),
                last_call: String::new(),
            },
        );
        self.runners.insert(
            profile.id.clone(),
            RunnerHandle {
                cancel,
                runner_join,
                event_join,
            },
        );
        self.refresh_profile_metadata(&profile);
    }

    fn refresh_profile_metadata(&self, profile: &Profile) {
        let profile_id = profile.id.clone();
        let server_url = profile.server_url.clone();
        let token = profile.token.clone();
        let ui_tx = self.ui_tx.clone();

        self.runtime.spawn(async move {
            match fetch_outlet_tool_name(&server_url, &token).await {
                Ok(name) => {
                    let _ = ui_tx.send(UiEvent::MetadataRefreshed { profile_id, name });
                }
                Err(error) => {
                    let _ = ui_tx.send(UiEvent::MetadataRefreshFailed {
                        profile_id,
                        error: error.to_string(),
                    });
                }
            }
        });
    }

    fn stop_profile(&mut self, profile_id: &str) {
        if let Some(handle) = self.runners.remove(profile_id) {
            handle.cancel.cancel();
            handle.runner_join.abort();
            handle.event_join.abort();
        }
        let status = self.statuses.entry(profile_id.to_string()).or_default();
        status.running = false;
        status.online = false;
        status.text = "Stopped".to_string();
    }

    fn delete_profile(&mut self, profile_id: &str) {
        self.stop_profile(profile_id);
        self.config
            .profiles
            .retain(|profile| profile.id != profile_id);
        self.statuses.remove(profile_id);
        if let Err(error) = save_config(&self.config_path, &self.config) {
            self.last_error = error.to_string();
        }
    }

    fn set_auto_start(&mut self, profile_id: &str, value: bool) {
        if let Some(profile) = self
            .config
            .profiles
            .iter_mut()
            .find(|profile| profile.id == profile_id)
        {
            profile.auto_start = value;
            profile.updated_at = now_timestamp();
            if let Err(error) = save_config(&self.config_path, &self.config) {
                self.last_error = error.to_string();
            }
        }
    }
}

impl eframe::App for OutletDesktopApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_events();

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Outlet Shell");
            ui.label("Manage shell outlet connections for Intellectual Club instances.");

            if !self.last_error.trim().is_empty() {
                ui.colored_label(egui::Color32::RED, &self.last_error);
            }

            ui.separator();
            ui.heading("Add connection");
            ui.horizontal(|ui| {
                ui.label("Server URL");
                ui.text_edit_singleline(&mut self.new_server_url);
            });
            if ui.button("Pair new outlet").clicked() {
                self.last_error.clear();
                self.start_pairing(None, self.new_server_url.clone());
            }

            if let Some(pairing) = &self.pairing {
                ui.separator();
                ui.heading("Pairing");
                ui.label(&pairing.status);
                if !pairing.server_url.is_empty() {
                    ui.label(format!("Server: {}", pairing.server_url));
                }
                if !pairing.requested_name.is_empty() {
                    ui.label(format!("Name: {}", pairing.requested_name));
                }
                if let Some(profile_id) = &pairing.profile_id {
                    ui.label(format!("Profile: {profile_id}"));
                }
                if !pairing.user_code.is_empty() {
                    ui.monospace(format!("Code: {}", pairing.user_code));
                }
                if !pairing.suggested_tool_name.is_empty() {
                    ui.label(format!(
                        "Suggested tool name: {}",
                        pairing.suggested_tool_name
                    ));
                }
                if !pairing.verification_url.is_empty() {
                    ui.hyperlink_to("Open verification page", &pairing.verification_url);
                }
                if !pairing.error.is_empty() {
                    ui.colored_label(egui::Color32::RED, &pairing.error);
                }
            }

            ui.separator();
            ui.heading("Connections");
            if self.config.profiles.is_empty() {
                ui.label("No connections yet.");
            }

            let profiles = self.config.profiles.clone();
            let mut action = None;
            for profile in profiles {
                let status = self.statuses.get(&profile.id).cloned().unwrap_or_default();
                ui.group(|ui| {
                    ui.horizontal(|ui| {
                        ui.strong(&profile.name);
                        let status_text = if status.online {
                            "Online"
                        } else if status.running {
                            "Connecting"
                        } else {
                            "Stopped"
                        };
                        ui.label(status_text);
                    });
                    ui.label(&profile.server_url);
                    if !status.last_call.is_empty() {
                        ui.label(&status.last_call);
                    }
                    if !status.error.is_empty() {
                        ui.colored_label(egui::Color32::RED, &status.error);
                    }

                    ui.horizontal(|ui| {
                        if status.running {
                            if ui.button("Stop").clicked() {
                                action = Some(ProfileAction::Stop(profile.id.clone()));
                            }
                        } else if ui.button("Start").clicked() {
                            action = Some(ProfileAction::Start(profile.id.clone()));
                        }

                        if ui.button("Re-pair").clicked() {
                            action = Some(ProfileAction::Repair(profile.id.clone()));
                        }

                        if ui.button("Delete").clicked() {
                            action = Some(ProfileAction::Delete(profile.id.clone()));
                        }

                        let mut auto_start = profile.auto_start;
                        if ui.checkbox(&mut auto_start, "Auto-start").changed() {
                            action = Some(ProfileAction::ToggleAutoStart(
                                profile.id.clone(),
                                auto_start,
                            ));
                        }
                    });
                });
            }

            if let Some(action) = action {
                match action {
                    ProfileAction::Start(id) => self.start_profile(&id),
                    ProfileAction::Stop(id) => self.stop_profile(&id),
                    ProfileAction::Delete(id) => self.delete_profile(&id),
                    ProfileAction::Repair(id) => {
                        if let Some(profile) = self
                            .config
                            .profiles
                            .iter()
                            .find(|profile| profile.id == id)
                            .cloned()
                        {
                            self.stop_profile(&id);
                            self.start_pairing(Some(id), profile.server_url);
                        }
                    }
                    ProfileAction::ToggleAutoStart(id, value) => self.set_auto_start(&id, value),
                }
            }
        });

        ctx.request_repaint_after(std::time::Duration::from_millis(500));
    }
}

impl Drop for OutletDesktopApp {
    fn drop(&mut self) {
        for (_id, handle) in self.runners.drain() {
            handle.cancel.cancel();
            handle.runner_join.abort();
            handle.event_join.abort();
        }
    }
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

fn restrict_file_permissions(path: &PathBuf) -> Result<()> {
    #[cfg(unix)]
    {
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
