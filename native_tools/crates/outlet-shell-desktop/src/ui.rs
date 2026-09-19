use eframe::egui::{self, Color32, RichText};

use crate::history::{CallState, EntryKind, History};
use crate::i18n::{Locale, Text};
use crate::{
    generate_secret, ConnectionMode, OutletDesktopApp, ProfileAction, ProfileStatus,
    APP_DISPLAY_NAME,
};

const GREEN: Color32 = Color32::from_rgb(88, 190, 147);
const AMBER: Color32 = Color32::from_rgb(221, 170, 89);
const RED: Color32 = Color32::from_rgb(228, 115, 118);

pub fn configure(ctx: &egui::Context) {
    ctx.style_mut(|style| {
        style.spacing.item_spacing = egui::vec2(10.0, 7.0);
        style.spacing.button_padding = egui::vec2(12.0, 7.0);
        style.spacing.interact_size.y = 32.0;
        style
            .text_styles
            .insert(egui::TextStyle::Body, egui::FontId::proportional(14.0));
        style
            .text_styles
            .insert(egui::TextStyle::Button, egui::FontId::proportional(14.0));
        style
            .text_styles
            .insert(egui::TextStyle::Monospace, egui::FontId::monospace(13.0));
    });
}

fn status_color(status: &ProfileStatus) -> Color32 {
    if status.online {
        GREEN
    } else if !status.running {
        Color32::GRAY
    } else if !status.error.is_empty() {
        RED
    } else {
        AMBER
    }
}

fn dot(ui: &mut egui::Ui, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(10.0, 16.0), egui::Sense::hover());
    ui.painter().circle_filled(rect.center(), 3.5, color);
}

impl OutletDesktopApp {
    pub(super) fn render(&mut self, ctx: &egui::Context) {
        let locale = self.config.locale;
        egui::TopBottomPanel::bottom("app_footer")
            .frame(egui::Frame::new().inner_margin(egui::Margin::symmetric(20, 7)))
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.weak(APP_DISPLAY_NAME);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let mut selected = locale;
                        ui.selectable_value(&mut selected, Locale::Ru, "Русский");
                        ui.selectable_value(&mut selected, Locale::En, "English");
                        if selected != locale {
                            self.config.locale = selected;
                            self.save();
                        }
                    });
                });
            });

        egui::TopBottomPanel::top("server_tabs")
            .frame(
                egui::Frame::new()
                    .fill(ctx.style().visuals.faint_bg_color)
                    .inner_margin(egui::Margin::symmetric(12, 9)),
            )
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    let plus_width = 42.0;
                    egui::ScrollArea::horizontal()
                        .id_salt("tabs_scroll")
                        .max_width((ui.available_width() - plus_width - 12.0).max(100.0))
                        .auto_shrink([true, true])
                        .show(ui, |ui| {
                            ui.horizontal(|ui| {
                                for profile in &self.config.profiles {
                                    let status =
                                        self.statuses.get(&profile.id).cloned().unwrap_or_default();
                                    let selected =
                                        self.active_profile.as_deref() == Some(profile.id.as_str());
                                    let fill = if selected {
                                        ui.visuals().panel_fill
                                    } else {
                                        Color32::TRANSPARENT
                                    };
                                    let response = ui
                                        .add_sized(
                                            [210.0, 40.0],
                                            egui::Button::new(
                                                RichText::new(format!("  {}", profile.name))
                                                    .size(14.0),
                                            )
                                            .fill(fill)
                                            .truncate(),
                                        )
                                        .on_hover_text(format!(
                                            "{}\n{}",
                                            profile.server_url,
                                            locale.text(status.label())
                                        ));
                                    ui.painter().circle_filled(
                                        egui::pos2(
                                            response.rect.left() + 13.0,
                                            response.rect.center().y,
                                        ),
                                        3.5,
                                        status_color(&status),
                                    );
                                    if selected {
                                        if self.scroll_to_active_tab {
                                            response.scroll_to_me(Some(egui::Align::Center));
                                            self.scroll_to_active_tab = false;
                                        }
                                        ui.painter().hline(
                                            response.rect.x_range(),
                                            response.rect.bottom() + 3.0,
                                            egui::Stroke::new(2.0, GREEN),
                                        );
                                    }
                                    if response.clicked() {
                                        self.active_profile = Some(profile.id.clone());
                                    }
                                }
                            });
                        });
                    if ui
                        .add_sized(
                            [plus_width, 40.0],
                            egui::Button::new(RichText::new("+").size(24.0)),
                        )
                        .on_hover_text(locale.text(Text::AddConnection))
                        .clicked()
                    {
                        self.open_connection(None);
                    }
                });
            });

        egui::CentralPanel::default()
            .frame(egui::Frame::central_panel(&ctx.style()).inner_margin(20))
            .show(ctx, |ui| {
                if !self.last_error.is_empty() {
                    ui.horizontal_wrapped(|ui| {
                        ui.colored_label(RED, &self.last_error);
                        if ui.small_button(locale.text(Text::Close)).clicked() {
                            self.last_error.clear();
                        }
                    });
                    ui.add_space(4.0);
                }
                if let Some(profile) = self
                    .active_profile
                    .as_ref()
                    .and_then(|id| self.config.profiles.iter().find(|p| &p.id == id))
                    .cloned()
                {
                    let status = self.statuses.get(&profile.id).cloned().unwrap_or_default();
                    let mut action = None;
                    ui.horizontal(|ui| {
                        let title_width = (ui.available_width() - 250.0).max(180.0);
                        ui.vertical(|ui| {
                            ui.set_width(title_width);
                            ui.add(
                                egui::Label::new(RichText::new(&profile.name).size(23.0).strong())
                                    .truncate(),
                            )
                            .on_hover_text(&profile.name);
                            ui.add(
                                egui::Label::new(RichText::new(&profile.server_url).weak())
                                    .truncate(),
                            )
                            .on_hover_text(&profile.server_url);
                        });
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            ui.menu_button(locale.text(Text::Settings), |ui| {
                                let mut auto_start = profile.auto_start;
                                if ui
                                    .checkbox(&mut auto_start, locale.text(Text::AutoStart))
                                    .changed()
                                {
                                    action = Some(ProfileAction::ToggleAutoStart(
                                        profile.id.clone(),
                                        auto_start,
                                    ));
                                }
                                ui.separator();
                                if ui.button(locale.text(Text::Reconnect)).clicked() {
                                    action = Some(ProfileAction::Repair(profile.id.clone()));
                                    ui.close();
                                }
                                if ui
                                    .button(RichText::new(locale.text(Text::Remove)).color(RED))
                                    .clicked()
                                {
                                    action = Some(ProfileAction::Delete(profile.id.clone()));
                                    ui.close();
                                }
                            });
                            if status.running {
                                if ui.button(locale.text(Text::Stop)).clicked() {
                                    action = Some(ProfileAction::Stop(profile.id.clone()));
                                }
                            } else if ui.button(locale.text(Text::Start)).clicked() {
                                action = Some(ProfileAction::Start(profile.id.clone()));
                            }
                        });
                    });
                    ui.add_space(4.0);
                    let history = self.histories.entry(profile.id.clone()).or_default();
                    let (running, done, failed) = history.counts();
                    ui.horizontal_wrapped(|ui| {
                        ui.spacing_mut().interact_size.y = 18.0;
                        dot(ui, status_color(&status));
                        ui.label(
                            RichText::new(locale.text(status.label())).color(status_color(&status)),
                        );
                        ui.separator();
                        ui.label(format!("{}  {running}", locale.text(Text::Running)));
                        ui.weak(format!("{}  {done}", locale.text(Text::Done)));
                        ui.weak(format!("{}  {failed}", locale.text(Text::Failed)));
                    });
                    if !status.error.is_empty() {
                        ui.add(
                            egui::Label::new(RichText::new(&status.error).color(RED)).truncate(),
                        )
                        .on_hover_text(&status.error);
                    }
                    ui.add_space(6.0);
                    ui.separator();
                    render_history(ui, history, &profile.id, locale);
                    if let Some(action) = action {
                        self.apply_action(action);
                    }
                } else {
                    ui.add_space((ui.available_height() * 0.28).max(20.0));
                    ui.vertical_centered(|ui| {
                        ui.label(
                            RichText::new(locale.text(Text::EmptyTitle))
                                .size(28.0)
                                .strong(),
                        );
                        ui.add_space(8.0);
                        ui.label(locale.text(Text::EmptyHelp));
                        ui.weak(locale.text(Text::EmptyHint));
                        ui.add_space(12.0);
                        if ui
                            .add_sized(
                                [220.0, 42.0],
                                egui::Button::new(locale.text(Text::AddConnection)),
                            )
                            .clicked()
                        {
                            self.open_connection(None);
                        }
                    });
                }
            });
        self.render_connection(ctx);
        self.render_remove(ctx);
    }

    fn render_connection(&mut self, ctx: &egui::Context) {
        let locale = self.config.locale;
        let Some(form) = &mut self.connection else {
            return;
        };
        let mut connect = false;
        let mut close = false;
        let busy = form.request_id.is_some();
        let modal = egui::Modal::new(egui::Id::new("connect_server"))
            .frame(
                egui::Frame::popup(&ctx.style())
                    .inner_margin(24)
                    .corner_radius(12),
            )
            .show(ctx, |ui| {
                ui.set_width(480.0_f32.min(ctx.content_rect().width() - 80.0));
                ui.heading(locale.text(if form.profile_id.is_some() {
                    Text::EditConnection
                } else {
                    Text::AddConnection
                }));
                ui.add_space(6.0);
                ui.add_enabled_ui(!busy, |ui| {
                    let label = ui.label(locale.text(Text::ServerUrl));
                    ui.add(
                        egui::TextEdit::singleline(&mut form.server_url)
                            .desired_width(f32::INFINITY)
                            .hint_text("https://club.example.com"),
                    )
                    .labelled_by(label.id);
                    ui.add_space(6.0);
                    ui.horizontal(|ui| {
                        ui.selectable_value(
                            &mut form.mode,
                            ConnectionMode::Browser,
                            locale.text(Text::BrowserPairing),
                        );
                        ui.selectable_value(
                            &mut form.mode,
                            ConnectionMode::Secret,
                            locale.text(Text::SharedSecret),
                        );
                    });
                });
                ui.separator();
                match form.mode {
                    ConnectionMode::Browser => {
                        ui.label(locale.text(Text::PairingHelp));
                        if let Some(pairing) = &form.pairing {
                            ui.add_space(6.0);
                            ui.horizontal(|ui| {
                                ui.spinner();
                                ui.label(locale.text(Text::PairWaiting));
                            });
                            ui.weak(locale.text(Text::PairCode));
                            ui.horizontal(|ui| {
                                ui.label(RichText::new(&pairing.user_code).monospace().size(27.0));
                                if ui.button(locale.text(Text::Copy)).clicked() {
                                    ctx.copy_text(pairing.user_code.clone());
                                }
                            });
                            ui.hyperlink_to(
                                locale.text(Text::OpenBrowser),
                                &pairing.verification_url,
                            );
                        } else if busy {
                            ui.horizontal(|ui| {
                                ui.spinner();
                                ui.label(locale.text(Text::PairStarting));
                            });
                        }
                    }
                    ConnectionMode::Secret => {
                        ui.label(locale.text(Text::SecretHelp));
                        ui.add_enabled_ui(!busy, |ui| {
                            let label = ui.label(locale.text(Text::SharedSecret));
                            let secret = ui
                                .add(
                                    egui::TextEdit::singleline(&mut form.secret)
                                        .password(!form.show_secret)
                                        .desired_width(f32::INFINITY),
                                )
                                .labelled_by(label.id);
                            if secret.changed() {
                                form.copied = false;
                            }
                            ui.horizontal_wrapped(|ui| {
                                if ui.button(locale.text(Text::GenerateCopy)).clicked() {
                                    match generate_secret() {
                                        Ok(token) => {
                                            ctx.copy_text(token.clone());
                                            form.secret = token;
                                            form.copied = true;
                                            form.error.clear();
                                        }
                                        Err(error) => form.error = error.to_string(),
                                    }
                                }
                                if ui.button(locale.text(Text::Paste)).clicked() {
                                    secret.request_focus();
                                    let mut state = egui::TextEdit::load_state(ctx, secret.id)
                                        .unwrap_or_default();
                                    state.cursor.set_char_range(Some(
                                        egui::text::CCursorRange::two(
                                            egui::text::CCursor::new(0),
                                            egui::text::CCursor::new(form.secret.chars().count()),
                                        ),
                                    ));
                                    state.store(ctx, secret.id);
                                    ctx.send_viewport_cmd(egui::ViewportCommand::RequestPaste);
                                    form.copied = false;
                                }
                                if form.copied {
                                    ui.colored_label(GREEN, locale.text(Text::Copied));
                                }
                            });
                            ui.checkbox(&mut form.show_secret, locale.text(Text::ShowSecret));
                        });
                        if busy {
                            ui.horizontal(|ui| {
                                ui.spinner();
                                ui.label(locale.text(Text::Verify));
                            });
                        }
                    }
                }
                if !form.error.is_empty() {
                    ui.colored_label(RED, &form.error);
                }
                ui.add_space(10.0);
                ui.horizontal(|ui| {
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if !busy {
                            let label = match form.mode {
                                ConnectionMode::Browser => Text::Pair,
                                ConnectionMode::Secret => Text::Connect,
                            };
                            if ui.button(locale.text(label)).clicked() {
                                connect = true;
                            }
                        }
                        if ui.button(locale.text(Text::Cancel)).clicked() {
                            close = true;
                        }
                    });
                });
            });
        if close || modal.should_close() {
            self.close_connection();
        } else if connect {
            self.connect();
        }
    }

    fn render_remove(&mut self, ctx: &egui::Context) {
        let Some(id) = self.remove_profile.clone() else {
            return;
        };
        let locale = self.config.locale;
        let mut remove = false;
        let mut close = false;
        let modal = egui::Modal::new(egui::Id::new("remove_connection")).show(ctx, |ui| {
            ui.set_width(420.0);
            ui.heading(locale.text(Text::RemoveTitle));
            if let Some(profile) = self.config.profiles.iter().find(|p| p.id == id) {
                ui.strong(&profile.name);
            }
            ui.label(locale.text(Text::RemoveHelp));
            ui.horizontal(|ui| {
                if ui.button(locale.text(Text::Cancel)).clicked() {
                    close = true;
                }
                if ui
                    .button(RichText::new(locale.text(Text::RemoveConfirm)).color(RED))
                    .clicked()
                {
                    remove = true;
                }
            });
        });
        if remove {
            self.delete_profile(&id);
        }
        if remove || close || modal.should_close() {
            self.remove_profile = None;
        }
    }
}

fn render_history(ui: &mut egui::Ui, history: &mut History, profile_id: &str, locale: Locale) {
    ui.horizontal_wrapped(|ui| {
        ui.strong(locale.text(Text::History));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui
                .small_button(locale.text(Text::Clear))
                .on_hover_text(locale.text(Text::ClearHelp))
                .clicked()
            {
                history.clear_finished();
            }
            if ui.small_button(locale.text(Text::CopyLog)).clicked() {
                ui.ctx().copy_text(history.text(locale));
            }
            ui.checkbox(&mut history.follow, locale.text(Text::Follow));
        });
    });
    ui.label(RichText::new(locale.text(Text::HistoryHint)).small().weak());
    let fill = if ui.visuals().dark_mode {
        Color32::from_rgb(22, 25, 29)
    } else {
        Color32::from_rgb(247, 249, 250)
    };
    egui::Frame::new()
        .fill(fill)
        .stroke(ui.visuals().widgets.noninteractive.bg_stroke)
        .corner_radius(8)
        .inner_margin(14)
        .show(ui, |ui| {
            let size = ui.available_size();
            ui.set_min_size(size);
            egui::ScrollArea::vertical()
                .id_salt(("history", profile_id))
                .auto_shrink([false, false])
                .stick_to_bottom(history.follow)
                .max_height(size.y)
                .show(ui, |ui| {
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.spacing_mut().interact_size.y = 20.0;
                    ui.set_min_width(ui.available_width());
                    if history.entries.is_empty() {
                        ui.add_space(50.0);
                        ui.vertical_centered(|ui| {
                            ui.strong(locale.text(Text::NoCommands));
                            ui.weak(locale.text(Text::NoCommandsHelp));
                        });
                    }
                    for entry in &history.entries {
                        ui.push_id((profile_id, entry.sequence), |ui| match &entry.kind {
                            EntryKind::Notice(label, detail) => {
                                ui.horizontal_wrapped(|ui| {
                                    ui.label(RichText::new(&entry.time).monospace().weak());
                                    ui.weak(locale.text(*label));
                                    if !detail.is_empty() {
                                        ui.weak(detail);
                                    }
                                });
                            }
                            EntryKind::Call(call) => {
                                let color = match call.state {
                                    CallState::Running => AMBER,
                                    CallState::Done => GREEN,
                                    CallState::Failed => RED,
                                    CallState::Interrupted => Color32::GRAY,
                                };
                                ui.horizontal_wrapped(|ui| {
                                    ui.label(RichText::new(&entry.time).monospace().weak());
                                    ui.label(
                                        RichText::new(locale.text(call.state.label())).color(color),
                                    );
                                    ui.weak(&call.function);
                                    if let Some(duration) = call.duration_ms {
                                        ui.weak(format!("{:.2} s", duration as f64 / 1000.0));
                                    }
                                    if let Some(code) = call.exit_code {
                                        ui.weak(format!("{} {code}", locale.text(Text::ExitCode)));
                                    }
                                });
                                if let Some(description) = &call.description {
                                    ui.add(egui::Label::new(description).wrap().selectable(true));
                                }
                                if let Some(command) = &call.command {
                                    ui.add(
                                        egui::Label::new(RichText::new(command).monospace())
                                            .wrap()
                                            .selectable(true),
                                    );
                                }
                                if !call.error.is_empty() {
                                    ui.colored_label(RED, &call.error);
                                }
                                egui::CollapsingHeader::new(locale.text(Text::Details))
                                    .id_salt("details")
                                    .show(ui, |ui| {
                                        ui.weak(format!(
                                            "{}: {}",
                                            locale.text(Text::CallId),
                                            call.call_id
                                        ));
                                        if !call.output.is_empty() {
                                            ui.add(
                                                egui::Label::new(
                                                    RichText::new(&call.output).monospace(),
                                                )
                                                .wrap()
                                                .selectable(true),
                                            );
                                        }
                                    });
                                ui.separator();
                            }
                        });
                    }
                });
        });
}
