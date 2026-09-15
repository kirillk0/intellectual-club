use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use async_trait::async_trait;
use bollard::container::{DownloadFromContainerOptions, LogOutput, UploadToContainerOptions};
use bollard::exec::{CreateExecOptions, StartExecOptions, StartExecResults};
use futures_util::StreamExt;
use outlet_core::{
    CallContext, ExecutionOutcomeUnknown as UnconfirmedExecution, ToolProvider, ToolResult,
    ToolSpec,
};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::io::ReaderStream;

use crate::manager::{ContainerLease, ContainerManager};

const OUTPUT_BYTES: usize = 200_000;
const FILE_OPERATION_TIMEOUT: Duration = Duration::from_secs(600);

pub struct ContainerOutlet {
    manager: Arc<ContainerManager>,
    default_timeout: Duration,
    max_file_bytes: u64,
}

impl ContainerOutlet {
    pub fn new(
        manager: Arc<ContainerManager>,
        default_timeout: Duration,
        max_file_bytes: u64,
    ) -> Result<Self> {
        if default_timeout.is_zero() || max_file_bytes == 0 {
            bail!("Command timeout and file transfer safety limit must be positive");
        }
        Ok(Self {
            manager,
            default_timeout,
            max_file_bytes,
        })
    }

    async fn execute(
        &self,
        lease: &ContainerLease,
        args: RunCommandArgs,
        context: &CallContext,
    ) -> Result<ToolResult> {
        let mut env = args.env.clone();
        let mut secrets = Vec::new();
        for name in &args.use_secrets {
            validate_env_key(name)?;
            let value = tokio::select! {
                result = tokio::time::timeout(Duration::from_secs(30), context.fetch_call_secret(name)) =>
                    result.context("Managed secret fetch timed out before command execution")??,
                _ = context.cancelled() => bail!("Call canceled before command execution"),
            };
            if !value.is_empty() {
                secrets.push(value.clone());
            }
            env.insert(name.clone(), value);
        }
        let command = args.command_argv()?;
        let cwd = normalize_path(args.cwd.as_deref().unwrap_or("/workspace"), true)?;
        let seconds = args
            .timeout_seconds
            .unwrap_or(self.default_timeout.as_secs());
        if seconds == 0 {
            bail!("timeout_seconds must be positive");
        }
        let mut stdout = Capture::new(&secrets);
        let mut stderr = Capture::new(&secrets);
        let mut stdin_error = None;
        let run = async {
            let exec = self
                .manager
                .docker()
                .create_exec(
                    &lease.container_id,
                    CreateExecOptions {
                        attach_stdin: Some(true),
                        attach_stdout: Some(true),
                        attach_stderr: Some(true),
                        tty: Some(false),
                        cmd: Some(command),
                        working_dir: Some(cwd),
                        env: Some(
                            env.into_iter()
                                .map(|(key, value)| format!("{key}={value}"))
                                .collect(),
                        ),
                        ..Default::default()
                    },
                )
                .await?;
            let StartExecResults::Attached {
                mut output,
                mut input,
            } = self
                .manager
                .docker()
                .start_exec(
                    &exec.id,
                    Some(StartExecOptions {
                        output_capacity: Some(8192),
                        ..Default::default()
                    }),
                )
                .await?
            else {
                bail!("Docker exec unexpectedly detached");
            };
            // Write stdin and drain both outputs concurrently to avoid pipe deadlocks.
            let write = async {
                if let Some(stdin) = &args.stdin {
                    input.write_all(stdin.as_bytes()).await?;
                }
                input.shutdown().await?;
                Ok::<_, anyhow::Error>(())
            };
            let read = async {
                while let Some(chunk) = output.next().await {
                    match chunk? {
                        LogOutput::StdErr { message } => {
                            stderr.push(&message, context, "stderr", secrets.is_empty())
                        }
                        LogOutput::StdOut { message } | LogOutput::Console { message } => {
                            stdout.push(&message, context, "stdout", secrets.is_empty())
                        }
                        LogOutput::StdIn { .. } => {}
                    }
                }
                Ok::<_, anyhow::Error>(())
            };
            // A process may close stdin early; still drain and collect its exit code.
            let (input_result, output_result) = tokio::join!(write, read);
            stdin_error = input_result
                .err()
                .map(|error| redact(&format!("{error:#}"), &secrets));
            output_result?;
            let status = self.manager.docker().inspect_exec(&exec.id).await?;
            if status.running == Some(true) {
                bail!("Docker exec stream ended while the command is still running");
            }
            status.exit_code.ok_or_else(|| {
                anyhow!("Docker returned no exit status; execution outcome is unknown")
            })
        };
        let outcome = tokio::select! {
            result = tokio::time::timeout(Duration::from_secs(seconds), run) => {
                match result {
                    Ok(Ok(code)) => CommandOutcome::Exited(code),
                    Ok(Err(error)) => CommandOutcome::Failed(redact(&format!("{error:#}"), &secrets)),
                    Err(_) => CommandOutcome::TimedOut,
                }
            }
            _ = context.cancelled() => CommandOutcome::Canceled,
        };
        let reset = !matches!(outcome, CommandOutcome::Exited(_));
        if reset {
            let reason = match &outcome {
                CommandOutcome::TimedOut => "command_timeout",
                CommandOutcome::Canceled => "command_canceled",
                _ => "command_outcome_unknown",
            };
            // Disconnecting exec does not kill its process tree. Destroy the whole workspace.
            self.manager.destroy(lease, reason).await.map_err(|error| anyhow!(UnconfirmedExecution(format!(
                "Cannot confirm emergency container removal; execution outcome is unknown. Administrator intervention may be required: {error:#}"
            ))))?;
        }
        let (out, out_truncated) = stdout.finish(&secrets);
        let (err, err_truncated) = stderr.finish(&secrets);
        let code = match outcome {
            CommandOutcome::Exited(code) => Some(code),
            _ => None,
        };
        let error = match &outcome {
            CommandOutcome::Failed(error) => Some(error.as_str()),
            _ => None,
        };
        let raw = json!({
            "stdout": out, "stderr": err, "exit_code": code,
            "timed_out": matches!(outcome, CommandOutcome::TimedOut),
            "canceled": matches!(outcome, CommandOutcome::Canceled),
            "output_truncated": out_truncated || err_truncated,
            "container_destroyed": reset, "error": error, "stdin_error": stdin_error,
        });
        let mut text = format!(
            "exit_code: {}\nstdout:\n{out}\nstderr:\n{err}",
            code.map(|v| v.to_string())
                .unwrap_or_else(|| "unknown".to_string())
        );
        if reset {
            text.push_str("\nWARNING: Command interrupted or outcome unknown; the entire shared task container was destroyed to stop all processes. Files and concurrent work are lost. The next call creates a fresh container.");
        }
        if let Some(error) = error {
            text.push_str(&format!("\nError: {error}"));
        }
        if let Some(error) = stdin_error {
            text.push_str(&format!(
                "\nWarning: stdin may not have been fully delivered: {error}"
            ));
        }
        if out_truncated || err_truncated {
            text.push_str("\nOutput truncated.");
        }
        Ok(ToolResult::new(text, raw))
    }

    async fn download_file(
        &self,
        lease: &ContainerLease,
        args: DownloadFileArgs,
        context: &CallContext,
    ) -> Result<ToolResult> {
        let path = normalize_path(&args.local_path, false)?;
        let (parent, name) = split_file_path(&path)?;
        let temp = TempDir::new().context("Cannot create private file transfer directory")?;
        let source = temp.path().join("source");
        let metadata = context
            .download_call_file_to_path_limited(&args.file_id, &source, self.max_file_bytes)
            .await?;
        let mkdir = self
            .execute(
                lease,
                RunCommandArgs {
                    argv: Some(vec![
                        "mkdir".into(),
                        "-p".into(),
                        "--".into(),
                        parent.clone(),
                    ]),
                    ..Default::default()
                },
                context,
            )
            .await?;
        if mkdir.raw.get("exit_code").and_then(Value::as_i64) != Some(0) {
            bail!("Cannot create destination directory: {}", mkdir.text);
        }
        let archive_path = temp.path().join("archive.tar");
        let target = archive_path.clone();
        tokio::task::spawn_blocking(move || make_archive(&source, &target, &name)).await??;
        let archive = tokio::fs::File::open(&archive_path).await?;
        let read_error = Arc::new(Mutex::new(None));
        let stream_error = read_error.clone();
        let stream = ReaderStream::new(archive).filter_map(move |item| {
            let value = match item {
                Ok(bytes) => Some(bytes),
                Err(error) => {
                    *stream_error.lock().unwrap() = Some(error);
                    None
                }
            };
            std::future::ready(value)
        });
        self.manager
            .docker()
            .upload_to_container_streaming(
                &lease.container_id,
                Some(UploadToContainerOptions {
                    path: parent,
                    no_overwrite_dir_non_dir: "true".to_string(),
                }),
                stream,
            )
            .await?;
        if let Some(error) = read_error.lock().unwrap().take() {
            return Err(error.into());
        }
        Ok(ToolResult::new(
            format!("File {} downloaded to {path}", args.file_id),
            json!({
                "file_id": args.file_id, "path": path, "size_bytes": metadata.size_bytes,
                "content_type": metadata.content_type,
            }),
        ))
    }

    async fn upload_file(
        &self,
        lease: &ContainerLease,
        args: LocalPathArgs,
        context: &CallContext,
        media: bool,
    ) -> Result<ToolResult> {
        let path = normalize_path(&args.local_path, false)?;
        let (_, filename) = split_file_path(&path)?;
        let temp = TempDir::new().context("Cannot create private file transfer directory")?;
        let archive_path = temp.path().join("archive.tar");
        let mut archive = tokio::fs::File::create(&archive_path).await?;
        let mut stream = self.manager.docker().download_from_container(
            &lease.container_id,
            Some(DownloadFromContainerOptions { path: path.clone() }),
        );
        let mut received = 0u64;
        // Bound tar overhead too, so requesting a directory cannot fill the runner disk.
        let archive_limit = self.max_file_bytes.saturating_add(1024 * 1024);
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            received = received.saturating_add(chunk.len() as u64);
            if received > archive_limit {
                bail!(
                    "File exceeds the transfer safety limit ({} bytes)",
                    self.max_file_bytes
                );
            }
            archive.write_all(&chunk).await?;
        }
        archive.flush().await?;
        drop(archive);
        let output_path = temp.path().join("file");
        let target = output_path.clone();
        let limit = self.max_file_bytes;
        let (size, sha256) = tokio::task::spawn_blocking(move || {
            read_single_file_archive(&archive_path, &target, limit)
        })
        .await??;
        let mime_type = if media {
            let mut input = tokio::fs::File::open(&output_path).await?;
            let mut header = vec![0u8; 8192];
            let n = input.read(&mut header).await?;
            image_mime(&header[..n])?.to_string()
        } else {
            mime_guess::from_path(&filename)
                .first_raw()
                .unwrap_or("application/octet-stream")
                .to_string()
        };
        let uploaded = context
            .upload_call_file_path(&filename, &mime_type, &output_path)
            .await?;
        let external_id = uploaded
            .get("file_external_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut result = ToolResult::new(
            format!(
                "{} {external_id} attached from {path}",
                if media { "Image" } else { "File" }
            ),
            json!({
                "path": path, "sha256": sha256, "size_bytes": size,
            }),
        );
        if media {
            result.media.push(uploaded);
        } else {
            result.artifacts.push(uploaded);
        }
        Ok(result)
    }
}

#[async_trait]
impl ToolProvider for ContainerOutlet {
    fn tools(&self) -> Vec<ToolSpec> {
        let path_schema = json!({"type": "object", "properties": {
            "local_path": {"type": "string", "description": "File path inside the task container. Relative paths start at /workspace; host paths are never accessible."}
        }, "required": ["local_path"], "additionalProperties": false});
        let mut download_schema = path_schema.clone();
        download_schema["properties"]["file_id"] =
            json!({"type": "string", "description": "Chat file external UUID."});
        download_schema["required"] = json!(["file_id", "local_path"]);
        vec![
            ToolSpec::new("run_command", "Run a command in the Linux container shared by this chat and its subagents. Files persist between calls until eviction or failure. argv takes precedence over command (/bin/sh -c). Default cwd: /workspace. Use the background wrapper for long cancellable work; stopping foreground chat generation does not cancel a dispatched exec. Timeout/background cancel destroys the ENTIRE shared container, including concurrent work. Inspect workspace generation and reset warnings in every result. Never automatically retry a command with unknown outcome.", json!({
                "type": "object", "properties": {
                    "command": {"type": "string"},
                    "argv": {"type": "array", "items": {"type": "string"}, "minItems": 1},
                    "cwd": {"type": "string"},
                    "env": {"type": "object", "additionalProperties": {"type": "string"}},
                    "stdin": {"type": "string"},
                    "timeout_seconds": {"type": "integer", "minimum": 1, "description": format!("Command timeout; default {} seconds. Timeout destroys the shared workspace.", self.default_timeout.as_secs())},
                    "use_secrets": {"type": "array", "items": {"type": "string"}, "description": "Managed secret names to inject into this exec only. Raw progress is suppressed and exact values are redacted from the final output."}
                }, "additionalProperties": false
            })).with_background_support(),
            ToolSpec::new("download_file", "Download a chat attachment into the task container; create parent directories as needed.", download_schema),
            ToolSpec::new("upload_file", "Upload a regular file from the task container as a user-visible artifact. Archive directories yourself first; symlinks are not followed.", path_schema.clone()),
            ToolSpec::new("read_image", "Read an image from the task container and attach it as media input.", path_schema),
        ]
    }

    fn metadata(&self) -> Map<String, Value> {
        Map::from_iter([
            ("runner_kind".to_string(), json!("task-container")),
            ("workspace_directory".to_string(), json!("/workspace")),
        ])
    }

    async fn call(
        &self,
        function_name: &str,
        arguments: Value,
        context: CallContext,
    ) -> Result<ToolResult> {
        // Parse before allocation and never accept routing ids from model-controlled arguments.
        let request = Request::parse(function_name, arguments)?;
        let routing = context.execution_context().ok_or_else(|| anyhow!("Server did not provide execution context; upgrade the server. No container was selected."))?;
        let root = routing
            .root_chat_id
            .filter(|id| *id > 0)
            .ok_or_else(|| anyhow!("Server did not provide a valid root_chat_id"))?;
        let user = routing
            .user_id
            .filter(|id| *id > 0)
            .ok_or_else(|| anyhow!("Server did not provide a valid user_id"))?;
        if context.is_cancelled() {
            bail!("Call canceled before container allocation");
        }
        let mut lease = self.manager.acquire(root, user).await?;
        if context.is_cancelled() {
            lease.finish_without_notice()?;
            bail!("Call canceled before command execution");
        }
        let workspace = json!({"root_chat_id": root, "container_id": lease.container_id,
            "generation": lease.generation, "recreated": lease.recreated, "reset_reason": lease.reset_reason});
        let notice = if lease.recreated {
            format!("WARNING: The previous task container was lost ({}) and a new one was created (generation {}). Previous files/processes are gone.\n", lease.reset_reason.as_deref().unwrap_or("container_missing"), lease.generation)
        } else {
            String::new()
        };
        if !notice.is_empty() {
            context.report_progress("workspace", &notice);
        }
        let result = match request {
            Request::Run(args) => self.execute(&lease, args, &context).await,
            other => {
                let operation = async {
                    match other {
                        Request::Download(args) => self.download_file(&lease, args, &context).await,
                        Request::Upload(args) => {
                            self.upload_file(&lease, args, &context, false).await
                        }
                        Request::Image(args) => {
                            self.upload_file(&lease, args, &context, true).await
                        }
                        Request::Run(_) => unreachable!(),
                    }
                };
                let completed = tokio::select! {
                    value = tokio::time::timeout(FILE_OPERATION_TIMEOUT, operation) => value.ok(),
                    _ = context.cancelled() => None,
                };
                match completed {
                    Some(result) => result,
                    None => match self.manager.destroy(&lease, "file_transfer_interrupted").await {
                        Ok(()) => Err(anyhow!("File transfer interrupted; the task container was destroyed. The next call creates a fresh workspace.")),
                        Err(error) => Err(anyhow!(UnconfirmedExecution(format!("File transfer interrupted; cannot confirm container removal: {error:#}")))),
                    }
                }
            }
        };
        // Only a completed operation may clear its durable busy marker. A dropped future
        // or unconfirmed emergency stop leaves deletion intent for recovery.
        if result
            .as_ref()
            .err()
            .is_none_or(|error| error.downcast_ref::<UnconfirmedExecution>().is_none())
        {
            lease.finish()?;
        }
        match result {
            Ok(mut result) => {
                result.text = format!(
                    "{notice}{}\nWorkspace generation: {}",
                    result.text, lease.generation
                );
                result.raw["workspace"] = workspace;
                Ok(result)
            }
            Err(error) => {
                let message = format!(
                    "{notice}{error:#}\nWorkspace generation: {}",
                    lease.generation
                );
                // Keep typed unknown-outcome errors available to the background pool.
                Err(error.context(message))
            }
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RunCommandArgs {
    command: Option<String>,
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    #[serde(default)]
    env: HashMap<String, String>,
    #[serde(default)]
    use_secrets: Vec<String>,
    stdin: Option<String>,
    timeout_seconds: Option<u64>,
}
impl RunCommandArgs {
    fn command_argv(&self) -> Result<Vec<String>> {
        if let Some(argv) = &self.argv {
            if argv.is_empty() || argv[0].is_empty() || argv.iter().any(|s| s.contains('\0')) {
                bail!("argv must contain an executable and no NUL characters");
            }
            Ok(argv.clone())
        } else if let Some(command) = self
            .command
            .as_ref()
            .filter(|s| !s.trim().is_empty() && !s.contains('\0'))
        {
            Ok(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                command.clone(),
            ])
        } else {
            bail!("command or argv is required");
        }
    }
    fn validate(&self) -> Result<()> {
        self.command_argv()?;
        if self.timeout_seconds == Some(0) {
            bail!("timeout_seconds must be positive");
        }
        normalize_path(self.cwd.as_deref().unwrap_or("/workspace"), true)?;
        for (name, value) in &self.env {
            validate_env_key(name)?;
            if value.contains('\0') {
                bail!("Environment values must not contain NUL characters");
            }
        }
        for name in &self.use_secrets {
            validate_env_key(name)?;
        }
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalPathArgs {
    #[serde(alias = "container_path")]
    local_path: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DownloadFileArgs {
    file_id: String,
    #[serde(alias = "container_path")]
    local_path: String,
}
enum Request {
    Run(RunCommandArgs),
    Download(DownloadFileArgs),
    Upload(LocalPathArgs),
    Image(LocalPathArgs),
}
impl Request {
    fn parse(name: &str, args: Value) -> Result<Self> {
        match name {
            "run_command" => {
                let args: RunCommandArgs = serde_json::from_value(args)?;
                args.validate()?;
                Ok(Self::Run(args))
            }
            "download_file" => {
                let args: DownloadFileArgs = serde_json::from_value(args)?;
                uuid::Uuid::parse_str(&args.file_id).context("file_id must be a UUID")?;
                normalize_path(&args.local_path, false)?;
                Ok(Self::Download(args))
            }
            "upload_file" | "read_image" => {
                let args: LocalPathArgs = serde_json::from_value(args)?;
                normalize_path(&args.local_path, false)?;
                Ok(if name == "upload_file" {
                    Self::Upload(args)
                } else {
                    Self::Image(args)
                })
            }
            _ => bail!("Unknown container tool: {name}"),
        }
    }
}
enum CommandOutcome {
    Exited(i64),
    TimedOut,
    Canceled,
    Failed(String),
}

fn validate_env_key(name: &str) -> Result<()> {
    if name.is_empty() || name.contains(['=', '\0']) {
        bail!("Invalid environment variable name");
    }
    Ok(())
}
fn normalize_path(path: &str, directory: bool) -> Result<String> {
    if path.is_empty() || path.contains('\0') {
        bail!("A non-empty container path without NUL characters is required");
    }
    if !directory && path.ends_with('/') {
        bail!("Expected a file path, not a directory");
    }
    let full = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/workspace/{path}")
    };
    let mut components = Vec::new();
    for part in full.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if components.pop().is_none() {
                    bail!("Path escapes the container root");
                }
            }
            _ => components.push(part),
        }
    }
    if !directory && components.is_empty() {
        bail!("Expected a regular file path");
    }
    Ok(format!("/{}", components.join("/")))
}
fn split_file_path(path: &str) -> Result<(String, String)> {
    let (parent, name) = path
        .rsplit_once('/')
        .ok_or_else(|| anyhow!("Expected absolute container path"))?;
    if name.is_empty() {
        bail!("Expected file name");
    }
    Ok((
        if parent.is_empty() {
            "/".to_string()
        } else {
            parent.to_string()
        },
        name.to_string(),
    ))
}
fn make_archive(source: &Path, target: &Path, name: &str) -> Result<()> {
    let mut input = std::fs::File::open(source)?;
    let mut builder = tar::Builder::new(std::fs::File::create(target)?);
    let mut header = tar::Header::new_gnu();
    header.set_size(input.metadata()?.len());
    header.set_mode(0o644);
    header.set_entry_type(tar::EntryType::Regular);
    header.set_cksum();
    builder.append_data(&mut header, name, &mut input)?;
    builder.finish()?;
    Ok(())
}
fn read_single_file_archive(archive: &Path, target: &Path, limit: u64) -> Result<(u64, String)> {
    let mut archive = tar::Archive::new(std::fs::File::open(archive)?);
    let mut result = None;
    for entry in archive.entries()? {
        let mut entry = entry?;
        if !entry.header().entry_type().is_file() || result.is_some() {
            bail!("Only a single regular file is supported; archive directories yourself and do not use symlinks");
        }
        if entry.size() > limit {
            bail!("File exceeds the transfer safety limit ({limit} bytes)");
        }
        // Never unpack or join an archive-supplied path with a host path.
        let mut output = std::fs::File::create(target)?;
        let mut hash = Sha256::new();
        let mut size = 0u64;
        let mut buf = [0u8; 65536];
        loop {
            let n = entry.read(&mut buf)?;
            if n == 0 {
                break;
            }
            size += n as u64;
            if size > limit {
                bail!("File exceeds the transfer safety limit ({limit} bytes)");
            }
            output.write_all(&buf[..n])?;
            hash.update(&buf[..n]);
        }
        output.flush()?;
        result = Some((size, format!("{:x}", hash.finalize())));
    }
    result.ok_or_else(|| anyhow!("Docker returned an empty file archive"))
}
fn image_mime(header: &[u8]) -> Result<&'static str> {
    Ok(
        match image::guess_format(header).context("File is not a supported image")? {
            image::ImageFormat::Png => "image/png",
            image::ImageFormat::Jpeg => "image/jpeg",
            image::ImageFormat::Gif => "image/gif",
            image::ImageFormat::WebP => "image/webp",
            _ => bail!("Use PNG, JPEG, GIF, or WebP for image input"),
        },
    )
}
fn redact(value: &str, secrets: &[String]) -> String {
    let mut ordered = secrets.iter().filter(|s| !s.is_empty()).collect::<Vec<_>>();
    ordered.sort_by_key(|s| std::cmp::Reverse(s.len()));
    ordered.into_iter().fold(value.to_string(), |text, secret| {
        text.replace(secret, "[REDACTED]")
    })
}
struct Capture {
    bytes: Vec<u8>,
    limit: usize,
    observed: usize,
}
impl Capture {
    fn new(secrets: &[String]) -> Self {
        Self {
            bytes: Vec::new(),
            limit: OUTPUT_BYTES.saturating_add(secrets.iter().map(String::len).max().unwrap_or(0)),
            observed: 0,
        }
    }
    fn push(&mut self, bytes: &[u8], context: &CallContext, kind: &str, progress: bool) {
        self.observed = self.observed.saturating_add(bytes.len());
        let count = bytes.len().min(self.limit.saturating_sub(self.bytes.len()));
        self.bytes.extend_from_slice(&bytes[..count]);
        if progress {
            context.report_progress(kind, String::from_utf8_lossy(bytes));
        }
    }
    fn finish(self, secrets: &[String]) -> (String, bool) {
        let mut text = redact(&String::from_utf8_lossy(&self.bytes), secrets);
        let truncated = self.observed > OUTPUT_BYTES;
        if text.len() > OUTPUT_BYTES {
            let mut end = OUTPUT_BYTES;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            text.truncate(end);
        }
        (text, truncated)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths_are_container_paths_on_every_host_platform() {
        assert_eq!(
            normalize_path("reports/a.pdf", false).unwrap(),
            "/workspace/reports/a.pdf"
        );
        assert_eq!(normalize_path("/tmp/a/../b", false).unwrap(), "/tmp/b");
        assert!(normalize_path("/../host", false).is_err());
        assert!(normalize_path("/", false).is_err());
        assert!(normalize_path("", false).is_err());
        assert!(normalize_path("a\0b", false).is_err());
    }
    #[test]
    fn reject_model_routing_overrides_before_creating_container() {
        assert!(
            Request::parse("run_command", json!({"command":"true", "root_chat_id": 2})).is_err()
        );
        assert!(Request::parse("run_command", json!({"argv": []})).is_err());
        assert!(Request::parse(
            "run_command",
            json!({"command":"true", "timeout_seconds": 0})
        )
        .is_err());
        assert!(Request::parse(
            "download_file",
            json!({"file_id":"../secrets", "local_path":"a"})
        )
        .is_err());
    }
    #[test]
    fn argv_preserves_empty_arguments_and_takes_precedence() {
        let args: RunCommandArgs =
            serde_json::from_value(json!({"command":"false", "argv":["printf", "", "x"]})).unwrap();
        assert_eq!(args.command_argv().unwrap(), vec!["printf", "", "x"]);
    }
    #[test]
    fn archive_roundtrip_is_binary_safe_and_size_bounded() {
        let dir = TempDir::new().unwrap();
        let input = dir.path().join("in");
        let archive = dir.path().join("tar");
        let output = dir.path().join("out");
        std::fs::write(&input, b"\0binary\xff").unwrap();
        make_archive(&input, &archive, "document.pdf").unwrap();
        let (size, _) = read_single_file_archive(&archive, &output, 100).unwrap();
        assert_eq!(size, 8);
        assert_eq!(std::fs::read(output).unwrap(), b"\0binary\xff");
        assert!(read_single_file_archive(&archive, &dir.path().join("small"), 1).is_err());
    }
    #[test]
    fn archive_symlinks_are_never_followed() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tar");
        let mut builder = tar::Builder::new(std::fs::File::create(&path).unwrap());
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(tar::EntryType::Symlink);
        header.set_size(0);
        header.set_mode(0o777);
        builder
            .append_link(&mut header, "x", "/etc/passwd")
            .unwrap();
        builder.finish().unwrap();
        drop(builder);
        assert!(read_single_file_archive(&path, &dir.path().join("out"), 1024).is_err());
        assert!(!dir.path().join("out").exists());
    }
    #[test]
    fn redact_secrets_before_truncating_output() {
        let secrets = vec!["secret-value".to_string()];
        let mut capture = Capture::new(&secrets);
        capture.bytes = vec![b'x'; OUTPUT_BYTES - 3];
        capture.bytes.extend_from_slice(b"secret-value");
        capture.observed = capture.bytes.len();
        let (text, truncated) = capture.finish(&secrets);
        assert!(truncated);
        assert!(!text.contains("sec"));
        assert_eq!(
            redact(
                "long-secret short",
                &["secret".into(), "long-secret".into()]
            ),
            "[REDACTED] short"
        );
    }
}
