use std::collections::HashMap;
use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use outlet_core::{CallContext, ToolProvider, ToolResult, ToolSpec};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::task::{AbortHandle, JoinHandle};
use tracing::info;

const POSIX_SHELL_BASENAMES: &[&str] = &["bash", "zsh", "sh", "dash", "ksh"];
const TIMEOUT_TERMINATE_GRACE_SECONDS: f64 = 2.0;
const TIMEOUT_DRAIN_SECONDS: f64 = 5.0;
const MAX_STREAM_CHARS_DEFAULT: usize = 200_000;
const MAX_SUMMARY_CHARS_DEFAULT: usize = 50_000;
const UTF8_ENCODING: &str = "utf-8";
const WINDOWS_UTF8_BOOTSTRAP_MODE: &str = "windows-force-utf8";
const WINDOWS_FORCE_UTF8_ENV: &str = "SHELL_OUTLET_WINDOWS_FORCE_UTF8";

#[derive(Clone, Debug)]
pub struct ShellExecutor {
    kind: String,
    argv_prefix: Vec<String>,
    display_name: String,
}

#[derive(Clone, Debug)]
pub struct ShellOutlet {
    executor: ShellExecutor,
}

impl Default for ShellOutlet {
    fn default() -> Self {
        Self::new()
    }
}

impl ShellOutlet {
    pub fn new() -> Self {
        Self {
            executor: detect_shell_executor(),
        }
    }

    pub fn executor(&self) -> &ShellExecutor {
        &self.executor
    }

    pub async fn run_command_from_value(&self, args: Value) -> Result<ToolResult> {
        let args: RunCommandArgs =
            serde_json::from_value(args).context("invalid run_command arguments")?;
        let (text, raw) = self.run_command(args, None).await?;
        Ok(ToolResult::new(text, raw))
    }

    async fn run_command_from_value_with_context(
        &self,
        args: Value,
        context: &CallContext,
    ) -> Result<ToolResult> {
        let args: RunCommandArgs =
            serde_json::from_value(args).context("invalid run_command arguments")?;
        let (text, raw) = self.run_command(args, Some(context)).await?;
        Ok(ToolResult::new(text, raw))
    }

    async fn run_command(
        &self,
        args: RunCommandArgs,
        context: Option<&CallContext>,
    ) -> Result<(String, Value)> {
        let argv = args
            .argv
            .unwrap_or_default()
            .into_iter()
            .map(|item| item.to_string())
            .filter(|item| !item.is_empty())
            .collect::<Vec<_>>();
        let command = args.command.unwrap_or_default();
        if argv.is_empty() && command.trim().is_empty() {
            return Err(anyhow!("command or argv is required"));
        }

        let command_display = if argv.is_empty() {
            command.clone()
        } else {
            shlex_join(&argv)
        };
        info!(command = %command_display, "shell command");

        let max_stream_chars =
            load_env_usize("SHELL_OUTLET_MAX_STREAM_CHARS", MAX_STREAM_CHARS_DEFAULT);
        let max_summary_chars =
            load_env_usize("SHELL_OUTLET_MAX_SUMMARY_CHARS", MAX_SUMMARY_CHARS_DEFAULT);
        let max_capture_bytes = max_stream_chars.saturating_mul(4);

        let mut merged_env = env::vars().collect::<HashMap<String, String>>();
        if let Some(env_map) = args.env {
            for (key, value) in env_map {
                merged_env.insert(key, json_value_to_env_string(value));
            }
        }

        let mut shell_encoding_bootstrap = String::new();
        let command_to_spawn;
        let spawn_args;
        let shell_kind_for_raw;
        let shell_executor_for_raw;
        let shell_argv_prefix_for_raw;

        if argv.is_empty() {
            let mut shell_command = command;
            if should_bootstrap_windows_powershell(&self.executor.kind, &merged_env) {
                shell_command = wrap_windows_powershell_command(&shell_command);
                shell_encoding_bootstrap = WINDOWS_UTF8_BOOTSTRAP_MODE.to_string();
            }

            let mut full = self.executor.argv_prefix.clone();
            full.push(shell_command);
            command_to_spawn = full
                .first()
                .cloned()
                .ok_or_else(|| anyhow!("shell executor is unavailable"))?;
            spawn_args = full.into_iter().skip(1).collect::<Vec<_>>();
            shell_kind_for_raw = self.executor.kind.clone();
            shell_executor_for_raw = command_to_spawn.clone();
            shell_argv_prefix_for_raw = self.executor.argv_prefix.clone();
        } else {
            command_to_spawn = argv[0].clone();
            spawn_args = argv.iter().skip(1).cloned().collect::<Vec<_>>();
            shell_kind_for_raw = String::new();
            shell_executor_for_raw = String::new();
            shell_argv_prefix_for_raw = Vec::new();
        }

        let mut command = Command::new(&command_to_spawn);
        command.kill_on_drop(true);
        command
            .args(&spawn_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        if let Some(cwd) = args
            .cwd
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            command.current_dir(expand_path(cwd));
        }
        command.env_clear();
        command.envs(&merged_env);
        configure_process_isolation(&mut command);

        let mut child = command
            .spawn()
            .with_context(|| format!("failed to spawn command: {command_display}"))?;
        let mut process_group = ProcessGroupGuard::new(child.id());

        let mut stdin_task = write_stdin(child.stdin.take(), args.stdin.unwrap_or_default());
        let stdout_capture = PipeCapture::new(max_capture_bytes);
        let stderr_capture = PipeCapture::new(max_capture_bytes);
        let mut stdout_task = read_pipe(
            child.stdout.take(),
            context.cloned(),
            "stdout",
            stdout_capture.clone(),
        );
        let mut stderr_task = read_pipe(
            child.stderr.take(),
            context.cloned(),
            "stderr",
            stderr_capture.clone(),
        );
        let mut task_guard = AbortTasksGuard::new([
            stdin_task.abort_handle(),
            stdout_task.abort_handle(),
            stderr_task.abort_handle(),
        ]);

        let timeout = args
            .timeout_seconds
            .and_then(|seconds| (seconds > 0).then_some(Duration::from_secs(seconds)));
        let (status, timed_out, wait_canceled) =
            wait_for_command(&mut child, process_group.id(), timeout, context).await?;

        finish_stdin(&mut stdin_task).await;
        let drain = drain_output_tasks(
            &mut stdout_task,
            &mut stderr_task,
            context,
            Duration::from_secs_f64(TIMEOUT_DRAIN_SECONDS),
        )
        .await;
        let canceled = wait_canceled || drain.canceled;
        if drain.timed_out || drain.canceled {
            force_kill_process_tree(&mut child, process_group.id()).await;
        }
        if drain.timed_out {
            stderr_capture.append_notice(
                b"[timeout] command output pipes did not close within the drain window.\n",
            );
        }
        let stdout = stdout_capture.snapshot();
        let stderr = stderr_capture.snapshot();
        task_guard.disarm();
        process_group.disarm();

        let exit_code = status.code().unwrap_or(if timed_out { -9 } else { -1 });
        let (stdout_text, stdout_decode_error) = decode_utf8_output(&stdout.bytes);
        let (stderr_text, stderr_decode_error) = decode_utf8_output(&stderr.bytes);

        let (stdout_text, stdout_chars_truncated) = truncate_text(&stdout_text, max_stream_chars);
        let (stderr_text, stderr_chars_truncated) = truncate_text(&stderr_text, max_stream_chars);
        let stdout_truncated = stdout.truncated || stdout_chars_truncated;
        let stderr_truncated = stderr.truncated || stderr_chars_truncated;

        let mut summary = stdout_text.clone();
        if !stderr_text.is_empty() {
            if !summary.is_empty() {
                summary.push('\n');
            }
            summary.push_str(&stderr_text);
        }
        let (mut summary, summary_truncated) = truncate_text(summary.trim(), max_summary_chars);
        if timed_out {
            summary = append_command_timeout_notice(&summary, args.timeout_seconds);
        }

        let raw = json!({
            "argv": argv,
            "shell_kind": shell_kind_for_raw,
            "shell_executor": shell_executor_for_raw,
            "shell_argv_prefix": shell_argv_prefix_for_raw,
            "shell_encoding_bootstrap": shell_encoding_bootstrap,
            "exit_code": exit_code,
            "stdout": stdout_text,
            "stderr": stderr_text,
            "stdout_encoding": UTF8_ENCODING,
            "stderr_encoding": UTF8_ENCODING,
            "stdout_decode_error": stdout_decode_error,
            "stderr_decode_error": stderr_decode_error,
            "timed_out": timed_out,
            "canceled": canceled,
            "output_drain_timed_out": drain.timed_out,
            "stdout_truncated": stdout_truncated,
            "stderr_truncated": stderr_truncated,
            "summary_truncated": summary_truncated,
            "stdout_bytes_total": stdout.bytes_total,
            "stderr_bytes_total": stderr.bytes_total,
        });

        Ok((summary, raw))
    }

    async fn read_image(&self, context: CallContext, args: Value) -> Result<ToolResult> {
        let args: LocalPathArgs =
            serde_json::from_value(args).context("invalid read_image arguments")?;
        let path = require_local_file(&args.local_path)?;
        let payload = tokio::fs::read(&path)
            .await
            .context("failed to read image file")?;
        let mime_type = detect_image_mime(&payload)
            .ok_or_else(|| anyhow!("File content is not a valid image."))?;
        let sha256 = sha256_file_hex(&path).await?;
        let uploaded = context
            .upload_call_file_path(
                file_name(&path).as_deref().unwrap_or("image"),
                mime_type,
                &path,
            )
            .await?;

        let external_id = uploaded
            .get("file_external_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let text = format!("Image {external_id} attached from {}", path.display());
        let raw = json!({
            "path": path.to_string_lossy(),
            "sha256": sha256,
        });

        Ok(ToolResult {
            text,
            raw,
            media: vec![uploaded],
            artifacts: Vec::new(),
        })
    }

    async fn download_file(&self, context: CallContext, args: Value) -> Result<ToolResult> {
        let args: DownloadFileArgs =
            serde_json::from_value(args).context("invalid download_file arguments")?;
        let file_id = args.file_id.trim().to_string();
        if file_id.is_empty() {
            return Err(anyhow!("file_id is required"));
        }
        let target = expand_path(args.local_path.trim());
        if target.as_os_str().is_empty() {
            return Err(anyhow!("local_path is required"));
        }

        if let Some(parent) = target
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            tokio::fs::create_dir_all(parent)
                .await
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let downloaded = context
            .download_call_file_to_path(&file_id, &target)
            .await?;

        Ok(ToolResult::new(
            format!("File {file_id} downloaded to {}", target.display()),
            json!({
                "file_id": file_id,
                "path": target.to_string_lossy(),
                "size_bytes": downloaded.size_bytes,
                "content_type": downloaded.content_type,
            }),
        ))
    }

    async fn upload_file(&self, context: CallContext, args: Value) -> Result<ToolResult> {
        let args: LocalPathArgs =
            serde_json::from_value(args).context("invalid upload_file arguments")?;
        let path = require_local_file(&args.local_path)?;
        let mime_type = mime_guess::from_path(&path)
            .first_raw()
            .unwrap_or("application/octet-stream");
        let sha256 = sha256_file_hex(&path).await?;
        let uploaded = context
            .upload_call_file_path(
                file_name(&path).as_deref().unwrap_or("file.bin"),
                mime_type,
                &path,
            )
            .await?;
        let external_id = uploaded
            .get("file_external_id")
            .and_then(Value::as_str)
            .unwrap_or_default();

        Ok(ToolResult {
            text: format!("File {external_id} uploaded"),
            raw: json!({
                "path": path.to_string_lossy(),
                "sha256": sha256,
            }),
            media: Vec::new(),
            artifacts: vec![uploaded],
        })
    }
}

#[async_trait]
impl ToolProvider for ShellOutlet {
    fn tools(&self) -> Vec<ToolSpec> {
        vec![
            ToolSpec::new("run_command", SHELL_TOOL_DESCRIPTION, run_command_schema())
                .with_background_support(),
            ToolSpec::new(
                "read_image",
                "Read an image file from the runner filesystem and attach it as media input.",
                read_image_schema(),
            ),
            ToolSpec::new(
                "download_file",
                "Download a chat file referenced by file_id into the runner filesystem.",
                download_file_schema(),
            ),
            ToolSpec::new(
                "upload_file",
                "Upload a runner filesystem file as a user-visible artifact.",
                upload_file_schema(),
            ),
        ]
    }

    fn metadata(&self) -> Map<String, Value> {
        let mut metadata = Map::new();
        metadata.insert("shell_kind".to_string(), json!(self.executor.kind));
        metadata.insert(
            "shell_display".to_string(),
            json!(self.executor.display_name),
        );
        metadata
    }

    async fn call(
        &self,
        function_name: &str,
        arguments: Value,
        context: CallContext,
    ) -> Result<ToolResult> {
        match function_name {
            "run_command" => {
                self.run_command_from_value_with_context(arguments, &context)
                    .await
            }
            "read_image" => self.read_image(context, arguments).await,
            "download_file" => self.download_file(context, arguments).await,
            "upload_file" => self.upload_file(context, arguments).await,
            other => Err(anyhow!("Unknown tool: {other}")),
        }
    }
}

const SHELL_TOOL_DESCRIPTION: &str = "Run a shell command and return stdout/stderr. If `argv` is provided, the command is executed directly (no shell). If `command` is provided, it is executed via the runner shell (non-interactive). Prefer `argv` for portability.";

#[derive(Debug, Deserialize)]
struct RunCommandArgs {
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    env: Option<HashMap<String, Value>>,
    #[serde(default)]
    stdin: Option<String>,
    #[serde(default)]
    timeout_seconds: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct LocalPathArgs {
    local_path: String,
}

#[derive(Debug, Deserialize)]
struct DownloadFileArgs {
    file_id: String,
    local_path: String,
}

fn run_command_schema() -> Value {
    json!({
        "type": "object",
        "description": "Provide either `command` (shell string) or `argv` (array of strings). If both are set, `argv` takes precedence.",
        "properties": {
            "command": {
                "type": "string",
                "description": "Shell command to execute."
            },
            "argv": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Command argv to execute without a shell (argv[0] is program)."
            },
            "cwd": {
                "type": "string",
                "description": "Working directory (optional)."
            },
            "env": {
                "type": "object",
                "description": "Environment variables (optional).",
                "additionalProperties": {"type": "string"}
            },
            "stdin": {
                "type": "string",
                "description": "Standard input (optional)."
            },
            "timeout_seconds": {
                "type": "integer",
                "description": "Command timeout in seconds (optional).",
                "minimum": 0
            }
        },
        "additionalProperties": false
    })
}

fn read_image_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "local_path": {
                "type": "string",
                "description": "Path to the image file on the runner filesystem."
            }
        },
        "required": ["local_path"],
        "additionalProperties": false
    })
}

fn download_file_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "file_id": {
                "type": "string",
                "description": "File external UUID."
            },
            "local_path": {
                "type": "string",
                "description": "Destination path on the runner filesystem."
            }
        },
        "required": ["file_id", "local_path"],
        "additionalProperties": false
    })
}

fn upload_file_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "local_path": {
                "type": "string",
                "description": "Path to the file on the runner filesystem."
            }
        },
        "required": ["local_path"],
        "additionalProperties": false
    })
}

fn detect_shell_executor() -> ShellExecutor {
    if cfg!(windows) {
        if let Some(path) = resolve_executable("pwsh") {
            let display = format!("{} -Command", path.display());
            return ShellExecutor {
                kind: "pwsh".to_string(),
                argv_prefix: vec![
                    path.to_string_lossy().to_string(),
                    "-NoLogo".to_string(),
                    "-NoProfile".to_string(),
                    "-NonInteractive".to_string(),
                    "-Command".to_string(),
                ],
                display_name: display,
            };
        }
        if let Some(path) =
            resolve_executable("powershell").or_else(|| resolve_executable("powershell.exe"))
        {
            let display = format!("{} -Command", path.display());
            return ShellExecutor {
                kind: "powershell".to_string(),
                argv_prefix: vec![
                    path.to_string_lossy().to_string(),
                    "-NoLogo".to_string(),
                    "-NoProfile".to_string(),
                    "-NonInteractive".to_string(),
                    "-ExecutionPolicy".to_string(),
                    "Bypass".to_string(),
                    "-Command".to_string(),
                ],
                display_name: display,
            };
        }

        let comspec = env::var("COMSPEC")
            .ok()
            .and_then(|value| resolve_executable(&value));
        let path = comspec
            .or_else(|| resolve_executable("cmd.exe"))
            .or_else(|| resolve_executable("cmd"))
            .unwrap_or_else(|| PathBuf::from("cmd.exe"));
        let display = format!("{} /c", path.display());
        return ShellExecutor {
            kind: "cmd".to_string(),
            argv_prefix: vec![
                path.to_string_lossy().to_string(),
                "/d".to_string(),
                "/s".to_string(),
                "/c".to_string(),
            ],
            display_name: display,
        };
    }

    if let Ok(shell) = env::var("SHELL") {
        if let Some(path) = resolve_executable(&shell) {
            if let Some(base) = path
                .file_name()
                .and_then(|value| value.to_str())
                .map(str::to_lowercase)
            {
                if POSIX_SHELL_BASENAMES.contains(&base.as_str()) {
                    let display = format!("{} -c", path.display());
                    return ShellExecutor {
                        kind: base,
                        argv_prefix: vec![path.to_string_lossy().to_string(), "-c".to_string()],
                        display_name: display,
                    };
                }
            }
        }
    }

    for candidate in [
        "bash",
        "/bin/bash",
        "/usr/bin/bash",
        "zsh",
        "/bin/zsh",
        "/usr/bin/zsh",
        "sh",
        "/bin/sh",
        "/usr/bin/sh",
    ] {
        if let Some(path) = resolve_executable(candidate) {
            let base = path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("sh")
                .to_lowercase();
            if POSIX_SHELL_BASENAMES.contains(&base.as_str()) {
                let display = format!("{} -c", path.display());
                return ShellExecutor {
                    kind: base,
                    argv_prefix: vec![path.to_string_lossy().to_string(), "-c".to_string()],
                    display_name: display,
                };
            }
        }
    }

    ShellExecutor {
        kind: "sh".to_string(),
        argv_prefix: vec!["/bin/sh".to_string(), "-c".to_string()],
        display_name: "/bin/sh -c".to_string(),
    }
}

fn resolve_executable(candidate: &str) -> Option<PathBuf> {
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return None;
    }
    let path = Path::new(candidate);
    if path.is_absolute() {
        return path.exists().then(|| path.to_path_buf());
    }
    which::which(candidate).ok()
}

fn should_bootstrap_windows_powershell(shell_kind: &str, env: &HashMap<String, String>) -> bool {
    cfg!(windows)
        && matches!(shell_kind, "pwsh" | "powershell")
        && load_bool_from_mapping(env, WINDOWS_FORCE_UTF8_ENV, true)
}

fn wrap_windows_powershell_command(command: &str) -> String {
    format!(
        "$utf8NoBom = [System.Text.UTF8Encoding]::new($false); \
         [Console]::InputEncoding = $utf8NoBom; \
         [Console]::OutputEncoding = $utf8NoBom; \
         $OutputEncoding = $utf8NoBom; \
         try {{ chcp.com 65001 > $null }} catch {{}}; \
         & {{ {command} }}"
    )
}

fn load_bool_from_mapping(env: &HashMap<String, String>, key: &str, default: bool) -> bool {
    match env.get(key).map(|value| value.trim().to_ascii_lowercase()) {
        Some(value) if matches!(value.as_str(), "1" | "true" | "yes" | "y" | "on") => true,
        Some(value) if matches!(value.as_str(), "0" | "false" | "no" | "n" | "off") => false,
        _ => default,
    }
}

fn load_env_usize(key: &str, default: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(default)
}

fn json_value_to_env_string(value: Value) -> String {
    match value {
        Value::String(value) => value,
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

struct AbortTasksGuard {
    handles: Vec<AbortHandle>,
    armed: bool,
}

impl AbortTasksGuard {
    fn new(handles: impl IntoIterator<Item = AbortHandle>) -> Self {
        Self {
            handles: handles.into_iter().collect(),
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for AbortTasksGuard {
    fn drop(&mut self) {
        if self.armed {
            for handle in &self.handles {
                handle.abort();
            }
        }
    }
}

struct ProcessGroupGuard {
    process_group_id: Option<u32>,
    armed: bool,
}

impl ProcessGroupGuard {
    fn new(process_group_id: Option<u32>) -> Self {
        Self {
            process_group_id,
            armed: true,
        }
    }

    fn id(&self) -> Option<u32> {
        self.process_group_id
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ProcessGroupGuard {
    fn drop(&mut self) {
        if self.armed {
            force_kill_process_tree_sync(self.process_group_id);
        }
    }
}

#[derive(Clone, Default)]
struct CapturedOutput {
    bytes: Vec<u8>,
    bytes_total: u64,
    truncated: bool,
}

#[derive(Clone)]
struct PipeCapture {
    state: Arc<StdMutex<CapturedOutput>>,
    max_bytes: usize,
}

impl PipeCapture {
    fn new(max_bytes: usize) -> Self {
        Self {
            state: Arc::new(StdMutex::new(CapturedOutput::default())),
            max_bytes,
        }
    }

    fn push(&self, bytes: &[u8]) {
        if let Ok(mut state) = self.state.lock() {
            state.bytes_total = state.bytes_total.saturating_add(bytes.len() as u64);
            let available = self.max_bytes.saturating_sub(state.bytes.len());
            let retained = bytes.len().min(available);
            state.bytes.extend_from_slice(&bytes[..retained]);
            state.truncated |= retained < bytes.len();
        }
    }

    fn append_notice(&self, notice: &[u8]) {
        if let Ok(mut state) = self.state.lock() {
            let available = self.max_bytes.saturating_sub(state.bytes.len());
            let retained = notice.len().min(available);
            state.bytes.extend_from_slice(&notice[..retained]);
            state.truncated |= retained < notice.len();
        }
    }

    fn snapshot(&self) -> CapturedOutput {
        self.state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default()
    }
}

fn write_stdin(stdin: Option<tokio::process::ChildStdin>, input: String) -> JoinHandle<()> {
    tokio::spawn(async move {
        if let Some(mut stdin) = stdin {
            if !input.is_empty() {
                let _ = stdin.write_all(input.as_bytes()).await;
            }
        }
    })
}

async fn wait_for_command(
    child: &mut Child,
    process_group_id: Option<u32>,
    timeout: Option<Duration>,
    context: Option<&CallContext>,
) -> Result<(std::process::ExitStatus, bool, bool)> {
    enum WaitTrigger {
        Exited(std::io::Result<std::process::ExitStatus>),
        TimedOut,
        Canceled,
    }

    let trigger = if let Some(timeout) = timeout {
        tokio::select! {
            status = child.wait() => WaitTrigger::Exited(status),
            _ = tokio::time::sleep(timeout) => WaitTrigger::TimedOut,
            _ = wait_for_cancellation(context) => WaitTrigger::Canceled,
        }
    } else {
        tokio::select! {
            status = child.wait() => WaitTrigger::Exited(status),
            _ = wait_for_cancellation(context) => WaitTrigger::Canceled,
        }
    };

    match trigger {
        WaitTrigger::Exited(status) => {
            Ok((status.context("failed waiting for command")?, false, false))
        }
        WaitTrigger::TimedOut => {
            let status = terminate_and_wait(child, process_group_id).await?;
            Ok((status, true, false))
        }
        WaitTrigger::Canceled => {
            let status = terminate_and_wait(child, process_group_id).await?;
            Ok((status, false, true))
        }
    }
}

async fn wait_for_cancellation(context: Option<&CallContext>) {
    match context {
        Some(context) => context.cancelled().await,
        None => std::future::pending::<()>().await,
    }
}

async fn terminate_and_wait(
    child: &mut Child,
    process_group_id: Option<u32>,
) -> Result<std::process::ExitStatus> {
    terminate_process_tree(child, process_group_id, TIMEOUT_TERMINATE_GRACE_SECONDS).await;
    match tokio::time::timeout(Duration::from_secs_f64(TIMEOUT_DRAIN_SECONDS), child.wait()).await {
        Ok(Ok(status)) => Ok(status),
        _ => {
            force_kill_process_tree(child, process_group_id).await;
            child
                .wait()
                .await
                .context("failed waiting for killed command")
        }
    }
}

#[derive(Default)]
struct Utf8ProgressDecoder {
    pending: Vec<u8>,
}

impl Utf8ProgressDecoder {
    fn push(&mut self, bytes: &[u8]) -> String {
        self.pending.extend_from_slice(bytes);
        let mut decoded = String::new();

        loop {
            match std::str::from_utf8(&self.pending) {
                Ok(text) => {
                    decoded.push_str(text);
                    self.pending.clear();
                    break;
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    if valid > 0 {
                        decoded.push_str(
                            std::str::from_utf8(&self.pending[..valid])
                                .expect("validated UTF-8 prefix"),
                        );
                        self.pending.drain(..valid);
                    }

                    match error.error_len() {
                        Some(invalid_len) => {
                            decoded.push('\u{fffd}');
                            self.pending.drain(..invalid_len.min(self.pending.len()));
                        }
                        None => break,
                    }
                }
            }
        }

        decoded
    }

    fn finish(&mut self) -> String {
        let decoded = String::from_utf8_lossy(&self.pending).into_owned();
        self.pending.clear();
        decoded
    }
}

fn read_pipe<R>(
    reader: Option<R>,
    context: Option<CallContext>,
    progress_type: &'static str,
    capture: PipeCapture,
) -> JoinHandle<Result<(), std::io::Error>>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut progress_decoder = Utf8ProgressDecoder::default();
        if let Some(mut reader) = reader {
            let mut chunk = vec![0_u8; 8 * 1024];
            loop {
                let read = match reader.read(&mut chunk).await {
                    Ok(read) => read,
                    Err(error) => {
                        capture.append_notice(
                            format!("[error] failed reading {progress_type}: {error}\n").as_bytes(),
                        );
                        return Err(error);
                    }
                };
                if read == 0 {
                    break;
                }
                let bytes = &chunk[..read];
                capture.push(bytes);
                if let Some(context) = &context {
                    context.report_progress(progress_type, progress_decoder.push(bytes));
                }
            }
        }
        if let Some(context) = &context {
            context.report_progress(progress_type, progress_decoder.finish());
        }
        Ok(())
    })
}

#[derive(Default)]
struct DrainOutcome {
    timed_out: bool,
    canceled: bool,
}

async fn finish_stdin(task: &mut JoinHandle<()>) {
    if !task.is_finished() {
        task.abort();
    }
    let _ = task.await;
}

async fn drain_output_tasks(
    stdout_task: &mut JoinHandle<Result<(), std::io::Error>>,
    stderr_task: &mut JoinHandle<Result<(), std::io::Error>>,
    context: Option<&CallContext>,
    drain_timeout: Duration,
) -> DrainOutcome {
    let deadline = tokio::time::sleep(drain_timeout);
    tokio::pin!(deadline);
    let mut stdout_done = false;
    let mut stderr_done = false;
    let mut outcome = DrainOutcome::default();

    while !stdout_done || !stderr_done {
        tokio::select! {
            _ = &mut deadline => {
                outcome.timed_out = true;
                break;
            }
            _ = wait_for_cancellation(context) => {
                outcome.canceled = true;
                break;
            }
            _ = &mut *stdout_task, if !stdout_done => {
                stdout_done = true;
            }
            _ = &mut *stderr_task, if !stderr_done => {
                stderr_done = true;
            }
        }
    }

    if !stdout_done {
        stdout_task.abort();
        let _ = stdout_task.await;
    }
    if !stderr_done {
        stderr_task.abort();
        let _ = stderr_task.await;
    }

    outcome
}

fn configure_process_isolation(command: &mut Command) {
    #[cfg(unix)]
    {
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(CREATE_NEW_PROCESS_GROUP);
    }
}

async fn terminate_process_tree(
    child: &mut Child,
    process_group_id: Option<u32>,
    grace_seconds: f64,
) {
    #[cfg(unix)]
    {
        if let Some(pid) = process_group_id {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGTERM);
            }
            tokio::time::sleep(Duration::from_secs_f64(grace_seconds.max(0.1))).await;
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }

    #[cfg(windows)]
    {
        if let Some(pid) = process_group_id {
            let _ = Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T"])
                .status()
                .await;
            tokio::time::sleep(Duration::from_secs_f64(grace_seconds.max(0.1))).await;
            let _ = Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T", "/F"])
                .status()
                .await;
        }
    }

    if child.try_wait().ok().flatten().is_none() {
        let _ = child.start_kill();
    }
}

async fn force_kill_process_tree(child: &mut Child, process_group_id: Option<u32>) {
    #[cfg(unix)]
    {
        if let Some(pid) = process_group_id {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
    #[cfg(windows)]
    {
        if let Some(pid) = process_group_id {
            let _ = Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T", "/F"])
                .status()
                .await;
        }
    }
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.start_kill();
    }
}

fn force_kill_process_tree_sync(process_group_id: Option<u32>) {
    #[cfg(unix)]
    if let Some(pid) = process_group_id {
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
    }

    #[cfg(windows)]
    if let Some(pid) = process_group_id {
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .status();
    }
}

fn decode_utf8_output(payload: &[u8]) -> (String, bool) {
    match String::from_utf8(payload.to_vec()) {
        Ok(value) => (value, false),
        Err(error) => (String::from_utf8_lossy(error.as_bytes()).into_owned(), true),
    }
}

fn truncate_text(text: &str, max_chars: usize) -> (String, bool) {
    if text.chars().count() <= max_chars {
        return (text.to_string(), false);
    }
    if max_chars == 0 {
        return (String::new(), true);
    }
    if max_chars <= 3 {
        return (text.chars().take(max_chars).collect(), true);
    }
    let mut truncated = text.chars().take(max_chars - 3).collect::<String>();
    truncated.push_str("...");
    (truncated, true)
}

fn append_command_timeout_notice(text: &str, timeout_seconds: Option<u64>) -> String {
    let notice = command_timeout_notice(timeout_seconds);
    let text = text.trim();
    if text.is_empty() {
        notice
    } else {
        format!("{text}\n\n{notice}")
    }
}

fn command_timeout_notice(timeout_seconds: Option<u64>) -> String {
    if let Some(seconds) = timeout_seconds.filter(|seconds| *seconds > 0) {
        let unit = if seconds == 1 { "second" } else { "seconds" };
        format!("[timeout] Command exceeded timeout of {seconds} {unit}.")
    } else {
        "[timeout] Command exceeded timeout.".to_string()
    }
}

fn expand_path(path: &str) -> PathBuf {
    PathBuf::from(shellexpand::tilde(path).into_owned())
}

fn require_local_file(path: &str) -> Result<PathBuf> {
    let path = expand_path(path.trim());
    if path.as_os_str().is_empty() {
        return Err(anyhow!("local_path is required"));
    }
    if !path.exists() {
        return Err(anyhow!("File not found: {}", path.display()));
    }
    if !path.is_file() {
        return Err(anyhow!("Not a file: {}", path.display()));
    }
    Ok(path)
}

fn file_name(path: &Path) -> Option<String> {
    path.file_name()
        .map(OsString::from)
        .map(|value| value.to_string_lossy().to_string())
}

async fn sha256_file_hex(path: &Path) -> Result<String> {
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("failed to open {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];

    loop {
        let read = file
            .read(&mut buffer)
            .await
            .with_context(|| format!("failed to read {}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }

    Ok(hex::encode(hasher.finalize()))
}

fn detect_image_mime(payload: &[u8]) -> Option<&'static str> {
    if payload.is_empty() {
        return None;
    }

    if let Ok(format) = image::guess_format(payload) {
        if image::load_from_memory(payload).is_err() {
            return None;
        }
        return match format {
            image::ImageFormat::Png => Some("image/png"),
            image::ImageFormat::Jpeg => Some("image/jpeg"),
            image::ImageFormat::Gif => Some("image/gif"),
            image::ImageFormat::WebP => Some("image/webp"),
            image::ImageFormat::Bmp => Some("image/bmp"),
            _ => None,
        };
    }

    sniff_image_mime(payload)
}

fn sniff_image_mime(payload: &[u8]) -> Option<&'static str> {
    if payload.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if payload.starts_with(b"\xff\xd8\xff") {
        return Some("image/jpeg");
    }
    if payload.starts_with(b"GIF87a") || payload.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if payload.len() >= 12 && payload.starts_with(b"RIFF") && &payload[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if payload.starts_with(b"BM") {
        return Some("image/bmp");
    }
    None
}

fn shlex_join(argv: &[String]) -> String {
    argv.iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(arg: &str) -> String {
    if arg.is_empty() {
        return "''".to_string();
    }
    if arg.chars().all(|ch| {
        ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | '/' | ':' | '=' | '+')
    }) {
        return arg.to_string();
    }
    format!("'{}'", arg.replace('\'', "'\"'\"'"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use outlet_core::{BackgroundPool, BackgroundStatus};

    #[tokio::test]
    async fn run_command_executes_argv_without_shell_metadata() {
        let outlet = ShellOutlet::new();
        let result = outlet
            .run_command_from_value(json!({
                "argv": ["sh", "-c", "printf direct"]
            }))
            .await
            .unwrap();

        assert_eq!(result.text, "direct");
        assert_eq!(result.raw["shell_kind"], "");
        assert_eq!(result.raw["exit_code"], 0);
    }

    #[tokio::test]
    async fn run_command_reports_utf8_decode_errors() {
        let outlet = ShellOutlet::new();
        let result = outlet
            .run_command_from_value(json!({
                "argv": ["sh", "-c", "printf '\\377hello'"]
            }))
            .await
            .unwrap();

        assert!(result.raw["stdout"]
            .as_str()
            .unwrap_or_default()
            .contains('\u{fffd}'));
        assert_eq!(result.raw["stdout_decode_error"], true);
    }

    #[tokio::test]
    async fn run_command_times_out() {
        let outlet = ShellOutlet::new();
        let result = outlet
            .run_command_from_value(json!({
                "argv": ["sh", "-c", "sleep 3"],
                "timeout_seconds": 1
            }))
            .await
            .unwrap();

        assert_eq!(result.raw["timed_out"], true);
        assert!(result.text.contains("[timeout]"));
    }

    #[tokio::test]
    async fn background_run_command_streams_stdout_and_completes() {
        let provider = std::sync::Arc::new(ShellOutlet::new());
        let pool = BackgroundPool::with_default_client(
            provider,
            "http://server",
            "token",
            1,
            Duration::from_secs(60),
        );
        pool.start_background(
            "shell-progress",
            "run_command",
            json!({"argv": ["sh", "-c", "printf first; sleep 0.1; printf second"]}),
            None,
        )
        .await
        .unwrap();

        let completed =
            wait_for_shell_background_status(&pool, "shell-progress", BackgroundStatus::Completed)
                .await;
        let stdout = completed.raw["progress"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["type"] == "stdout")
            .filter_map(|entry| entry["text"].as_str())
            .collect::<String>();
        assert_eq!(stdout, "firstsecond");
        assert_eq!(completed.raw["result"]["raw"]["exit_code"], 0);
        assert_eq!(completed.raw["result"]["text"], "firstsecond");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn background_cancel_terminates_shell_process_tree() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let pid_path = env::temp_dir().join(format!(
            "outlet-shell-background-pid-{}-{suffix}",
            std::process::id()
        ));
        let command = format!(
            "echo $$ > {}; sleep 30",
            shell_quote(&pid_path.to_string_lossy())
        );
        let provider = std::sync::Arc::new(ShellOutlet::new());
        let pool = BackgroundPool::with_default_client(
            provider,
            "http://server",
            "token",
            1,
            Duration::from_secs(60),
        );
        pool.start_background(
            "shell-cancel",
            "run_command",
            json!({"argv": ["sh", "-c", command]}),
            None,
        )
        .await
        .unwrap();

        let pid = wait_for_pid_file(&pid_path).await;
        let canceled = pool.cancel_background("shell-cancel", "0").await.unwrap();
        assert_eq!(canceled.raw["status"], "running");
        wait_for_shell_background_status(&pool, "shell-cancel", BackgroundStatus::Canceled).await;

        let mut gone = false;
        for _ in 0..100 {
            let result = unsafe { libc::kill(pid, 0) };
            if result == -1 {
                gone = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let _ = tokio::fs::remove_file(&pid_path).await;
        assert!(gone, "canceled shell process {pid} is still running");
    }

    #[test]
    fn pipe_capture_retains_a_bounded_prefix_and_counts_all_bytes() {
        let capture = PipeCapture::new(4);
        capture.push(b"abcdefghij");
        let snapshot = capture.snapshot();
        assert_eq!(snapshot.bytes, b"abcd");
        assert_eq!(snapshot.bytes_total, 10);
        assert!(snapshot.truncated);
    }

    #[tokio::test]
    async fn drain_timeout_aborts_and_awaits_pipe_readers() {
        let (mut stdout_writer, stdout_reader) = tokio::io::duplex(64);
        let (mut stderr_writer, stderr_reader) = tokio::io::duplex(64);
        let stdout_capture = PipeCapture::new(64);
        let stderr_capture = PipeCapture::new(64);
        let mut stdout_task =
            read_pipe(Some(stdout_reader), None, "stdout", stdout_capture.clone());
        let mut stderr_task =
            read_pipe(Some(stderr_reader), None, "stderr", stderr_capture.clone());
        stdout_writer.write_all(b"partial stdout").await.unwrap();
        stderr_writer.write_all(b"partial stderr").await.unwrap();

        let outcome = drain_output_tasks(
            &mut stdout_task,
            &mut stderr_task,
            None,
            Duration::from_millis(20),
        )
        .await;
        assert!(outcome.timed_out);
        assert!(stdout_task.is_finished());
        assert!(stderr_task.is_finished());
        assert_eq!(stdout_capture.snapshot().bytes, b"partial stdout");
        assert_eq!(stderr_capture.snapshot().bytes, b"partial stderr");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancel_kills_descendant_after_shell_leader_exits() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let pid_path = env::temp_dir().join(format!(
            "outlet-shell-descendant-pid-{}-{suffix}",
            std::process::id()
        ));
        let command = format!(
            "sleep 30 & echo $! > {}; exit 0",
            shell_quote(&pid_path.to_string_lossy())
        );
        let provider = Arc::new(ShellOutlet::new());
        let pool = BackgroundPool::with_default_client(
            provider,
            "http://server",
            "token",
            1,
            Duration::from_secs(60),
        );
        pool.start_background(
            "shell-descendant-cancel",
            "run_command",
            json!({"argv": ["sh", "-c", command]}),
            None,
        )
        .await
        .unwrap();

        let pid = wait_for_pid_file(&pid_path).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        let cancel = pool
            .cancel_background("shell-descendant-cancel", "0")
            .await
            .unwrap();
        assert_eq!(cancel.raw["status"], "running");
        wait_for_shell_background_status(
            &pool,
            "shell-descendant-cancel",
            BackgroundStatus::Canceled,
        )
        .await;
        assert_process_gone(pid).await;
        let _ = tokio::fs::remove_file(&pid_path).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn aborting_command_future_kills_the_process_group() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let pid_path = env::temp_dir().join(format!(
            "outlet-shell-abort-pid-{}-{suffix}",
            std::process::id()
        ));
        let command = format!(
            "echo $$ > {}; sleep 30",
            shell_quote(&pid_path.to_string_lossy())
        );
        let outlet = ShellOutlet::new();
        let execution = tokio::spawn(async move {
            outlet
                .run_command_from_value(json!({"argv": ["sh", "-c", command]}))
                .await
        });

        let pid = wait_for_pid_file(&pid_path).await;
        execution.abort();
        let _ = execution.await;
        assert_process_gone(pid).await;
        let _ = tokio::fs::remove_file(&pid_path).await;
    }

    async fn wait_for_shell_background_status(
        pool: &BackgroundPool<ShellOutlet>,
        task_id: &str,
        expected: BackgroundStatus,
    ) -> ToolResult {
        for _ in 0..200 {
            let result = pool.background_status(task_id, "0").await.unwrap();
            let status: BackgroundStatus =
                serde_json::from_value(result.raw["status"].clone()).unwrap();
            if status == expected {
                return result;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("shell background task did not reach {expected:?}");
    }

    #[cfg(unix)]
    async fn wait_for_pid_file(path: &Path) -> i32 {
        for _ in 0..200 {
            if let Ok(value) = tokio::fs::read_to_string(path).await {
                if let Ok(pid) = value.trim().parse::<i32>() {
                    return pid;
                }
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("background command did not write its pid file");
    }

    #[cfg(unix)]
    async fn assert_process_gone(pid: i32) {
        for _ in 0..100 {
            if unsafe { libc::kill(pid, 0) } == -1 {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("shell process {pid} is still running");
    }

    #[test]
    fn schemas_keep_expected_required_fields() {
        assert_eq!(read_image_schema()["required"][0], "local_path");
        assert_eq!(download_file_schema()["required"][0], "file_id");
        assert_eq!(upload_file_schema()["additionalProperties"], false);
    }

    #[test]
    fn image_sniffer_accepts_png_signature() {
        let payload = b"\x89PNG\r\n\x1a\nrest";
        assert_eq!(sniff_image_mime(payload), Some("image/png"));
    }

    #[test]
    fn image_detector_rejects_html_payload() {
        assert_eq!(detect_image_mime(b"<html>404</html>"), None);
    }

    #[test]
    fn timeout_notice_matches_python_text() {
        assert_eq!(
            command_timeout_notice(Some(1)),
            "[timeout] Command exceeded timeout of 1 second."
        );
        assert_eq!(
            command_timeout_notice(Some(2)),
            "[timeout] Command exceeded timeout of 2 seconds."
        );
    }

    #[test]
    fn truncation_appends_ellipsis() {
        assert_eq!(truncate_text("abcdef", 5), ("ab...".to_string(), true));
        assert_eq!(truncate_text("abc", 5), ("abc".to_string(), false));
    }

    #[test]
    fn progress_decoder_preserves_utf8_split_across_chunks() {
        let mut decoder = Utf8ProgressDecoder::default();
        let bytes = "before-🙂-after".as_bytes();
        let split = "before-".len() + 2;
        let first = decoder.push(&bytes[..split]);
        let second = decoder.push(&bytes[split..]);
        let finished = decoder.finish();
        assert_eq!(first + &second + &finished, "before-🙂-after");
    }

    #[test]
    fn bool_env_mapping_accepts_common_values() {
        let mut env = HashMap::new();
        env.insert("X".to_string(), "off".to_string());
        assert!(!load_bool_from_mapping(&env, "X", true));
        env.insert("X".to_string(), "yes".to_string());
        assert!(load_bool_from_mapping(&env, "X", false));
    }

    #[test]
    fn shell_quote_handles_spaces() {
        assert_eq!(shlex_join(&["hello world".to_string()]), "'hello world'");
    }

    #[tokio::test]
    async fn sha256_file_hex_is_stable() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = env::temp_dir().join(format!(
            "outlet-shell-sha256-{}-{suffix}.txt",
            std::process::id()
        ));
        tokio::fs::write(&path, b"hello").await.unwrap();

        assert_eq!(
            sha256_file_hex(&path).await.unwrap(),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );

        let _ = tokio::fs::remove_file(path).await;
    }

    #[test]
    fn provider_lists_current_tools() {
        let tools = ShellOutlet::new().tools();
        let names = tools
            .iter()
            .map(|tool| tool.name.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            ["run_command", "read_image", "download_file", "upload_file"]
        );
        assert!(
            tools
                .iter()
                .find(|tool| tool.name == "run_command")
                .unwrap()
                .supports_background
        );
        assert!(tools
            .iter()
            .filter(|tool| tool.name != "run_command")
            .all(|tool| !tool.supports_background));
    }
}
