use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::Result;
use eframe::egui;

use crate::cli::LogSource;
use crate::config::{AppPaths, LauncherConfig, Locale, TextKey};
use crate::fs_utils::{list_backups, open_path, BackupEntry};
use crate::operations::{
    backup_command, build_status_payload, log_path_for, move_data_command, move_files_data_command,
    open_command, open_log, read_log, restart_application_command, restore_command,
    start_application_command, start_command, stop_application_command, stop_command,
};
use crate::status::{ServiceState, ServiceStatus, StatusPayload};

const REFRESH_INTERVAL: Duration = Duration::from_millis(900);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum View {
    Overview,
    BackupRestore,
    Logs,
    Paths,
}

pub struct LauncherGui {
    paths: AppPaths,
    config: LauncherConfig,
    runtime: tokio::runtime::Runtime,
    tx: mpsc::Sender<GuiEvent>,
    rx: mpsc::Receiver<GuiEvent>,
    status: Option<StatusPayload>,
    backups: Vec<BackupEntry>,
    selected_backup: Option<PathBuf>,
    view: View,
    active_log: LogSource,
    log_text: String,
    log_scroll_to_bottom: bool,
    last_error: String,
    last_message: String,
    moving_to: String,
    files_moving_to: String,
    busy: Option<String>,
    last_refresh: Instant,
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
            backups: Vec::new(),
            selected_backup: None,
            view: View::Overview,
            active_log: LogSource::App,
            log_text: String::new(),
            log_scroll_to_bottom: true,
            last_error: String::new(),
            last_message: String::new(),
            moving_to: String::new(),
            files_moving_to: String::new(),
            busy: None,
            last_refresh: Instant::now() - REFRESH_INTERVAL,
        };
        app.refresh_all();
        app
    }

    fn refresh_all(&mut self) {
        self.reload_config();
        self.refresh_status();
        self.refresh_backups();
        self.refresh_log();
    }

    fn reload_config(&mut self) {
        if let Ok(config) = LauncherConfig::load_or_default(&self.paths.config_path, &self.paths) {
            self.config = config;
        }
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

    fn refresh_backups(&mut self) {
        match list_backups(&self.paths.backups_dir) {
            Ok(backups) => {
                if let Some(selected) = &self.selected_backup {
                    if !backups.iter().any(|backup| &backup.path == selected) {
                        self.selected_backup = None;
                    }
                }
                self.backups = backups;
            }
            Err(error) => self.last_error = error.to_string(),
        }
    }

    fn refresh_log(&mut self) {
        match read_log(&self.paths, &self.config, self.active_log) {
            Ok(text) => self.log_text = text,
            Err(error) => self.last_error = error.to_string(),
        }
    }

    fn run_task<F>(&mut self, label: String, task: F)
    where
        F: Future<Output = Result<String>> + Send + 'static,
    {
        self.busy = Some(label);
        self.last_error.clear();
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
                    self.busy = None;
                    self.last_error.clear();
                    self.last_message = message;
                    self.refresh_all();
                }
                GuiEvent::Error(error) => {
                    self.busy = None;
                    self.last_error = error;
                    self.refresh_all();
                }
            }
        }
    }

    fn tick(&mut self) {
        if self.last_refresh.elapsed() >= REFRESH_INTERVAL {
            self.last_refresh = Instant::now();
            self.refresh_status();
            if matches!(self.view, View::Logs) {
                self.refresh_log();
            }
        }
    }

    fn is_busy(&self) -> bool {
        self.busy.is_some()
    }

    fn try_open_path(&mut self, path: &Path) {
        if let Err(error) = open_path(path) {
            self.last_error = error.to_string();
        }
    }

    fn try_open_log(&mut self, source: LogSource) {
        if let Err(error) = open_log(&self.paths, &self.config, source) {
            self.last_error = error.to_string();
        }
    }

    fn render_top(&mut self, ctx: &egui::Context) {
        let locale = self.config.locale;
        egui::TopBottomPanel::top("launcher_top").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.heading(locale.text(TextKey::Title));
                ui.separator();
                if let Some(status) = &self.status {
                    status_pill(ui, locale, locale.text(TextKey::Application), &status.app);
                    status_pill(ui, locale, locale.text(TextKey::Postgres), &status.postgres);
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui
                        .add_enabled(
                            !self.is_busy(),
                            egui::Button::new(locale.text(TextKey::Refresh)),
                        )
                        .clicked()
                    {
                        self.refresh_all();
                    }
                    if let Some(label) = &self.busy {
                        ui.label(format!("{}: {}", locale.text(TextKey::Busy), label));
                    }
                });
            });
            ui.add_space(6.0);
        });
    }

    fn render_nav(&mut self, ctx: &egui::Context) {
        let locale = self.config.locale;
        egui::SidePanel::left("launcher_nav")
            .resizable(false)
            .default_width(190.0)
            .show(ctx, |ui| {
                let previous_view = self.view;
                ui.add_space(10.0);
                nav_button(
                    ui,
                    &mut self.view,
                    View::Overview,
                    locale.text(TextKey::Overview),
                );
                nav_button(
                    ui,
                    &mut self.view,
                    View::BackupRestore,
                    locale.text(TextKey::BackupRestore),
                );
                nav_button(ui, &mut self.view, View::Logs, locale.text(TextKey::Logs));
                nav_button(ui, &mut self.view, View::Paths, locale.text(TextKey::Paths));
                if previous_view != self.view && matches!(self.view, View::Logs) {
                    self.log_scroll_to_bottom = true;
                    self.refresh_log();
                }
                ui.separator();
                if ui
                    .add_enabled(
                        !self.is_busy(),
                        egui::Button::new(locale.text(TextKey::OpenApp)),
                    )
                    .clicked()
                {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    let label = locale.text(TextKey::OpenApp).to_string();
                    self.run_task(label.clone(), async move {
                        open_command(&paths, &config).await?;
                        Ok(label)
                    });
                }
            });
    }

    fn render_application_card(
        &mut self,
        ui: &mut egui::Ui,
        locale: Locale,
        status: &ServiceStatus,
        rows: &[(&str, String)],
    ) {
        service_card_with_controls(
            ui,
            locale,
            locale.text(TextKey::Application),
            status,
            rows,
            |ui| self.render_application_controls(ui, locale, status),
        );
    }

    fn render_application_controls(
        &mut self,
        ui: &mut egui::Ui,
        locale: Locale,
        status: &ServiceStatus,
    ) {
        ui.add_space(8.0);
        ui.horizontal_wrapped(|ui| {
            let start_enabled = !self.is_busy()
                && !matches!(status.state, ServiceState::Running | ServiceState::Starting);
            if ui
                .add_enabled(
                    start_enabled,
                    egui::Button::new(locale.text(TextKey::Start)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::Start).to_string();
                self.run_task(label.clone(), async move {
                    start_application_command(&paths, &config).await?;
                    Ok(label)
                });
            }

            let stop_enabled = !self.is_busy()
                && matches!(status.state, ServiceState::Running | ServiceState::Starting);
            if ui
                .add_enabled(stop_enabled, egui::Button::new(locale.text(TextKey::Stop)))
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::Stop).to_string();
                self.run_task(label.clone(), async move {
                    stop_application_command(&paths, &config).await?;
                    Ok(label)
                });
            }

            if ui
                .add_enabled(
                    !self.is_busy(),
                    egui::Button::new(locale.text(TextKey::Restart)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::Restart).to_string();
                self.run_task(label.clone(), async move {
                    restart_application_command(&paths, &config).await?;
                    Ok(label)
                });
            }
        });
    }

    fn render_overview(&mut self, ui: &mut egui::Ui) {
        let locale = self.config.locale;
        ui.heading(locale.text(TextKey::Overview));
        ui.add_space(8.0);

        let app_status = self
            .status
            .as_ref()
            .map(|status| status.app.clone())
            .unwrap_or_else(|| ServiceStatus::new(ServiceState::Unknown));
        let postgres_status = self
            .status
            .as_ref()
            .map(|status| status.postgres.clone())
            .unwrap_or_else(|| ServiceStatus::new(ServiceState::Unknown));
        let daemon_status = self
            .status
            .as_ref()
            .map(|status| status.daemon.clone())
            .unwrap_or_else(|| ServiceStatus::new(ServiceState::Unknown));

        let app_rows = [
            (locale.text(TextKey::Url), self.config.app_url()),
            (locale.text(TextKey::Port), self.config.app_port.to_string()),
            (
                locale.text(TextKey::FilesDataDir),
                self.config.files_data_dir.display().to_string(),
            ),
        ];
        let postgres_rows = [
            (
                locale.text(TextKey::DataDir),
                self.config.postgres_data_dir.display().to_string(),
            ),
            (
                locale.text(TextKey::Port),
                self.config.postgres_port.to_string(),
            ),
        ];
        let daemon_rows = [(
            locale.text(TextKey::RuntimeDir),
            self.paths.runtime_dir.display().to_string(),
        )];

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                if ui.available_width() >= 960.0 {
                    ui.columns(3, |columns| {
                        self.render_application_card(
                            &mut columns[0],
                            locale,
                            &app_status,
                            &app_rows,
                        );
                        service_card(
                            &mut columns[1],
                            locale,
                            locale.text(TextKey::Postgres),
                            &postgres_status,
                            &postgres_rows,
                        );
                        service_card(
                            &mut columns[2],
                            locale,
                            locale.text(TextKey::Launcher),
                            &daemon_status,
                            &daemon_rows,
                        );
                    });
                } else {
                    self.render_application_card(ui, locale, &app_status, &app_rows);
                    ui.add_space(8.0);
                    service_card(
                        ui,
                        locale,
                        locale.text(TextKey::Postgres),
                        &postgres_status,
                        &postgres_rows,
                    );
                    ui.add_space(8.0);
                    service_card(
                        ui,
                        locale,
                        locale.text(TextKey::Launcher),
                        &daemon_status,
                        &daemon_rows,
                    );
                }
            });

        ui.add_space(12.0);
        ui.horizontal(|ui| {
            if ui
                .add_enabled(
                    !self.is_busy(),
                    egui::Button::new(locale.text(TextKey::Start)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::Start).to_string();
                self.run_task(label.clone(), async move {
                    start_command(&paths, &config, true).await?;
                    Ok(label)
                });
            }
            if ui
                .add_enabled(
                    !self.is_busy(),
                    egui::Button::new(locale.text(TextKey::Stop)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::Stop).to_string();
                self.run_task(label.clone(), async move {
                    stop_command(&paths, &config).await?;
                    Ok(label)
                });
            }
            if ui
                .add_enabled(
                    !self.is_busy(),
                    egui::Button::new(locale.text(TextKey::Restart)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::Restart).to_string();
                self.run_task(label.clone(), async move {
                    stop_command(&paths, &config).await.ok();
                    start_command(&paths, &config, true).await?;
                    Ok(label)
                });
            }
        });

        self.render_messages(ui);
    }

    fn render_backup_restore(&mut self, ui: &mut egui::Ui) {
        let locale = self.config.locale;
        ui.heading(locale.text(TextKey::BackupRestore));
        ui.add_space(8.0);

        ui.horizontal(|ui| {
            if ui
                .add_enabled(
                    !self.is_busy(),
                    egui::Button::new(locale.text(TextKey::BackupNow)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let config = self.config.clone();
                let label = locale.text(TextKey::BackupNow).to_string();
                self.run_task(label.clone(), async move {
                    let backup = backup_command(&paths, &config, None).await?;
                    Ok(format!("{label}: {}", backup.display()))
                });
            }
            if ui.button(locale.text(TextKey::OpenBackups)).clicked() {
                let path = self.paths.backups_dir.clone();
                self.try_open_path(&path);
            }
            let selected = self.selected_backup.clone();
            if ui
                .add_enabled(
                    !self.is_busy() && selected.is_some(),
                    egui::Button::new(locale.text(TextKey::RestoreSelected)),
                )
                .clicked()
            {
                if let Some(path) = selected {
                    let paths = self.paths.clone();
                    let config = self.config.clone();
                    let label = locale.text(TextKey::RestoreSelected).to_string();
                    self.run_task(label.clone(), async move {
                        restore_command(&paths, &config, &path, true).await?;
                        Ok(format!("{label}: {}", path.display()))
                    });
                }
            }
            if ui
                .add_enabled(
                    self.selected_backup.is_some(),
                    egui::Button::new(locale.text(TextKey::Reveal)),
                )
                .clicked()
            {
                if let Some(path) = self.selected_backup.clone() {
                    self.try_open_path(&path);
                }
            }
        });

        ui.add_space(10.0);
        if self.backups.is_empty() {
            ui.label(locale.text(TextKey::NoBackups));
        } else {
            let table_height = (ui.available_height() - 48.0).max(220.0);
            egui::ScrollArea::both()
                .auto_shrink([false, false])
                .max_height(table_height)
                .show(ui, |ui| {
                    egui::Grid::new("backup_grid")
                        .num_columns(4)
                        .striped(true)
                        .spacing([16.0, 8.0])
                        .min_col_width(80.0)
                        .show(ui, |ui| {
                            ui.strong(locale.text(TextKey::Name));
                            ui.strong(locale.text(TextKey::Modified));
                            ui.strong(locale.text(TextKey::Size));
                            ui.strong(locale.text(TextKey::Paths));
                            ui.end_row();
                            for backup in &self.backups {
                                let selected = self.selected_backup.as_ref() == Some(&backup.path);
                                if ui.selectable_label(selected, &backup.name).clicked() {
                                    self.selected_backup = Some(backup.path.clone());
                                }
                                ui.label(backup.modified_at.as_deref().unwrap_or("-"));
                                ui.label(format_bytes(backup.size_bytes));
                                ui.monospace(compact_path(&backup.path));
                                ui.end_row();
                            }
                        });
                });
        }

        self.render_messages(ui);
    }

    fn render_logs(&mut self, ui: &mut egui::Ui) {
        let locale = self.config.locale;
        ui.heading(locale.text(TextKey::Logs));
        ui.add_space(8.0);

        ui.horizontal(|ui| {
            for source in [LogSource::App, LogSource::Postgres, LogSource::Launcher] {
                let label = log_source_label(locale, source);
                if ui
                    .selectable_label(self.active_log == source, label)
                    .clicked()
                {
                    self.active_log = source;
                    self.log_scroll_to_bottom = true;
                    self.refresh_log();
                }
            }
            ui.separator();
            if ui.button(locale.text(TextKey::Refresh)).clicked() {
                self.refresh_log();
            }
            if ui.button(locale.text(TextKey::Open)).clicked() {
                self.try_open_log(self.active_log);
            }
        });

        ui.add_space(8.0);
        egui::ScrollArea::horizontal()
            .id_salt("active_log_path_scroll")
            .max_height(28.0)
            .show(ui, |ui| {
                ui.monospace(compact_path(&log_path_for(
                    &self.paths,
                    &self.config,
                    self.active_log,
                )));
            });
        ui.add_space(8.0);

        let mut display_text = if self.log_text.is_empty() {
            locale.text(TextKey::AppLogEmpty).to_string()
        } else {
            self.log_text.clone()
        };
        let log_height = (ui.available_height() - 40.0).max(220.0);
        let scroll_to_bottom = self.log_scroll_to_bottom;
        egui::ScrollArea::both()
            .id_salt(format!("log_text_scroll_{}", self.active_log))
            .auto_shrink([false, false])
            .stick_to_bottom(true)
            .max_height(log_height)
            .show(ui, |ui| {
                let response = ui.add(
                    egui::TextEdit::multiline(&mut display_text)
                        .font(egui::TextStyle::Monospace)
                        .desired_rows(36)
                        .desired_width(1600.0)
                        .interactive(false),
                );
                if scroll_to_bottom {
                    ui.scroll_to_rect(response.rect, Some(egui::Align::BOTTOM));
                }
            });
        self.log_scroll_to_bottom = false;

        self.render_messages(ui);
    }

    fn render_paths(&mut self, ui: &mut egui::Ui) {
        let locale = self.config.locale;
        ui.heading(locale.text(TextKey::Paths));
        ui.add_space(8.0);

        let rows = vec![
            (
                locale.text(TextKey::ConfigPath),
                Some(self.paths.config_path.clone()),
            ),
            (locale.text(TextKey::AppDir), self.config.app_dir.clone()),
            (
                locale.text(TextKey::DataDir),
                Some(self.config.postgres_data_dir.clone()),
            ),
            (
                locale.text(TextKey::FilesDataDir),
                Some(self.config.files_data_dir.clone()),
            ),
            (
                locale.text(TextKey::BackupsDir),
                Some(self.paths.backups_dir.clone()),
            ),
            (
                locale.text(TextKey::InstallationsDir),
                Some(self.paths.installations_dir.clone()),
            ),
            (
                locale.text(TextKey::RuntimeDir),
                Some(self.paths.runtime_dir.clone()),
            ),
            (
                locale.text(TextKey::LauncherLog),
                Some(self.paths.launcher_log_path.clone()),
            ),
            (
                locale.text(TextKey::AppLog),
                Some(self.paths.app_log_path.clone()),
            ),
            (
                locale.text(TextKey::PostgresLog),
                Some(log_path_for(&self.paths, &self.config, LogSource::Postgres)),
            ),
        ];

        let paths_height = (ui.available_height() - 86.0).max(220.0);
        egui::ScrollArea::both()
            .auto_shrink([false, false])
            .max_height(paths_height)
            .show(ui, |ui| {
                egui::Grid::new("paths_grid")
                    .num_columns(3)
                    .striped(true)
                    .spacing([14.0, 8.0])
                    .min_col_width(72.0)
                    .show(ui, |ui| {
                        for (label, path) in rows {
                            if ui
                                .add_enabled(
                                    path.is_some(),
                                    egui::Button::new(locale.text(TextKey::Open)),
                                )
                                .clicked()
                            {
                                if let Some(path) = &path {
                                    self.try_open_path(path);
                                }
                            }
                            ui.strong(label);
                            let display_path = path
                                .as_deref()
                                .map(compact_path)
                                .unwrap_or_else(|| "-".to_string());
                            ui.monospace(display_path);
                            ui.end_row();
                        }
                    });
            });

        ui.add_space(16.0);
        ui.separator();
        ui.add_space(8.0);
        ui.horizontal(|ui| {
            ui.label(locale.text(TextKey::DataDir));
            ui.add(
                egui::TextEdit::singleline(&mut self.moving_to)
                    .desired_width(460.0)
                    .hint_text(self.config.postgres_data_dir.display().to_string()),
            );
            if ui
                .add_enabled(
                    !self.is_busy() && !self.moving_to.trim().is_empty(),
                    egui::Button::new(locale.text(TextKey::MoveData)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let mut config = self.config.clone();
                let target = PathBuf::from(self.moving_to.trim());
                let label = locale.text(TextKey::MoveData).to_string();
                self.run_task(label.clone(), async move {
                    move_data_command(&paths, &mut config, &target, false).await?;
                    Ok(format!("{label}: {}", target.display()))
                });
            }
        });
        ui.horizontal(|ui| {
            ui.label(locale.text(TextKey::FilesDataDir));
            ui.add(
                egui::TextEdit::singleline(&mut self.files_moving_to)
                    .desired_width(460.0)
                    .hint_text(self.config.files_data_dir.display().to_string()),
            );
            if ui
                .add_enabled(
                    !self.is_busy() && !self.files_moving_to.trim().is_empty(),
                    egui::Button::new(locale.text(TextKey::MoveFilesData)),
                )
                .clicked()
            {
                let paths = self.paths.clone();
                let mut config = self.config.clone();
                let target = PathBuf::from(self.files_moving_to.trim());
                let label = locale.text(TextKey::MoveFilesData).to_string();
                self.run_task(label.clone(), async move {
                    move_files_data_command(&paths, &mut config, &target, false).await?;
                    Ok(format!("{label}: {}", target.display()))
                });
            }
        });

        self.render_messages(ui);
    }

    fn render_messages(&mut self, ui: &mut egui::Ui) {
        let locale = self.config.locale;
        if !self.last_message.is_empty() {
            ui.add_space(10.0);
            ui.label(format!(
                "{}: {}",
                locale.text(TextKey::LastMessage),
                self.last_message
            ));
        }
        if !self.last_error.is_empty() {
            ui.add_space(10.0);
            ui.colored_label(
                egui::Color32::from_rgb(176, 43, 43),
                format!("{}: {}", locale.text(TextKey::LastError), self.last_error),
            );
        }
    }
}

impl eframe::App for LauncherGui {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_events();
        self.tick();
        self.render_top(ctx);
        self.render_nav(ctx);

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(10.0);
            match self.view {
                View::Overview => self.render_overview(ui),
                View::BackupRestore => self.render_backup_restore(ui),
                View::Logs => self.render_logs(ui),
                View::Paths => self.render_paths(ui),
            }
        });

        ctx.request_repaint_after(Duration::from_millis(250));
    }
}

pub fn run_gui(paths: AppPaths, config: LauncherConfig) -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1080.0, 720.0]),
        run_and_return: false,
        ..Default::default()
    };
    eframe::run_native(
        "Intellectual Club",
        options,
        Box::new(|cc| {
            configure_style(&cc.egui_ctx);
            Ok(Box::new(LauncherGui::new(paths, config)))
        }),
    )
}

fn configure_style(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::light();
    visuals.panel_fill = egui::Color32::from_rgb(247, 248, 250);
    visuals.window_fill = egui::Color32::from_rgb(255, 255, 255);
    ctx.set_visuals(visuals);

    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = egui::vec2(8.0, 8.0);
    style.spacing.window_margin = egui::Margin::same(14);
    ctx.set_style(style);
}

fn nav_button(ui: &mut egui::Ui, active: &mut View, view: View, label: &str) {
    let selected = *active == view;
    if ui
        .add_sized([170.0, 32.0], egui::Button::selectable(selected, label))
        .clicked()
    {
        *active = view;
    }
}

fn service_card(
    ui: &mut egui::Ui,
    locale: Locale,
    title: &str,
    status: &ServiceStatus,
    rows: &[(&str, String)],
) {
    service_card_with_controls(ui, locale, title, status, rows, |_| {});
}

fn service_card_with_controls(
    ui: &mut egui::Ui,
    locale: Locale,
    title: &str,
    status: &ServiceStatus,
    rows: &[(&str, String)],
    controls: impl FnOnce(&mut egui::Ui),
) {
    let margin = egui::Margin::symmetric(12, 10);
    let inner_width = (ui.available_width() - margin.sum().x - 2.0).max(120.0);
    egui::Frame::group(ui.style())
        .inner_margin(margin)
        .show(ui, |ui| {
            ui.set_min_width(inner_width);
            ui.set_max_width(inner_width);
            ui.horizontal_wrapped(|ui| {
                ui.heading(title);
                colored_state(ui, locale, status.state);
            });
            ui.add_space(8.0);
            ui.horizontal_wrapped(|ui| {
                ui.label(format!(
                    "{} {}",
                    locale.text(TextKey::Pid),
                    status.pid.map_or("-".to_string(), |pid| pid.to_string())
                ));
                ui.separator();
                ui.label(if status.healthy {
                    locale.text(TextKey::Healthy)
                } else {
                    locale.text(TextKey::Unhealthy)
                });
            });
            for (label, value) in rows {
                detail_row(ui, label, value);
            }
            if let Some(detail) = &status.detail {
                ui.colored_label(egui::Color32::from_rgb(176, 43, 43), detail);
            }
            controls(ui);
        });
}

fn detail_row(ui: &mut egui::Ui, label: &str, value: &str) {
    ui.add_space(4.0);
    ui.horizontal_wrapped(|ui| {
        ui.label(format!("{label}:"));
        ui.add(
            egui::Label::new(egui::RichText::new(value).monospace())
                .wrap()
                .selectable(true),
        );
    });
}

fn status_pill(ui: &mut egui::Ui, locale: Locale, label: &str, status: &ServiceStatus) {
    ui.horizontal(|ui| {
        ui.label(label);
        colored_state(ui, locale, status.state);
    });
}

fn colored_state(ui: &mut egui::Ui, locale: Locale, state: ServiceState) {
    let color = match state {
        ServiceState::Running => egui::Color32::from_rgb(37, 128, 74),
        ServiceState::Starting | ServiceState::Installed => egui::Color32::from_rgb(150, 104, 24),
        ServiceState::Error => egui::Color32::from_rgb(176, 43, 43),
        ServiceState::Stopped | ServiceState::NotInstalled | ServiceState::Unknown => {
            egui::Color32::from_rgb(82, 91, 106)
        }
    };
    ui.colored_label(color, state_label(locale, state));
}

fn state_label(locale: Locale, state: ServiceState) -> &'static str {
    match state {
        ServiceState::Running => locale.text(TextKey::Running),
        ServiceState::Starting => locale.text(TextKey::Starting),
        ServiceState::Stopped => locale.text(TextKey::Stopped),
        ServiceState::Installed => locale.text(TextKey::Installed),
        ServiceState::NotInstalled => locale.text(TextKey::NotInstalled),
        ServiceState::Error => locale.text(TextKey::Error),
        ServiceState::Unknown => locale.text(TextKey::Unknown),
    }
}

fn log_source_label(locale: Locale, source: LogSource) -> &'static str {
    match source {
        LogSource::App => locale.text(TextKey::AppLog),
        LogSource::Postgres => locale.text(TextKey::PostgresLog),
        LogSource::Launcher | LogSource::All => locale.text(TextKey::LauncherLog),
    }
}

fn compact_path(path: &Path) -> String {
    path.display().to_string()
}

fn format_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    let bytes = bytes as f64;
    if bytes >= GB {
        format!("{:.1} GB", bytes / GB)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes / MB)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes / KB)
    } else {
        format!("{} B", bytes as u64)
    }
}
