use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use bytes::Bytes;
use reqwest::header::CONTENT_TYPE;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use tokio::fs::File as TokioFile;
use tokio::io::AsyncWriteExt;
use tokio::sync::{broadcast, Mutex, Semaphore};
use tokio::task::JoinHandle;
use tokio_util::io::ReaderStream;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

pub const DISCOVERY_FUNCTION: &str = "outlet.list_tools";
const BACKGROUND_PROGRESS_MAX_CHARS: usize = 400_000;
const BACKGROUND_PROGRESS_ENTRY_MAX_CHARS: usize = 12_000;
const BACKGROUND_SHUTDOWN_GRACE_SECONDS: u64 = 10;
const DEFAULT_BACKGROUND_TERMINAL_TTL_SECONDS: u64 = 86_400;
const BACKGROUND_PROGRESS_TRUNCATION_MESSAGE: &str =
    "Background progress truncated because the in-memory limit was reached.";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
    #[serde(default)]
    pub supports_background: bool,
}

impl ToolSpec {
    pub fn new(
        name: impl Into<String>,
        description: impl Into<String>,
        input_schema: Value,
    ) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            input_schema,
            supports_background: false,
        }
    }

    pub fn with_background_support(mut self) -> Self {
        self.supports_background = true;
        self
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ToolResult {
    pub text: String,
    pub raw: Value,
    pub media: Vec<Value>,
    pub artifacts: Vec<Value>,
}

impl ToolResult {
    pub fn new(text: impl Into<String>, raw: Value) -> Self {
        Self {
            text: text.into(),
            raw,
            media: Vec::new(),
            artifacts: Vec::new(),
        }
    }

    pub fn from_raw(raw: Value) -> Self {
        let text = serde_json::to_string(&raw).unwrap_or_else(|_| String::new());
        Self::new(text, raw)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BackgroundProgress {
    #[serde(rename = "type")]
    pub progress_type: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BackgroundError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BackgroundStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Canceled,
}

impl BackgroundStatus {
    fn terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Canceled)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BackgroundTaskSnapshot {
    pub background_task_id: String,
    pub status: BackgroundStatus,
    pub progress: Vec<BackgroundProgress>,
    pub next_cursor: String,
    pub progress_truncated: bool,
    pub progress_chars_total: u64,
    pub result: Option<ToolResult>,
    pub error: Option<BackgroundError>,
}

#[derive(Default)]
struct ProgressLogState {
    entries: Vec<BackgroundProgress>,
    chars_stored: usize,
    chars_total: u64,
    truncated: bool,
}

#[derive(Clone)]
struct ProgressLog {
    state: Arc<StdMutex<ProgressLogState>>,
    max_chars: usize,
}

impl Default for ProgressLog {
    fn default() -> Self {
        Self {
            state: Arc::new(StdMutex::new(ProgressLogState::default())),
            max_chars: BACKGROUND_PROGRESS_MAX_CHARS,
        }
    }
}

impl ProgressLog {
    fn push(&self, mut entry: BackgroundProgress) {
        if entry.text.is_empty() {
            return;
        }
        if let Ok(mut state) = self.state.lock() {
            let text_chars = entry.text.chars().count();
            state.chars_total = state.chars_total.saturating_add(text_chars as u64);
            if state.truncated {
                return;
            }

            let marker_chars = BACKGROUND_PROGRESS_TRUNCATION_MESSAGE.chars().count();
            let content_limit = self.max_chars.saturating_sub(marker_chars);
            let available = content_limit.saturating_sub(state.chars_stored);
            if text_chars <= available {
                state.chars_stored += text_chars;
                push_progress_chunks(&mut state.entries, entry);
                return;
            }

            if available > 0 {
                entry.text = entry.text.chars().take(available).collect();
                state.chars_stored += entry.text.chars().count();
                push_progress_chunks(&mut state.entries, entry);
            }

            state.truncated = true;
            if marker_chars <= self.max_chars.saturating_sub(state.chars_stored) {
                push_progress_chunks(
                    &mut state.entries,
                    BackgroundProgress {
                        progress_type: "system".to_string(),
                        text: BACKGROUND_PROGRESS_TRUNCATION_MESSAGE.to_string(),
                        mode: Some("truncated".to_string()),
                        cursor: None,
                    },
                );
                state.chars_stored += marker_chars;
            }
        }
    }

    fn read_from(&self, cursor: usize) -> Result<(Vec<BackgroundProgress>, usize, bool, u64)> {
        match self.state.lock() {
            Ok(state) => {
                let next_cursor = state.entries.len();
                if cursor > next_cursor {
                    return Err(anyhow!(
                        "background progress cursor {cursor} is ahead of {next_cursor}"
                    ));
                }
                Ok((
                    state.entries[cursor..].to_vec(),
                    next_cursor,
                    state.truncated,
                    state.chars_total,
                ))
            }
            Err(_) => Err(anyhow!("background progress log is unavailable")),
        }
    }
}

fn push_progress_chunks(entries: &mut Vec<BackgroundProgress>, entry: BackgroundProgress) {
    let mut chars = entry.text.chars();
    let mut first = true;

    loop {
        let text: String = chars
            .by_ref()
            .take(BACKGROUND_PROGRESS_ENTRY_MAX_CHARS)
            .collect();
        if text.is_empty() {
            break;
        }

        let mode = if first || entry.mode.as_deref() != Some("replace") {
            entry.mode.clone()
        } else {
            Some("append".to_string())
        };

        entries.push(BackgroundProgress {
            progress_type: entry.progress_type.clone(),
            text,
            mode,
            cursor: None,
        });
        first = false;
    }
}

#[derive(Clone)]
pub struct CallContext {
    client: reqwest::Client,
    server_url: Arc<str>,
    token: Arc<str>,
    call_id: Arc<str>,
    progress: Option<ProgressLog>,
    cancellation: CancellationToken,
}

impl CallContext {
    pub fn new(
        client: reqwest::Client,
        server_url: impl Into<Arc<str>>,
        token: impl Into<Arc<str>>,
        call_id: impl Into<Arc<str>>,
    ) -> Self {
        Self {
            client,
            server_url: server_url.into(),
            token: token.into(),
            call_id: call_id.into(),
            progress: None,
            cancellation: CancellationToken::new(),
        }
    }

    fn for_background(
        client: reqwest::Client,
        server_url: impl Into<Arc<str>>,
        token: impl Into<Arc<str>>,
        background_task_id: impl Into<Arc<str>>,
        progress: ProgressLog,
        cancellation: CancellationToken,
    ) -> Self {
        Self {
            client,
            server_url: server_url.into(),
            token: token.into(),
            call_id: background_task_id.into(),
            progress: Some(progress),
            cancellation,
        }
    }

    pub fn call_id(&self) -> &str {
        &self.call_id
    }

    pub fn server_url(&self) -> &str {
        &self.server_url
    }

    pub fn report_progress(&self, progress_type: impl Into<String>, text: impl Into<String>) {
        self.report_progress_with_mode(progress_type, text, None);
    }

    pub fn report_progress_with_mode(
        &self,
        progress_type: impl Into<String>,
        text: impl Into<String>,
        mode: Option<String>,
    ) {
        if let Some(progress) = &self.progress {
            progress.push(BackgroundProgress {
                progress_type: progress_type.into(),
                text: text.into(),
                mode,
                cursor: None,
            });
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancellation.is_cancelled()
    }

    pub async fn cancelled(&self) {
        self.cancellation.cancelled().await;
    }

    pub async fn upload_call_file(
        &self,
        filename: &str,
        mime_type: &str,
        payload: Vec<u8>,
    ) -> Result<Value> {
        self.upload_call_file_body(filename, mime_type, reqwest::Body::from(payload))
            .await
    }

    pub async fn upload_call_file_path(
        &self,
        filename: &str,
        mime_type: &str,
        path: impl AsRef<Path>,
    ) -> Result<Value> {
        let file = TokioFile::open(path.as_ref())
            .await
            .with_context(|| format!("failed to open {}", path.as_ref().display()))?;
        let stream = ReaderStream::new(file);

        self.upload_call_file_body(filename, mime_type, reqwest::Body::wrap_stream(stream))
            .await
    }

    async fn upload_call_file_body(
        &self,
        filename: &str,
        mime_type: &str,
        body: reqwest::Body,
    ) -> Result<Value> {
        let url = join_url(
            &self.server_url,
            &format!("/api/outlet/calls/{}/files", self.call_id),
        );

        let mut request = self
            .client
            .post(url)
            .bearer_auth(self.token.as_ref())
            .header(
                CONTENT_TYPE,
                if mime_type.trim().is_empty() {
                    "application/octet-stream"
                } else {
                    mime_type
                },
            )
            .query(&[("filename", filename)])
            .body(body);

        if filename.is_ascii() {
            request = request.header("X-Filename", filename);
        }

        let response = request
            .send()
            .await
            .context("failed to upload outlet call file")?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(anyhow!("file upload failed: HTTP {status}: {body}"));
        }

        let payload: Value =
            serde_json::from_str(&body).context("invalid file upload JSON response")?;
        payload
            .get("file")
            .cloned()
            .filter(Value::is_object)
            .ok_or_else(|| anyhow!("outlet file upload response is invalid"))
    }

    pub async fn download_call_file_to_path(
        &self,
        file_id: &str,
        path: impl AsRef<Path>,
    ) -> Result<DownloadedCallFileMetadata> {
        let url = join_url(
            &self.server_url,
            &format!("/api/outlet/calls/{}/files/{}", self.call_id, file_id),
        );

        let mut response = self
            .client
            .get(url)
            .bearer_auth(self.token.as_ref())
            .send()
            .await
            .context("failed to download outlet call file")?;

        let status = response.status();
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();
        let content_disposition = response
            .headers()
            .get("content-disposition")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
            .to_string();

        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("file download failed: HTTP {status}: {body}"));
        }

        let mut file = TokioFile::create(path.as_ref())
            .await
            .with_context(|| format!("failed to create {}", path.as_ref().display()))?;
        let mut size_bytes = 0_u64;

        while let Some(chunk) = response
            .chunk()
            .await
            .context("failed to read outlet file body")?
        {
            size_bytes += chunk.len() as u64;
            file.write_all(&chunk)
                .await
                .with_context(|| format!("failed to write {}", path.as_ref().display()))?;
        }

        file.flush()
            .await
            .with_context(|| format!("failed to flush {}", path.as_ref().display()))?;

        Ok(DownloadedCallFileMetadata {
            size_bytes,
            content_type,
            content_disposition,
        })
    }

    pub async fn download_call_file(&self, file_id: &str) -> Result<DownloadedCallFile> {
        let url = join_url(
            &self.server_url,
            &format!("/api/outlet/calls/{}/files/{}", self.call_id, file_id),
        );

        let response = self
            .client
            .get(url)
            .bearer_auth(self.token.as_ref())
            .send()
            .await
            .context("failed to download outlet call file")?;

        let status = response.status();
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();
        let content_disposition = response
            .headers()
            .get("content-disposition")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
            .to_string();
        let payload = response
            .bytes()
            .await
            .context("failed to read outlet file body")?;

        if !status.is_success() {
            return Err(anyhow!("file download failed: HTTP {status}"));
        }

        Ok(DownloadedCallFile {
            payload,
            content_type,
            content_disposition,
        })
    }
}

#[derive(Debug)]
pub struct DownloadedCallFileMetadata {
    pub size_bytes: u64,
    pub content_type: String,
    pub content_disposition: String,
}

#[derive(Debug)]
pub struct DownloadedCallFile {
    pub payload: Bytes,
    pub content_type: String,
    pub content_disposition: String,
}

#[async_trait]
pub trait ToolProvider: Send + Sync + 'static {
    fn tools(&self) -> Vec<ToolSpec>;

    fn metadata(&self) -> Map<String, Value> {
        Map::new()
    }

    async fn call(
        &self,
        function_name: &str,
        arguments: Value,
        context: CallContext,
    ) -> Result<ToolResult>;
}

#[derive(Clone, Debug)]
pub struct RunnerConfig {
    pub server_url: String,
    pub token: String,
    pub runner_id: String,
    pub max_concurrency: usize,
    pub background_control_capacity: usize,
    pub poll_max_wait_seconds: f64,
    pub complete_max_retries: usize,
    pub complete_max_seconds: f64,
    pub background_terminal_ttl_seconds: f64,
    pub poll_endpoint: String,
    pub complete_endpoint: String,
    pub metadata: Map<String, Value>,
}

impl RunnerConfig {
    pub fn new(server_url: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            server_url: server_url.into().trim().trim_end_matches('/').to_string(),
            token: token.into().trim().to_string(),
            runner_id: Uuid::new_v4().simple().to_string(),
            max_concurrency: 20,
            background_control_capacity: 4,
            poll_max_wait_seconds: 25.0,
            complete_max_retries: 100,
            complete_max_seconds: 300.0,
            background_terminal_ttl_seconds: 86_400.0,
            poll_endpoint: "/api/outlet/poll/".to_string(),
            complete_endpoint: "/api/outlet/complete/".to_string(),
            metadata: base_runner_metadata(),
        }
    }
}

#[derive(Clone, Debug)]
pub enum RunnerEvent {
    Connected,
    Disconnected {
        reason: String,
    },
    CallStarted {
        call_id: String,
        function_name: String,
    },
    CallFinished {
        call_id: String,
        function_name: String,
        status: String,
        duration_ms: u128,
        error_text: String,
    },
    Stopped {
        reason: String,
    },
}

#[derive(Debug, Deserialize)]
struct PollResponse {
    #[serde(default)]
    status: String,
    #[serde(default)]
    tasks: Vec<PollTask>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum PollOperation {
    #[default]
    Execute,
    BackgroundStart,
    BackgroundStatus,
    BackgroundCancel,
}

#[derive(Clone, Debug, Deserialize)]
struct PollTask {
    call_id: String,
    #[serde(rename = "function")]
    function_name: String,
    #[serde(default)]
    arguments: Value,
    #[serde(default)]
    operation: PollOperation,
    #[serde(default)]
    background_task_id: String,
    #[serde(default, deserialize_with = "deserialize_optional_cursor")]
    cursor: Option<String>,
}

fn deserialize_optional_cursor<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum CursorValue {
        String(String),
        Integer(u64),
    }

    Ok(
        Option::<CursorValue>::deserialize(deserializer)?.map(|value| match value {
            CursorValue::String(value) => value,
            CursorValue::Integer(value) => value.to_string(),
        }),
    )
}

#[derive(Debug, Serialize)]
struct CompletePayload<'a> {
    runner_id: &'a str,
    runner_session_id: &'a str,
    call_id: &'a str,
    status: &'a str,
    result_text: &'a str,
    result_raw: &'a Value,
    result_media: &'a [Value],
    result_artifacts: &'a [Value],
    error_text: &'a str,
    metadata: &'a Map<String, Value>,
}

struct BackgroundRequest {
    function_name: String,
    arguments: Value,
    fingerprint: [u8; 32],
}

struct BackgroundTaskState {
    request: Option<BackgroundRequest>,
    status: BackgroundStatus,
    progress: ProgressLog,
    cancellation: CancellationToken,
    cancel_requested: bool,
    result: Option<ToolResult>,
    error: Option<BackgroundError>,
    finished_at: Option<Instant>,
    job: Option<JoinHandle<()>>,
}

#[derive(Clone, Copy)]
struct ExpiredBackgroundTask {
    fingerprint: Option<[u8; 32]>,
}

struct BackgroundPoolInner<P: ToolProvider> {
    provider: Arc<P>,
    client: reqwest::Client,
    server_url: Arc<str>,
    token: Arc<str>,
    semaphore: Arc<Semaphore>,
    tasks: Mutex<HashMap<String, BackgroundTaskState>>,
    expired_tasks: StdMutex<HashMap<String, ExpiredBackgroundTask>>,
    terminal_ttl: Duration,
    shutting_down: AtomicBool,
}

pub struct BackgroundPool<P: ToolProvider> {
    inner: Arc<BackgroundPoolInner<P>>,
}

impl<P: ToolProvider> Clone for BackgroundPool<P> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<P: ToolProvider> BackgroundPool<P> {
    pub fn tools(&self) -> Vec<ToolSpec> {
        self.inner.provider.tools()
    }

    pub async fn running_background_count(&self) -> usize {
        self.inner
            .tasks
            .lock()
            .await
            .values()
            .filter(|task| task.status == BackgroundStatus::Running)
            .count()
    }

    pub fn with_default_client(
        provider: Arc<P>,
        server_url: impl Into<Arc<str>>,
        token: impl Into<Arc<str>>,
        max_concurrency: usize,
        terminal_ttl: Duration,
    ) -> Self {
        Self::new(
            provider,
            reqwest::Client::new(),
            server_url,
            token,
            max_concurrency,
            terminal_ttl,
        )
    }

    pub fn new(
        provider: Arc<P>,
        client: reqwest::Client,
        server_url: impl Into<Arc<str>>,
        token: impl Into<Arc<str>>,
        max_concurrency: usize,
        terminal_ttl: Duration,
    ) -> Self {
        let terminal_ttl = if terminal_ttl.is_zero() {
            Duration::from_secs(DEFAULT_BACKGROUND_TERMINAL_TTL_SECONDS)
        } else {
            terminal_ttl
        };
        Self {
            inner: Arc::new(BackgroundPoolInner {
                provider,
                client,
                server_url: server_url.into(),
                token: token.into(),
                semaphore: Arc::new(Semaphore::new(max_concurrency.max(1))),
                tasks: Mutex::new(HashMap::new()),
                expired_tasks: StdMutex::new(HashMap::new()),
                terminal_ttl,
                shutting_down: AtomicBool::new(false),
            }),
        }
    }

    pub async fn call_foreground(
        &self,
        function_name: &str,
        arguments: Value,
        context: CallContext,
    ) -> Result<ToolResult> {
        let _permit = Arc::clone(&self.inner.semaphore)
            .acquire_owned()
            .await
            .map_err(|_| anyhow!("background execution pool is closed"))?;
        self.inner
            .provider
            .call(function_name, arguments, context)
            .await
    }

    pub async fn start_background(
        &self,
        background_task_id: &str,
        function_name: &str,
        arguments: Value,
        cursor: Option<&str>,
    ) -> Result<ToolResult> {
        let background_task_id = background_task_id.trim();
        let function_name = function_name.trim();
        if background_task_id.is_empty() {
            return Err(anyhow!("background_task_id is required"));
        }
        if function_name.is_empty() {
            return Err(anyhow!("background function is required"));
        }

        self.cleanup_expired().await;
        let cursor = parse_cursor(cursor)?;
        let request_fingerprint = background_request_fingerprint(function_name, &arguments)?;

        {
            let tasks = self.inner.tasks.lock().await;
            if let Some(existing) = tasks.get(background_task_id) {
                if let Some(request) = &existing.request {
                    ensure_matching_background_request(
                        background_task_id,
                        request,
                        function_name,
                        &arguments,
                    )?;
                    return snapshot_result(background_task_id, existing, cursor);
                }
            }
            if self.ensure_expired_background_request(
                background_task_id,
                request_fingerprint,
                false,
            )? {
                return Err(expired_background_error(background_task_id));
            }
        }

        let supports_background = self
            .inner
            .provider
            .tools()
            .into_iter()
            .any(|tool| tool.name == function_name && tool.supports_background);
        if !supports_background {
            return Err(anyhow!(
                "tool function {function_name} does not support background execution"
            ));
        }

        let progress = ProgressLog::default();
        let cancellation = CancellationToken::new();
        let mut tasks = self.inner.tasks.lock().await;
        if let Some(existing) = tasks.get_mut(background_task_id) {
            if let Some(request) = &existing.request {
                ensure_matching_background_request(
                    background_task_id,
                    request,
                    function_name,
                    &arguments,
                )?;
            } else {
                existing.request = Some(BackgroundRequest {
                    function_name: function_name.to_string(),
                    arguments,
                    fingerprint: request_fingerprint,
                });
            }
            return snapshot_result(background_task_id, existing, cursor);
        }

        if self.ensure_expired_background_request(background_task_id, request_fingerprint, true)? {
            return Err(expired_background_error(background_task_id));
        }

        if self.inner.shutting_down.load(Ordering::Acquire) {
            return Err(anyhow!("background execution pool is shutting down"));
        }

        tasks.insert(
            background_task_id.to_string(),
            BackgroundTaskState {
                request: Some(BackgroundRequest {
                    function_name: function_name.to_string(),
                    arguments,
                    fingerprint: request_fingerprint,
                }),
                status: BackgroundStatus::Queued,
                progress,
                cancellation,
                cancel_requested: false,
                result: None,
                error: None,
                finished_at: None,
                job: None,
            },
        );

        let pool = self.clone();
        let task_id = background_task_id.to_string();
        let job = tokio::spawn(async move {
            pool.run_background(task_id).await;
        });
        if let Some(task) = tasks.get_mut(background_task_id) {
            task.job = Some(job);
        } else {
            job.abort();
            return Err(anyhow!(
                "background task disappeared before execution: {background_task_id}"
            ));
        }
        let snapshot = snapshot_result(background_task_id, &tasks[background_task_id], cursor);
        drop(tasks);
        snapshot
    }

    pub async fn background_status(
        &self,
        background_task_id: &str,
        cursor: &str,
    ) -> Result<ToolResult> {
        self.cleanup_expired().await;
        let cursor = parse_cursor(Some(cursor))?;
        let tasks = self.inner.tasks.lock().await;
        let task = match tasks.get(background_task_id.trim()) {
            Some(task) => task,
            None if self.is_expired_background(background_task_id.trim()) => {
                return Err(expired_background_error(background_task_id.trim()));
            }
            None => {
                return Err(anyhow!(
                    "background task not found: {}",
                    background_task_id.trim()
                ));
            }
        };
        snapshot_result(background_task_id.trim(), task, cursor)
    }

    pub async fn cancel_background(
        &self,
        background_task_id: &str,
        cursor: &str,
    ) -> Result<ToolResult> {
        let background_task_id = background_task_id.trim();
        if background_task_id.is_empty() {
            return Err(anyhow!("background_task_id is required"));
        }

        self.cleanup_expired().await;
        let cursor = parse_cursor(Some(cursor))?;
        let mut tasks = self.inner.tasks.lock().await;
        if !tasks.contains_key(background_task_id) && self.is_expired_background(background_task_id)
        {
            return Err(expired_background_error(background_task_id));
        }
        let task = tasks
            .entry(background_task_id.to_string())
            .or_insert_with(canceled_background_tombstone);

        match task.status {
            BackgroundStatus::Queued => {
                task.cancel_requested = true;
                task.cancellation.cancel();
                mark_background_canceled(task);
            }
            BackgroundStatus::Running => {
                task.cancel_requested = true;
                task.cancellation.cancel();
            }
            BackgroundStatus::Completed | BackgroundStatus::Failed | BackgroundStatus::Canceled => {
            }
        }

        snapshot_result(background_task_id, task, cursor)
    }

    pub async fn shutdown(&self) {
        if self.inner.shutting_down.swap(true, Ordering::AcqRel) {
            return;
        }

        let jobs = {
            let mut tasks = self.inner.tasks.lock().await;
            let mut jobs = Vec::new();
            for task in tasks.values_mut() {
                if !task.status.terminal() {
                    task.cancel_requested = true;
                    task.cancellation.cancel();
                    if task.status == BackgroundStatus::Queued {
                        mark_background_canceled(task);
                    }
                }
                if let Some(job) = task.job.take() {
                    jobs.push(job);
                }
            }
            jobs
        };

        let deadline =
            tokio::time::Instant::now() + Duration::from_secs(BACKGROUND_SHUTDOWN_GRACE_SECONDS);
        while jobs.iter().any(|job| !job.is_finished()) && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        for job in &jobs {
            if !job.is_finished() {
                job.abort();
            }
        }
        for job in jobs {
            let _ = job.await;
        }

        let mut tasks = self.inner.tasks.lock().await;
        for task in tasks.values_mut() {
            if !task.status.terminal() && task.cancel_requested {
                mark_background_canceled(task);
            }
        }
    }

    async fn run_background(&self, background_task_id: String) {
        let (function_name, arguments, progress, cancellation) = {
            let tasks = self.inner.tasks.lock().await;
            let Some(task) = tasks.get(&background_task_id) else {
                return;
            };
            let Some(request) = &task.request else {
                return;
            };
            (
                request.function_name.clone(),
                request.arguments.clone(),
                task.progress.clone(),
                task.cancellation.clone(),
            )
        };

        let permit = tokio::select! {
            permit = Arc::clone(&self.inner.semaphore).acquire_owned() => {
                match permit {
                    Ok(permit) => permit,
                    Err(_) => {
                        self.fail_background(&background_task_id, "pool_closed", "Background execution pool is closed.").await;
                        return;
                    }
                }
            }
            _ = cancellation.cancelled() => return,
        };

        {
            let mut tasks = self.inner.tasks.lock().await;
            let Some(task) = tasks.get_mut(&background_task_id) else {
                return;
            };
            if task.status == BackgroundStatus::Canceled {
                return;
            }
            task.status = BackgroundStatus::Running;
        }

        let context = CallContext::for_background(
            self.inner.client.clone(),
            Arc::clone(&self.inner.server_url),
            Arc::clone(&self.inner.token),
            Arc::<str>::from(background_task_id.clone()),
            progress,
            cancellation.clone(),
        );
        let result = self
            .inner
            .provider
            .call(&function_name, arguments, context)
            .await;
        let mut tasks = self.inner.tasks.lock().await;
        let Some(task) = tasks.get_mut(&background_task_id) else {
            return;
        };
        task.finished_at = Some(Instant::now());
        if task.cancel_requested || cancellation.is_cancelled() {
            mark_background_canceled(task);
            drop(permit);
            return;
        }
        match result {
            Ok(result) => {
                task.status = BackgroundStatus::Completed;
                task.result = Some(result);
                task.error = None;
            }
            Err(error) => {
                task.status = BackgroundStatus::Failed;
                task.result = None;
                task.error = Some(BackgroundError {
                    code: "execution_failed".to_string(),
                    message: error.to_string(),
                    outcome: Some("failed".to_string()),
                });
            }
        }
        drop(permit);
    }

    async fn fail_background(&self, background_task_id: &str, code: &str, message: &str) {
        let mut tasks = self.inner.tasks.lock().await;
        if let Some(task) = tasks.get_mut(background_task_id) {
            if task.status == BackgroundStatus::Canceled {
                return;
            }
            task.status = BackgroundStatus::Failed;
            task.result = None;
            task.error = Some(BackgroundError {
                code: code.to_string(),
                message: message.to_string(),
                outcome: Some("failed".to_string()),
            });
            task.finished_at = Some(Instant::now());
        }
    }

    async fn cleanup_expired(&self) {
        let now = Instant::now();
        let terminal_ttl = self.inner.terminal_ttl;
        let mut tasks = self.inner.tasks.lock().await;
        let Ok(mut expired_tasks) = self.inner.expired_tasks.lock() else {
            return;
        };
        tasks.retain(|background_task_id, task| {
            let keep = !task.status.terminal()
                || task
                    .finished_at
                    .is_none_or(|finished_at| now.duration_since(finished_at) < terminal_ttl);
            if !keep {
                expired_tasks
                    .entry(background_task_id.clone())
                    .or_insert(ExpiredBackgroundTask {
                        fingerprint: task.request.as_ref().map(|request| request.fingerprint),
                    });
            }
            keep
        });
    }

    fn ensure_expired_background_request(
        &self,
        background_task_id: &str,
        fingerprint: [u8; 32],
        bind_unbound: bool,
    ) -> Result<bool> {
        let mut expired_tasks = self
            .inner
            .expired_tasks
            .lock()
            .map_err(|_| anyhow!("background idempotency registry is unavailable"))?;
        let Some(expired) = expired_tasks.get_mut(background_task_id) else {
            return Ok(false);
        };
        match expired.fingerprint {
            Some(existing) if existing != fingerprint => Err(anyhow!(
                "background task {background_task_id} already exists with a different function or arguments"
            )),
            Some(_) => Ok(true),
            None if bind_unbound => {
                expired.fingerprint = Some(fingerprint);
                Ok(true)
            }
            None => Ok(false),
        }
    }

    fn is_expired_background(&self, background_task_id: &str) -> bool {
        self.inner
            .expired_tasks
            .lock()
            .map(|tasks| tasks.contains_key(background_task_id))
            .unwrap_or(true)
    }
}

fn background_request_fingerprint(function_name: &str, arguments: &Value) -> Result<[u8; 32]> {
    let payload = serde_json::to_vec(&(function_name, arguments))
        .context("failed to serialize background request for idempotency")?;
    Ok(Sha256::digest(payload).into())
}

fn expired_background_error(background_task_id: &str) -> anyhow::Error {
    anyhow!(
        "outlet_task_expired: background task {background_task_id} expired and cannot be restarted in this runner session"
    )
}

fn ensure_matching_background_request(
    background_task_id: &str,
    request: &BackgroundRequest,
    function_name: &str,
    arguments: &Value,
) -> Result<()> {
    if request.function_name == function_name && request.arguments == *arguments {
        Ok(())
    } else {
        Err(anyhow!(
            "background task {background_task_id} already exists with a different function or arguments"
        ))
    }
}

fn canceled_background_tombstone() -> BackgroundTaskState {
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let mut task = BackgroundTaskState {
        request: None,
        status: BackgroundStatus::Canceled,
        progress: ProgressLog::default(),
        cancellation,
        cancel_requested: true,
        result: None,
        error: None,
        finished_at: None,
        job: None,
    };
    mark_background_canceled(&mut task);
    task
}

fn mark_background_canceled(task: &mut BackgroundTaskState) {
    task.status = BackgroundStatus::Canceled;
    task.result = None;
    task.error = Some(BackgroundError {
        code: "canceled".to_string(),
        message: "Background task was canceled.".to_string(),
        outcome: Some("canceled".to_string()),
    });
    task.finished_at = Some(Instant::now());
}

fn safe_duration_from_secs(value: f64, fallback: Duration) -> Duration {
    if value.is_finite() && value > 0.0 {
        Duration::try_from_secs_f64(value).unwrap_or(fallback)
    } else {
        fallback
    }
}

fn parse_cursor(cursor: Option<&str>) -> Result<usize> {
    let cursor = cursor.unwrap_or_default().trim();
    if cursor.is_empty() {
        return Ok(0);
    }
    cursor
        .parse::<usize>()
        .map_err(|_| anyhow!("invalid background progress cursor: {cursor}"))
}

fn snapshot_result(
    background_task_id: &str,
    task: &BackgroundTaskState,
    cursor: usize,
) -> Result<ToolResult> {
    let (mut progress, next_cursor, progress_truncated, progress_chars_total) =
        task.progress.read_from(cursor)?;
    for (offset, entry) in progress.iter_mut().enumerate() {
        entry.cursor = Some((cursor + offset + 1).to_string());
    }
    let snapshot = BackgroundTaskSnapshot {
        background_task_id: background_task_id.to_string(),
        status: task.status,
        progress,
        next_cursor: next_cursor.to_string(),
        progress_truncated,
        progress_chars_total,
        result: task.result.clone(),
        error: task.error.clone(),
    };
    let status = serde_json::to_value(task.status)
        .ok()
        .and_then(|value| value.as_str().map(str::to_string))
        .unwrap_or_else(|| "unknown".to_string());
    Ok(ToolResult::new(
        format!("Background task {background_task_id} is {status}."),
        serde_json::to_value(snapshot).context("failed to serialize background task snapshot")?,
    ))
}

pub struct OutletRunner<P: ToolProvider> {
    background: BackgroundPool<P>,
    config: RunnerConfig,
    client: reqwest::Client,
    runner_session_id: String,
    running: Arc<Mutex<HashMap<String, PollOperation>>>,
    events: Option<broadcast::Sender<RunnerEvent>>,
}

impl<P: ToolProvider> OutletRunner<P> {
    pub fn new(provider: P, mut config: RunnerConfig) -> Result<Self> {
        if config.server_url.trim().is_empty() {
            return Err(anyhow!("server_url is required"));
        }
        if config.token.trim().is_empty() {
            return Err(anyhow!("token is required"));
        }
        if !config.background_terminal_ttl_seconds.is_finite()
            || config.background_terminal_ttl_seconds <= 0.0
        {
            return Err(anyhow!(
                "background_terminal_ttl_seconds must be greater than zero"
            ));
        }
        config.max_concurrency = config.max_concurrency.max(1);
        config.background_control_capacity = config.background_control_capacity.max(1);

        let provider_metadata = provider.metadata();
        for (key, value) in provider_metadata {
            config.metadata.insert(key, value);
        }

        let provider = Arc::new(provider);
        let client = reqwest::Client::new();
        let terminal_ttl = safe_duration_from_secs(
            config.background_terminal_ttl_seconds,
            Duration::from_secs(86_400),
        );
        let background = BackgroundPool::new(
            Arc::clone(&provider),
            client.clone(),
            Arc::<str>::from(config.server_url.clone()),
            Arc::<str>::from(config.token.clone()),
            config.max_concurrency,
            terminal_ttl,
        );

        Ok(Self {
            background,
            config,
            client,
            runner_session_id: Uuid::new_v4().simple().to_string(),
            running: Arc::new(Mutex::new(HashMap::new())),
            events: None,
        })
    }

    pub fn set_event_sender(&mut self, sender: broadcast::Sender<RunnerEvent>) {
        self.events = Some(sender);
    }

    pub async fn serve(self, cancel: CancellationToken) -> Result<()> {
        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    break;
                }
                result = self.poll_once() => {
                    if let Err(error) = result {
                        let reason = one_line_error(&error);
                        self.emit(RunnerEvent::Disconnected { reason: reason.clone() });
                        warn!(server_url = %self.config.server_url, runner_id = %self.config.runner_id, reason = %reason, "outlet connection error");
                        tokio::select! {
                            _ = cancel.cancelled() => {
                                break;
                            }
                            _ = tokio::time::sleep(Duration::from_secs(2)) => {}
                        }
                    }
                }
            }
        }

        self.background.shutdown().await;
        self.emit(RunnerEvent::Stopped {
            reason: "cancelled".to_string(),
        });
        Ok(())
    }

    async fn poll_once(&self) -> Result<()> {
        let (capacity, control_capacity) = self.capacities().await;
        let payload = json!({
            "runner_id": self.config.runner_id,
            "runner_session_id": self.runner_session_id,
            "capacity": capacity,
            "control_capacity": control_capacity,
            "max_wait_seconds": self.config.poll_max_wait_seconds,
            "metadata": self.config.metadata,
        });

        let response = self
            .client
            .post(join_url(
                &self.config.server_url,
                &self.config.poll_endpoint,
            ))
            .bearer_auth(&self.config.token)
            .json(&payload)
            .timeout(Duration::from_secs_f64(
                self.config.poll_max_wait_seconds.max(0.0) + 15.0,
            ))
            .send()
            .await
            .context("poll request failed")?;

        let status = response.status();
        if status.as_u16() == 401 {
            return Err(anyhow!("Unauthorized. Check outlet token."));
        }
        if status.as_u16() == 409 {
            return Err(anyhow!("Runner already active."));
        }
        if !status.is_success() {
            return Err(anyhow!("Poll failed: HTTP {status}"));
        }

        let payload: PollResponse = response
            .json()
            .await
            .context("invalid poll JSON response")?;
        debug!(status = %payload.status, task_count = payload.tasks.len(), "outlet poll response");
        self.emit(RunnerEvent::Connected);

        for task in payload.tasks {
            let function_required = matches!(
                task.operation,
                PollOperation::Execute | PollOperation::BackgroundStart
            );
            if task.call_id.trim().is_empty()
                || (function_required && task.function_name.trim().is_empty())
            {
                continue;
            }

            let background = self.background.clone();
            let client = self.client.clone();
            let config = self.config.clone();
            let runner_session_id = self.runner_session_id.clone();
            let running = Arc::clone(&self.running);
            let events = self.events.clone();

            tokio::spawn(async move {
                handle_call(
                    background,
                    client,
                    config,
                    runner_session_id,
                    running,
                    events,
                    task,
                )
                .await;
            });
        }

        Ok(())
    }

    async fn capacities(&self) -> (usize, usize) {
        let (running_execute, running_control) = {
            let running = self.running.lock().await;
            let running_execute = running
                .values()
                .filter(|operation| **operation == PollOperation::Execute)
                .count();
            (
                running_execute,
                running.len().saturating_sub(running_execute),
            )
        };
        let running_background = self.background.running_background_count().await;
        let execution_capacity = self
            .config
            .max_concurrency
            .saturating_sub(running_execute.saturating_add(running_background));
        let control_capacity = self
            .config
            .background_control_capacity
            .saturating_sub(running_control);
        (execution_capacity, control_capacity)
    }

    fn emit(&self, event: RunnerEvent) {
        if let Some(sender) = &self.events {
            let _ = sender.send(event);
        }
    }
}

async fn handle_call<P: ToolProvider>(
    background: BackgroundPool<P>,
    client: reqwest::Client,
    config: RunnerConfig,
    runner_session_id: String,
    running: Arc<Mutex<HashMap<String, PollOperation>>>,
    events: Option<broadcast::Sender<RunnerEvent>>,
    task: PollTask,
) {
    {
        let mut running = running.lock().await;
        running.insert(task.call_id.clone(), task.operation);
    }

    emit(
        &events,
        RunnerEvent::CallStarted {
            call_id: task.call_id.clone(),
            function_name: task.function_name.clone(),
        },
    );

    let started_at = Instant::now();
    let mut status = "done".to_string();
    let mut result = ToolResult::new("", json!({}));
    let mut error_text = String::new();

    let context = CallContext::new(
        client.clone(),
        Arc::<str>::from(config.server_url.clone()),
        Arc::<str>::from(config.token.clone()),
        Arc::<str>::from(task.call_id.clone()),
    );

    let arguments = match task.arguments {
        Value::Object(_) => task.arguments,
        _ => json!({}),
    };
    let cursor = task.cursor.as_deref().unwrap_or("0");

    let call_result = match task.operation {
        PollOperation::Execute if task.function_name == DISCOVERY_FUNCTION => {
            let tools = background
                .tools()
                .into_iter()
                .map(|tool| {
                    json!({
                        "name": tool.name,
                        "description": tool.description,
                        "input_schema": tool.input_schema,
                        "supports_background": tool.supports_background,
                    })
                })
                .collect::<Vec<_>>();
            Ok(ToolResult::from_raw(json!({ "tools": tools })))
        }
        PollOperation::Execute => {
            background
                .call_foreground(&task.function_name, arguments, context)
                .await
        }
        PollOperation::BackgroundStart => {
            background
                .start_background(
                    &task.background_task_id,
                    &task.function_name,
                    arguments,
                    task.cursor.as_deref(),
                )
                .await
        }
        PollOperation::BackgroundStatus => {
            background
                .background_status(&task.background_task_id, cursor)
                .await
        }
        PollOperation::BackgroundCancel => {
            background
                .cancel_background(&task.background_task_id, cursor)
                .await
        }
    };

    match call_result {
        Ok(ok) => {
            result = ok;
        }
        Err(error) => {
            status = "error".to_string();
            error_text = error.to_string();
            result.raw = json!({
                "error": error_text,
            });
        }
    }

    if let Err(error) = send_complete(
        &client,
        &config,
        &runner_session_id,
        &task.call_id,
        &status,
        &result,
        &error_text,
    )
    .await
    {
        error!(
            call_id = %task.call_id,
            function_name = %task.function_name,
            error = %one_line_error(&error),
            "failed to deliver outlet completion"
        );
    }

    let duration_ms = started_at.elapsed().as_millis();
    emit(
        &events,
        RunnerEvent::CallFinished {
            call_id: task.call_id.clone(),
            function_name: task.function_name.clone(),
            status: status.clone(),
            duration_ms,
            error_text: error_text.clone(),
        },
    );

    if task.function_name == DISCOVERY_FUNCTION {
        info!(
            call_id = %task.call_id,
            status = %status,
            duration_ms,
            "outlet discovery call finished"
        );
    }

    {
        let mut running = running.lock().await;
        running.remove(&task.call_id);
    }
}

async fn send_complete(
    client: &reqwest::Client,
    config: &RunnerConfig,
    runner_session_id: &str,
    call_id: &str,
    status: &str,
    result: &ToolResult,
    error_text: &str,
) -> Result<()> {
    let payload = CompletePayload {
        runner_id: &config.runner_id,
        runner_session_id,
        call_id,
        status,
        result_text: &result.text,
        result_raw: &result.raw,
        result_media: &result.media,
        result_artifacts: &result.artifacts,
        error_text,
        metadata: &config.metadata,
    };

    let url = join_url(&config.server_url, &config.complete_endpoint);
    let started_at = Instant::now();
    let mut attempt = 0usize;
    let mut backoff = Duration::from_millis(500);

    loop {
        attempt += 1;
        let response = client
            .post(&url)
            .bearer_auth(&config.token)
            .json(&payload)
            .timeout(Duration::from_secs(10))
            .send()
            .await;

        match response {
            Ok(response) if response.status().is_success() => return Ok(()),
            Ok(response) if response.status().as_u16() == 404 => {
                info!(call_id, "outlet completion dropped because call is gone");
                return Ok(());
            }
            Ok(response) => {
                let http_status = response.status();
                let preview = response.text().await.unwrap_or_default();
                warn!(
                    call_id,
                    attempt,
                    status = %http_status,
                    body = %truncate_one_line(&preview, 200),
                    "outlet completion delivery retry"
                );
            }
            Err(error) => {
                warn!(
                    call_id,
                    attempt,
                    error = %truncate_one_line(error.to_string(), 200),
                    "outlet completion delivery retry"
                );
            }
        }

        if attempt >= config.complete_max_retries
            || started_at.elapsed().as_secs_f64() >= config.complete_max_seconds
        {
            return Err(anyhow!(
                "outlet completion delivery failed after {attempt} attempts for call {call_id}"
            ));
        }

        let jitter = Duration::from_millis(fastrand::u64(0..=backoff.as_millis().min(1000) as u64));
        tokio::time::sleep(backoff + jitter).await;
        backoff = (backoff * 2).min(Duration::from_secs(10));
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct PairingStartResponse {
    pub status: String,
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    #[serde(default = "default_pairing_expires_in")]
    pub expires_in: u64,
    #[serde(default = "default_pairing_interval")]
    pub interval: f64,
    #[serde(default)]
    pub suggested_tool_name: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct PairingPollResponse {
    pub status: String,
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub tool_instance_id: Option<i64>,
    #[serde(default)]
    pub error: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct OutletMetadataResponse {
    pub status: String,
    pub metadata: OutletMetadata,
}

impl OutletMetadataResponse {
    pub fn tool_instance_name(&self) -> &str {
        &self.metadata.tool_instance.name
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct OutletMetadata {
    pub tool_instance: OutletToolInstanceMetadata,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct OutletToolInstanceMetadata {
    pub id: i64,
    #[serde(rename = "type")]
    pub tool_type: String,
    pub name: String,
}

#[derive(Clone)]
pub struct PairingClient {
    client: reqwest::Client,
    server_url: String,
}

impl PairingClient {
    pub fn new(server_url: impl Into<String>) -> Self {
        Self {
            client: reqwest::Client::new(),
            server_url: server_url.into().trim().trim_end_matches('/').to_string(),
        }
    }

    pub async fn start(
        &self,
        runner_kind: &str,
        requested_name: &str,
        metadata: Map<String, Value>,
    ) -> Result<PairingStartResponse> {
        let response = self
            .client
            .post(join_url(&self.server_url, "/api/outlet/pair/start/"))
            .json(&json!({
                "runner_kind": runner_kind,
                "requested_name": requested_name,
                "metadata": metadata,
            }))
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .context("failed to start outlet pairing")?;

        let status = response.status();
        if !status.is_success() {
            return Err(anyhow!("pairing start failed: HTTP {status}"));
        }

        let mut payload: PairingStartResponse = response
            .json()
            .await
            .context("invalid pairing start JSON")?;
        payload.verification_url = build_verification_url(
            &self.server_url,
            &payload.user_code,
            &payload.verification_url,
        );
        Ok(payload)
    }

    pub async fn poll(&self, device_code: &str) -> Result<PairingPollResponse> {
        let response = self
            .client
            .post(join_url(&self.server_url, "/api/outlet/pair/poll/"))
            .json(&json!({ "device_code": device_code }))
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .context("failed to poll outlet pairing")?;

        let status = response.status();
        let payload: PairingPollResponse =
            response.json().await.context("invalid pairing poll JSON")?;
        if !status.is_success() && payload.error.trim().is_empty() {
            return Err(anyhow!("pairing poll failed: HTTP {status}"));
        }
        Ok(payload)
    }
}

#[derive(Clone)]
pub struct OutletMetadataClient {
    client: reqwest::Client,
    server_url: String,
    token: String,
}

impl OutletMetadataClient {
    pub fn new(server_url: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            client: reqwest::Client::new(),
            server_url: server_url.into().trim().trim_end_matches('/').to_string(),
            token: token.into().trim().to_string(),
        }
    }

    pub async fn fetch(&self) -> Result<OutletMetadataResponse> {
        let response = self
            .client
            .get(join_url(&self.server_url, "/api/outlet/metadata/"))
            .bearer_auth(&self.token)
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .context("failed to fetch outlet metadata")?;

        let status = response.status();
        if status.as_u16() == 401 {
            return Err(anyhow!("Unauthorized. Check outlet token."));
        }
        if !status.is_success() {
            return Err(anyhow!("outlet metadata failed: HTTP {status}"));
        }

        response
            .json()
            .await
            .context("invalid outlet metadata JSON")
    }
}

pub async fn pair_until_approved(
    server_url: &str,
    runner_kind: &str,
    requested_name: &str,
    metadata: Map<String, Value>,
) -> Result<String> {
    let client = PairingClient::new(server_url);
    let started = client.start(runner_kind, requested_name, metadata).await?;
    let deadline = Instant::now() + Duration::from_secs(started.expires_in.max(1));
    let interval = Duration::from_secs_f64(started.interval.max(0.5));

    while Instant::now() < deadline {
        let payload = client.poll(&started.device_code).await?;
        match payload.status.as_str() {
            "approved" if !payload.token.trim().is_empty() => return Ok(payload.token),
            "consumed" => {
                return Err(anyhow!(
                    "Pairing token already consumed. Please restart pairing."
                ))
            }
            "expired" => return Err(anyhow!("Pairing code expired.")),
            "error" => return Err(anyhow!(payload.error)),
            _ => tokio::time::sleep(interval).await,
        }
    }

    Err(anyhow!("Pairing timed out. Please retry."))
}

pub fn base_runner_metadata() -> Map<String, Value> {
    let mut metadata = Map::new();
    metadata.insert(
        "hostname".to_string(),
        json!(gethostname::gethostname().to_string_lossy()),
    );
    metadata.insert("pid".to_string(), json!(std::process::id()));
    metadata.insert("platform".to_string(), json!(platform_label()));
    metadata.insert("sys_platform".to_string(), json!(std::env::consts::OS));
    metadata.insert("os_name".to_string(), json!(os_name()));
    metadata
}

pub fn build_verification_url(server_url: &str, user_code: &str, fallback: &str) -> String {
    let user_code = user_code.trim();
    if user_code.is_empty() {
        return fallback.trim().to_string();
    }
    join_url(
        server_url,
        &format!(
            "/outlets/connect?code={}",
            percent_encode_query_value(user_code)
        ),
    )
}

pub fn join_url(base: &str, path: &str) -> String {
    format!(
        "{}/{}",
        base.trim().trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

fn emit(sender: &Option<broadcast::Sender<RunnerEvent>>, event: RunnerEvent) {
    if let Some(sender) = sender {
        let _ = sender.send(event);
    }
}

fn default_pairing_expires_in() -> u64 {
    900
}

fn default_pairing_interval() -> f64 {
    2.0
}

fn platform_label() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        std::env::consts::OS
    }
}

fn os_name() -> &'static str {
    if cfg!(target_family = "windows") {
        "nt"
    } else if cfg!(target_family = "unix") {
        "posix"
    } else {
        std::env::consts::FAMILY
    }
}

fn percent_encode_query_value(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(*byte as char);
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    encoded
}

fn one_line_error(error: &anyhow::Error) -> String {
    truncate_one_line(error.to_string(), 300)
}

fn truncate_one_line(text: impl AsRef<str>, max_len: usize) -> String {
    let one_line = text
        .as_ref()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if one_line.len() <= max_len {
        return one_line;
    }
    if max_len <= 3 {
        return one_line.chars().take(max_len).collect();
    }
    let mut truncated = one_line.chars().take(max_len - 3).collect::<String>();
    truncated.push_str("...");
    truncated
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use tokio::sync::Semaphore as TokioSemaphore;

    #[test]
    fn verification_url_uses_requested_server_base() {
        assert_eq!(
            build_verification_url(
                "https://club.example.com/base/",
                "ABCD EFGH/1",
                "https://wrong.example.com/outlets/connect"
            ),
            "https://club.example.com/base/outlets/connect?code=ABCD%20EFGH%2F1"
        );
    }

    #[test]
    fn runner_metadata_contains_platform_fields() {
        let metadata = base_runner_metadata();
        assert!(metadata.contains_key("hostname"));
        assert!(metadata.contains_key("platform"));
        assert!(metadata.contains_key("pid"));
    }

    #[test]
    fn runner_config_requires_server_url_and_token() {
        let provider = EmptyProvider;
        assert!(OutletRunner::new(provider, RunnerConfig::new("", "")).is_err());
    }

    #[test]
    fn runner_rejects_zero_background_terminal_ttl() {
        let mut config = RunnerConfig::new("http://server", "token");
        config.background_terminal_ttl_seconds = 0.0;
        let error = OutletRunner::new(EmptyProvider, config).err().unwrap();
        assert!(error.to_string().contains("greater than zero"));
    }

    struct EmptyProvider;

    #[async_trait]
    impl ToolProvider for EmptyProvider {
        fn tools(&self) -> Vec<ToolSpec> {
            Vec::new()
        }

        async fn call(
            &self,
            _function_name: &str,
            _arguments: Value,
            _context: CallContext,
        ) -> Result<ToolResult> {
            Ok(ToolResult::new("", json!({})))
        }
    }

    struct BackgroundTestProvider {
        started: Arc<AtomicUsize>,
        gate: Arc<TokioSemaphore>,
    }

    impl BackgroundTestProvider {
        fn new() -> Self {
            Self {
                started: Arc::new(AtomicUsize::new(0)),
                gate: Arc::new(TokioSemaphore::new(0)),
            }
        }
    }

    #[async_trait]
    impl ToolProvider for BackgroundTestProvider {
        fn tools(&self) -> Vec<ToolSpec> {
            vec![ToolSpec::new("run", "Run", json!({"type": "object"})).with_background_support()]
        }

        async fn call(
            &self,
            function_name: &str,
            arguments: Value,
            context: CallContext,
        ) -> Result<ToolResult> {
            self.started.fetch_add(1, Ordering::SeqCst);
            if let Some(text) = arguments.get("progress").and_then(Value::as_str) {
                context.report_progress("stdout", text);
            }
            if arguments
                .get("block")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                if arguments
                    .get("ignore_cancel")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                {
                    self.gate
                        .acquire()
                        .await
                        .map_err(|_| anyhow!("test gate closed"))?
                        .forget();
                } else {
                    tokio::select! {
                        permit = self.gate.acquire() => {
                            permit.map_err(|_| anyhow!("test gate closed"))?.forget();
                        }
                        _ = context.cancelled() => return Err(anyhow!("canceled")),
                    }
                }
            }
            if arguments
                .get("fail")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                return Err(anyhow!("requested failure"));
            }
            Ok(ToolResult::new(
                format!("{function_name} complete"),
                json!({"arguments": arguments}),
            ))
        }
    }

    fn test_pool(
        provider: Arc<BackgroundTestProvider>,
        max_concurrency: usize,
        terminal_ttl: Duration,
    ) -> BackgroundPool<BackgroundTestProvider> {
        BackgroundPool::new(
            provider,
            reqwest::Client::new(),
            "http://server",
            "token",
            max_concurrency,
            terminal_ttl,
        )
    }

    async fn wait_for_background_status<P: ToolProvider>(
        pool: &BackgroundPool<P>,
        task_id: &str,
        expected: BackgroundStatus,
    ) -> ToolResult {
        for _ in 0..100 {
            let result = pool.background_status(task_id, "0").await.unwrap();
            let status: BackgroundStatus =
                serde_json::from_value(result.raw["status"].clone()).unwrap();
            if status == expected {
                return result;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("background task {task_id} did not reach {expected:?}");
    }

    #[tokio::test]
    async fn background_start_is_idempotent_and_rejects_mismatched_request() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_secs(60));
        let arguments = json!({"block": true});

        pool.start_background("task-1", "run", arguments.clone(), None)
            .await
            .unwrap();
        let repeated = pool
            .start_background("task-1", "run", arguments, None)
            .await
            .unwrap();
        assert_eq!(repeated.raw["background_task_id"], "task-1");

        let error = pool
            .start_background("task-1", "run", json!({"block": false}), None)
            .await
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("different function or arguments"));

        provider.gate.add_permits(1);
        wait_for_background_status(&pool, "task-1", BackgroundStatus::Completed).await;
    }

    #[tokio::test]
    async fn background_pool_queues_work_at_capacity() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_secs(60));

        pool.start_background("task-1", "run", json!({"block": true}), None)
            .await
            .unwrap();
        wait_for_background_status(&pool, "task-1", BackgroundStatus::Running).await;
        pool.start_background("task-2", "run", json!({"block": true}), None)
            .await
            .unwrap();
        let queued = pool.background_status("task-2", "0").await.unwrap();
        assert_eq!(queued.raw["status"], "queued");
        assert_eq!(provider.started.load(Ordering::SeqCst), 1);

        provider.gate.add_permits(1);
        wait_for_background_status(&pool, "task-2", BackgroundStatus::Running).await;
        provider.gate.add_permits(1);
        wait_for_background_status(&pool, "task-2", BackgroundStatus::Completed).await;
    }

    #[tokio::test]
    async fn foreground_and_background_share_provider_capacity() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_secs(60));
        pool.start_background("task-bg", "run", json!({"block": true}), None)
            .await
            .unwrap();
        wait_for_background_status(&pool, "task-bg", BackgroundStatus::Running).await;

        let foreground_pool = pool.clone();
        let foreground = tokio::spawn(async move {
            foreground_pool
                .call_foreground(
                    "run",
                    json!({}),
                    CallContext::new(reqwest::Client::new(), "http://server", "token", "call"),
                )
                .await
                .unwrap()
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(provider.started.load(Ordering::SeqCst), 1);

        provider.gate.add_permits(1);
        let result = foreground.await.unwrap();
        assert_eq!(result.text, "run complete");
        assert_eq!(provider.started.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn saturated_execution_keeps_reserved_control_capacity() {
        let provider = BackgroundTestProvider::new();
        let gate = Arc::clone(&provider.gate);
        let mut config = RunnerConfig::new("http://server", "token");
        config.max_concurrency = 1;
        config.background_control_capacity = 2;
        let runner = OutletRunner::new(provider, config).unwrap();

        runner
            .background
            .start_background("task-saturated", "run", json!({"block": true}), None)
            .await
            .unwrap();
        wait_for_background_status(
            &runner.background,
            "task-saturated",
            BackgroundStatus::Running,
        )
        .await;

        assert_eq!(runner.capacities().await, (0, 2));
        runner
            .running
            .lock()
            .await
            .insert("control-call".to_string(), PollOperation::BackgroundStatus);
        assert_eq!(runner.capacities().await, (0, 1));

        runner.running.lock().await.remove("control-call");
        runner
            .background
            .cancel_background("task-saturated", "0")
            .await
            .unwrap();
        gate.add_permits(1);
    }

    #[tokio::test]
    async fn background_snapshot_pages_progress_with_string_cursor() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(provider, 1, Duration::from_secs(60));
        pool.start_background("task-progress", "run", json!({"progress": "hello"}), None)
            .await
            .unwrap();

        let completed =
            wait_for_background_status(&pool, "task-progress", BackgroundStatus::Completed).await;
        assert_eq!(completed.raw["progress"][0]["type"], "stdout");
        assert_eq!(completed.raw["progress"][0]["text"], "hello");
        assert_eq!(completed.raw["progress"][0]["cursor"], "1");
        assert_eq!(completed.raw["next_cursor"], "1");
        assert_eq!(completed.raw["result"]["text"], "run complete");
        assert!(completed.raw["error"].is_null());

        let next = pool.background_status("task-progress", "1").await.unwrap();
        assert_eq!(next.raw["progress"], json!([]));
        assert_eq!(next.raw["next_cursor"], "1");

        let error = pool
            .background_status("task-progress", "2")
            .await
            .unwrap_err();
        assert!(error.to_string().contains("cursor 2 is ahead of 1"));
    }

    #[tokio::test]
    async fn oversized_background_progress_is_split_into_cursor_addressable_entries() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(provider, 1, Duration::from_secs(60));
        let progress_text = "x".repeat(BACKGROUND_PROGRESS_ENTRY_MAX_CHARS * 3 + 17);

        pool.start_background(
            "task-oversized-progress",
            "run",
            json!({"progress": progress_text}),
            None,
        )
        .await
        .unwrap();

        let completed = wait_for_background_status(
            &pool,
            "task-oversized-progress",
            BackgroundStatus::Completed,
        )
        .await;
        let entries = completed.raw["progress"].as_array().unwrap();

        assert_eq!(entries.len(), 4);
        for (offset, entry) in entries.iter().enumerate() {
            assert!(
                entry["text"].as_str().unwrap().chars().count()
                    <= BACKGROUND_PROGRESS_ENTRY_MAX_CHARS
            );
            assert_eq!(entry["cursor"], (offset + 1).to_string());
        }

        let reconstructed = entries
            .iter()
            .map(|entry| entry["text"].as_str().unwrap())
            .collect::<String>();
        assert_eq!(reconstructed, progress_text);
        assert_eq!(completed.raw["next_cursor"], "4");

        let remaining = pool
            .background_status("task-oversized-progress", "1")
            .await
            .unwrap();
        assert_eq!(remaining.raw["progress"][0]["cursor"], "2");
        assert_eq!(remaining.raw["next_cursor"], "4");

        let reconstructed_remaining = remaining.raw["progress"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["text"].as_str().unwrap())
            .collect::<String>();
        assert_eq!(
            reconstructed_remaining,
            progress_text
                .chars()
                .skip(BACKGROUND_PROGRESS_ENTRY_MAX_CHARS)
                .collect::<String>()
        );
    }

    #[test]
    fn split_replace_progress_uses_append_mode_after_the_first_chunk() {
        let progress = ProgressLog::default();
        progress.push(BackgroundProgress {
            progress_type: "answer".to_string(),
            text: "x".repeat(BACKGROUND_PROGRESS_ENTRY_MAX_CHARS + 1),
            mode: Some("replace".to_string()),
            cursor: None,
        });

        let (entries, _next_cursor, _truncated, _chars_total) = progress.read_from(0).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].mode.as_deref(), Some("replace"));
        assert_eq!(entries[1].mode.as_deref(), Some("append"));
    }

    #[test]
    fn background_progress_log_is_bounded() {
        let progress = ProgressLog::default();
        for _ in 0..3 {
            progress.push(BackgroundProgress {
                progress_type: "stdout".to_string(),
                text: "x".repeat(200_000),
                mode: None,
                cursor: None,
            });
        }
        let (entries, next_cursor, truncated, chars_total) = progress.read_from(0).unwrap();
        assert!(
            entries.iter().map(|entry| entry.text.len()).sum::<usize>()
                <= BACKGROUND_PROGRESS_MAX_CHARS
        );
        assert!(entries
            .iter()
            .all(|entry| entry.text.chars().count() <= BACKGROUND_PROGRESS_ENTRY_MAX_CHARS));
        assert_eq!(entries.last().unwrap().progress_type, "system");
        assert_eq!(entries.last().unwrap().mode.as_deref(), Some("truncated"));
        assert_eq!(next_cursor, entries.len());
        assert!(truncated);
        assert_eq!(chars_total, 600_000);
    }

    #[tokio::test]
    async fn cancel_signals_provider_before_marking_the_task_terminal() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_secs(60));
        pool.start_background("task-cancel", "run", json!({"block": true}), None)
            .await
            .unwrap();
        wait_for_background_status(&pool, "task-cancel", BackgroundStatus::Running).await;

        let canceled = pool.cancel_background("task-cancel", "0").await.unwrap();
        assert_eq!(canceled.raw["status"], "running");

        let canceled =
            wait_for_background_status(&pool, "task-cancel", BackgroundStatus::Canceled).await;
        assert_eq!(canceled.raw["error"]["code"], "canceled");
        assert_eq!(canceled.raw["error"]["outcome"], "canceled");
    }

    #[tokio::test]
    async fn cancel_before_start_creates_an_idempotent_tombstone() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_secs(60));

        let canceled = pool.cancel_background("task-race", "0").await.unwrap();
        assert_eq!(canceled.raw["status"], "canceled");
        let replay = pool
            .start_background("task-race", "run", json!({"value": 1}), None)
            .await
            .unwrap();
        assert_eq!(replay.raw["status"], "canceled");
        let replay = pool
            .start_background("task-race", "run", json!({"value": 1}), None)
            .await
            .unwrap();
        assert_eq!(replay.raw["status"], "canceled");
        assert_eq!(provider.started.load(Ordering::SeqCst), 0);

        let error = pool
            .start_background("task-race", "run", json!({"value": 2}), None)
            .await
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("different function or arguments"));
    }

    #[tokio::test]
    async fn cancel_keeps_execution_capacity_until_provider_stops() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_secs(60));
        pool.start_background(
            "task-running",
            "run",
            json!({"block": true, "ignore_cancel": true}),
            None,
        )
        .await
        .unwrap();
        wait_for_background_status(&pool, "task-running", BackgroundStatus::Running).await;

        let cancel = pool.cancel_background("task-running", "0").await.unwrap();
        assert_eq!(cancel.raw["status"], "running");
        assert_eq!(pool.running_background_count().await, 1);
        pool.start_background("task-queued", "run", json!({}), None)
            .await
            .unwrap();
        assert_eq!(
            pool.background_status("task-queued", "0")
                .await
                .unwrap()
                .raw["status"],
            "queued"
        );
        assert_eq!(provider.started.load(Ordering::SeqCst), 1);

        provider.gate.add_permits(1);
        wait_for_background_status(&pool, "task-running", BackgroundStatus::Canceled).await;
        wait_for_background_status(&pool, "task-queued", BackgroundStatus::Completed).await;
        assert_eq!(provider.started.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn terminal_background_tasks_expire_after_ttl() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_millis(50));
        pool.start_background("task-ttl", "run", json!({}), None)
            .await
            .unwrap();
        wait_for_background_status(&pool, "task-ttl", BackgroundStatus::Completed).await;
        tokio::time::sleep(Duration::from_millis(75)).await;
        let error = pool.background_status("task-ttl", "0").await.unwrap_err();
        assert!(error.to_string().contains("expired"));

        let replay = pool
            .start_background("task-ttl", "run", json!({}), None)
            .await
            .unwrap_err();
        assert!(replay.to_string().starts_with("outlet_task_expired:"));
        assert_eq!(provider.started.load(Ordering::SeqCst), 1);
        let mismatch = pool
            .start_background("task-ttl", "run", json!({"different": true}), None)
            .await
            .unwrap_err();
        assert!(mismatch
            .to_string()
            .contains("different function or arguments"));
    }

    #[tokio::test]
    async fn zero_pool_ttl_is_normalized_and_cannot_reexecute_a_uuid() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::ZERO);
        pool.start_background("task-zero-ttl", "run", json!({}), None)
            .await
            .unwrap();
        wait_for_background_status(&pool, "task-zero-ttl", BackgroundStatus::Completed).await;
        tokio::time::sleep(Duration::from_millis(5)).await;

        let replay = pool
            .start_background("task-zero-ttl", "run", json!({}), None)
            .await
            .unwrap();
        assert_eq!(replay.raw["status"], "completed");
        assert_eq!(provider.started.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn expired_cancel_tombstone_is_bound_only_by_a_supported_start() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(Arc::clone(&provider), 1, Duration::from_millis(20));
        pool.cancel_background("task-expired-cancel", "0")
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(30)).await;

        let unsupported = pool
            .start_background("task-expired-cancel", "unknown", json!({}), None)
            .await
            .unwrap_err();
        assert!(unsupported.to_string().contains("does not support"));
        let valid = pool
            .start_background("task-expired-cancel", "run", json!({}), None)
            .await
            .unwrap_err();
        assert!(valid.to_string().starts_with("outlet_task_expired:"));
        assert_eq!(provider.started.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn pool_shutdown_cancels_and_awaits_background_jobs() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(provider, 1, Duration::from_secs(60));
        pool.start_background("task-shutdown", "run", json!({"block": true}), None)
            .await
            .unwrap();
        wait_for_background_status(&pool, "task-shutdown", BackgroundStatus::Running).await;

        pool.shutdown().await;
        let canceled = pool.background_status("task-shutdown", "0").await.unwrap();
        assert_eq!(canceled.raw["status"], "canceled");
        let error = pool
            .start_background("after-shutdown", "run", json!({}), None)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("shutting down"));
    }

    #[tokio::test]
    async fn failed_background_task_exposes_structured_error() {
        let provider = Arc::new(BackgroundTestProvider::new());
        let pool = test_pool(provider, 1, Duration::from_secs(60));
        pool.start_background("task-fail", "run", json!({"fail": true}), None)
            .await
            .unwrap();
        let failed = wait_for_background_status(&pool, "task-fail", BackgroundStatus::Failed).await;
        assert_eq!(failed.raw["error"]["code"], "execution_failed");
        assert_eq!(failed.raw["error"]["outcome"], "failed");
        assert!(failed.raw["result"].is_null());
    }

    #[test]
    fn discovery_tool_name_is_stable() {
        assert_eq!(DISCOVERY_FUNCTION, "outlet.list_tools");
    }

    #[test]
    fn join_url_handles_slashes() {
        assert_eq!(
            join_url("http://localhost:4000/", "/api/outlet"),
            "http://localhost:4000/api/outlet"
        );
    }

    #[test]
    fn complete_payload_keeps_media_and_artifacts_arrays() {
        let raw = json!({"ok": true});
        let result = ToolResult {
            text: "ok".to_string(),
            raw,
            media: vec![json!({"file_id": 1})],
            artifacts: vec![json!({"file_id": 2})],
        };
        assert_eq!(result.media.len(), 1);
        assert_eq!(result.artifacts.len(), 1);
    }

    #[test]
    fn pairing_defaults_match_server_flow() {
        assert_eq!(default_pairing_expires_in(), 900);
        assert_eq!(default_pairing_interval(), 2.0);
    }

    #[test]
    fn outlet_metadata_response_deserializes_and_exposes_name() {
        let payload: OutletMetadataResponse = serde_json::from_value(json!({
            "status": "ok",
            "metadata": {
                "tool_instance": {
                    "id": 123,
                    "type": "outlet",
                    "name": "Shell Outlet"
                }
            }
        }))
        .unwrap();

        assert_eq!(payload.status, "ok");
        assert_eq!(payload.tool_instance_name(), "Shell Outlet");
        assert_eq!(payload.metadata.tool_instance.id, 123);
        assert_eq!(payload.metadata.tool_instance.tool_type, "outlet");
    }

    #[test]
    fn tool_result_from_raw_uses_json_text() {
        let result = ToolResult::from_raw(json!({"tools": []}));
        assert_eq!(result.text, "{\"tools\":[]}");
    }

    #[test]
    fn truncate_one_line_collapses_whitespace() {
        assert_eq!(truncate_one_line("one\n two\tthree", 100), "one two three");
        assert_eq!(truncate_one_line("abcdef", 5), "ab...");
    }

    #[test]
    fn call_context_exposes_identifiers() {
        let context = CallContext::new(reqwest::Client::new(), "http://s", "t", "c");
        assert_eq!(context.server_url(), "http://s");
        assert_eq!(context.call_id(), "c");
    }

    #[test]
    fn config_defaults_are_daemon_friendly() {
        let cfg = RunnerConfig::new("http://localhost:4000/", "token");
        assert_eq!(cfg.server_url, "http://localhost:4000");
        assert_eq!(cfg.max_concurrency, 20);
        assert_eq!(cfg.background_control_capacity, 4);
        assert_eq!(cfg.poll_max_wait_seconds, 25.0);
    }

    #[test]
    fn tool_spec_constructor_sets_fields() {
        let spec = ToolSpec::new("x", "desc", json!({"type": "object"}));
        assert_eq!(spec.name, "x");
        assert_eq!(spec.description, "desc");
        assert_eq!(spec.input_schema["type"], "object");
        assert!(!spec.supports_background);

        let capable = ToolSpec::new("x", "desc", json!({})).with_background_support();
        assert!(capable.supports_background);
    }

    #[test]
    fn percent_encoding_keeps_safe_chars() {
        assert_eq!(percent_encode_query_value("ABCD-EFGH_1.~"), "ABCD-EFGH_1.~");
    }

    #[test]
    fn percent_encoding_escapes_unicode_bytes() {
        assert_eq!(percent_encode_query_value("я"), "%D1%8F");
    }

    #[test]
    fn empty_user_code_uses_fallback_verification_url() {
        assert_eq!(
            build_verification_url("http://server", "", "http://fallback/path"),
            "http://fallback/path"
        );
    }

    #[test]
    fn result_constructor_defaults_empty_media_artifacts() {
        let result = ToolResult::new("text", json!({"value": 1}));
        assert!(result.media.is_empty());
        assert!(result.artifacts.is_empty());
    }

    #[test]
    fn default_config_endpoint_paths_match_server() {
        let cfg = RunnerConfig::new("http://localhost:4000", "token");
        assert_eq!(cfg.poll_endpoint, "/api/outlet/poll/");
        assert_eq!(cfg.complete_endpoint, "/api/outlet/complete/");
    }

    #[test]
    fn metadata_merge_prefers_provider_values() {
        let mut cfg = RunnerConfig::new("http://localhost:4000", "token");
        cfg.metadata.insert("shell_kind".to_string(), json!("bash"));
        assert_eq!(cfg.metadata["shell_kind"], "bash");
    }

    #[test]
    fn pairing_poll_response_can_parse_pending() {
        let payload: PairingPollResponse =
            serde_json::from_value(json!({"status": "pending"})).unwrap();
        assert_eq!(payload.status, "pending");
        assert!(payload.token.is_empty());
    }

    #[test]
    fn pairing_start_response_defaults() {
        let payload: PairingStartResponse = serde_json::from_value(json!({
            "status": "ok",
            "device_code": "device",
            "user_code": "ABCD-EFGH",
            "verification_url": "http://server/outlets/connect"
        }))
        .unwrap();
        assert_eq!(payload.expires_in, 900);
        assert_eq!(payload.interval, 2.0);
    }

    #[test]
    fn runner_event_debug_is_available() {
        let event = RunnerEvent::Connected;
        assert!(format!("{event:?}").contains("Connected"));
    }

    #[test]
    fn downloaded_call_file_holds_bytes_and_headers() {
        let file = DownloadedCallFile {
            payload: Bytes::from_static(b"hello"),
            content_type: "text/plain".to_string(),
            content_disposition: String::new(),
        };
        assert_eq!(&file.payload[..], b"hello");
        assert_eq!(file.content_type, "text/plain");
    }

    #[test]
    fn poll_task_accepts_arguments_default() {
        let task: PollTask = serde_json::from_value(json!({
            "call_id": "call",
            "function": "tool"
        }))
        .unwrap();
        assert_eq!(task.arguments, Value::Null);
        assert_eq!(task.operation, PollOperation::Execute);
        assert!(task.background_task_id.is_empty());
        assert_eq!(task.cursor, None);
    }

    #[test]
    fn poll_task_accepts_background_control_fields_and_numeric_cursor() {
        let task: PollTask = serde_json::from_value(json!({
            "call_id": "call",
            "function": "run",
            "operation": "background_status",
            "background_task_id": "task-id",
            "cursor": 12
        }))
        .unwrap();
        assert_eq!(task.operation, PollOperation::BackgroundStatus);
        assert_eq!(task.background_task_id, "task-id");
        assert_eq!(task.cursor.as_deref(), Some("12"));
    }

    #[test]
    fn poll_response_accepts_missing_tasks() {
        let response: PollResponse = serde_json::from_value(json!({"status": "idle"})).unwrap();
        assert_eq!(response.status, "idle");
        assert!(response.tasks.is_empty());
    }

    #[test]
    fn token_is_trimmed_in_config() {
        let cfg = RunnerConfig::new(" http://localhost:4000/ ", " token ");
        assert_eq!(cfg.server_url, "http://localhost:4000");
        assert_eq!(cfg.token, "token");
    }

    #[test]
    fn metadata_os_name_is_not_empty() {
        let metadata = base_runner_metadata();
        assert!(metadata["os_name"].as_str().unwrap_or_default().len() > 1);
    }
}
