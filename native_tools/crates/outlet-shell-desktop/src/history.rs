use std::collections::VecDeque;

use chrono::Local;
use outlet_core::RunnerEvent;

use crate::i18n::{Locale, Text};

const MAX_ENTRIES: usize = 1_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CallState {
    Running,
    Done,
    Failed,
    Interrupted,
}

impl CallState {
    pub fn label(self) -> Text {
        match self {
            Self::Running => Text::Running,
            Self::Done => Text::Done,
            Self::Failed => Text::Failed,
            Self::Interrupted => Text::Interrupted,
        }
    }
}

#[derive(Debug)]
pub struct CallEntry {
    pub call_id: String,
    pub function: String,
    pub command: Option<String>,
    pub description: Option<String>,
    pub state: CallState,
    pub duration_ms: Option<u128>,
    pub exit_code: Option<i64>,
    pub output: String,
    pub error: String,
}

#[derive(Debug)]
pub enum EntryKind {
    Notice(Text, String),
    Call(CallEntry),
}

#[derive(Debug)]
pub struct LogEntry {
    pub sequence: u64,
    pub time: String,
    pub kind: EntryKind,
}

#[derive(Debug)]
pub struct History {
    pub entries: VecDeque<LogEntry>,
    pub follow: bool,
    sequence: u64,
}

impl Default for History {
    fn default() -> Self {
        Self {
            entries: VecDeque::new(),
            follow: true,
            sequence: 0,
        }
    }
}

impl History {
    fn push(&mut self, kind: EntryKind) {
        if self.entries.len() >= MAX_ENTRIES {
            let removable = self.entries.iter().position(|entry| !is_running(entry));
            self.entries.remove(removable.unwrap_or(0));
        }
        self.sequence += 1;
        self.entries.push_back(LogEntry {
            sequence: self.sequence,
            time: Local::now().format("%H:%M:%S").to_string(),
            kind,
        });
    }

    pub fn notice(&mut self, label: Text, detail: String) {
        self.push(EntryKind::Notice(label, bounded(&detail)));
    }

    pub fn apply(&mut self, event: &RunnerEvent) {
        match event {
            RunnerEvent::CallStarted {
                call_id,
                function_name,
                command,
                description,
            } => {
                self.push(EntryKind::Call(CallEntry {
                    call_id: call_id.clone(),
                    function: bounded(function_name),
                    command: command.as_deref().map(bounded),
                    description: description.as_deref().map(bounded),
                    state: CallState::Running,
                    duration_ms: None,
                    exit_code: None,
                    output: String::new(),
                    error: String::new(),
                }));
            }
            RunnerEvent::CallFinished {
                call_id,
                function_name,
                status,
                duration_ms,
                error_text,
                exit_code,
                output,
            } => {
                let state = if status == "done"
                    && error_text.is_empty()
                    && exit_code.is_none_or(|code| code == 0)
                {
                    CallState::Done
                } else {
                    CallState::Failed
                };
                let existing =
                    self.entries
                        .iter_mut()
                        .rev()
                        .find_map(|entry| match &mut entry.kind {
                            EntryKind::Call(call) if call.call_id == *call_id => Some(call),
                            _ => None,
                        });
                if let Some(call) = existing {
                    call.state = state;
                    call.duration_ms = Some(*duration_ms);
                    call.exit_code = *exit_code;
                    call.error = bounded(error_text);
                    call.output = bounded(output);
                } else {
                    self.push(EntryKind::Call(CallEntry {
                        call_id: call_id.clone(),
                        function: bounded(function_name),
                        command: None,
                        description: None,
                        state,
                        duration_ms: Some(*duration_ms),
                        exit_code: *exit_code,
                        output: bounded(output),
                        error: bounded(error_text),
                    }));
                }
            }
            _ => {}
        }
    }

    pub fn interrupt(&mut self) {
        for entry in &mut self.entries {
            if let EntryKind::Call(call) = &mut entry.kind {
                if call.state == CallState::Running {
                    call.state = CallState::Interrupted;
                }
            }
        }
    }

    pub fn clear_finished(&mut self) {
        self.entries.retain(is_running);
    }

    pub fn counts(&self) -> (usize, usize, usize) {
        let mut counts = (0, 0, 0);
        for entry in &self.entries {
            if let EntryKind::Call(call) = &entry.kind {
                match call.state {
                    CallState::Running => counts.0 += 1,
                    CallState::Done => counts.1 += 1,
                    CallState::Failed | CallState::Interrupted => counts.2 += 1,
                }
            }
        }
        counts
    }

    pub fn text(&self, locale: Locale) -> String {
        self.entries
            .iter()
            .map(|entry| match &entry.kind {
                EntryKind::Notice(label, detail) => {
                    format!("{}  {}  {}", entry.time, locale.text(*label), detail)
                }
                EntryKind::Call(call) => format!(
                    "{}  {}  {}  {}{}\n{}: {} ms  {}: {}\n{}\n{}",
                    entry.time,
                    locale.text(call.state.label()),
                    call.function,
                    call.command.as_deref().unwrap_or(""),
                    call.description
                        .as_ref()
                        .map(|description| format!("\n{description}"))
                        .unwrap_or_default(),
                    locale.text(Text::Duration),
                    call.duration_ms.map(|v| v.to_string()).unwrap_or_default(),
                    locale.text(Text::ExitCode),
                    call.exit_code.map(|v| v.to_string()).unwrap_or_default(),
                    call.output,
                    call.error
                ),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn is_running(entry: &LogEntry) -> bool {
    matches!(&entry.kind, EntryKind::Call(call) if call.state == CallState::Running)
}

fn bounded(value: &str) -> String {
    let mut chars = value.chars();
    let mut result: String = chars.by_ref().take(16_000).collect();
    if chars.next().is_some() {
        result.push_str("\n…");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start(id: &str) -> RunnerEvent {
        RunnerEvent::CallStarted {
            call_id: id.into(),
            function_name: "run_command".into(),
            command: Some("pwd".into()),
            description: (id == "one").then(|| "Show the working directory.".into()),
        }
    }

    #[test]
    fn completion_updates_its_command_and_preserves_other_calls() {
        let mut history = History::default();
        history.apply(&start("one"));
        history.apply(&start("two"));
        history.apply(&RunnerEvent::CallFinished {
            call_id: "one".into(),
            function_name: "run_command".into(),
            status: "done".into(),
            duration_ms: 42,
            error_text: String::new(),
            exit_code: Some(1),
            output: "failed command".into(),
        });
        assert_eq!(history.entries.len(), 2);
        assert_eq!(history.counts(), (1, 0, 1));
        assert!(history.text(Locale::En).contains("failed command"));
        assert!(history
            .text(Locale::En)
            .contains("Show the working directory."));
        history.clear_finished();
        assert_eq!(history.counts(), (1, 0, 0));
        assert!(!history
            .text(Locale::En)
            .contains("Show the working directory."));
        history.interrupt();
        assert_eq!(history.counts(), (0, 0, 1));
    }

    #[test]
    fn history_is_bounded_without_evicting_running_commands() {
        let mut history = History::default();
        history.apply(&start("running"));
        for _ in 0..1_100 {
            history.notice(Text::Online, String::new());
        }
        assert_eq!(history.entries.len(), MAX_ENTRIES);
        assert_eq!(history.counts().0, 1);
        assert!(history.text(Locale::En).contains("pwd"));
    }
}
