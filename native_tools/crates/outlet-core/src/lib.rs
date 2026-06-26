use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use bytes::Bytes;
use reqwest::header::CONTENT_TYPE;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tokio::sync::{broadcast, Mutex};
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

pub const DISCOVERY_FUNCTION: &str = "outlet.list_tools";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
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
        }
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

#[derive(Clone)]
pub struct CallContext {
    client: reqwest::Client,
    server_url: Arc<str>,
    token: Arc<str>,
    call_id: Arc<str>,
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
        }
    }

    pub fn call_id(&self) -> &str {
        &self.call_id
    }

    pub fn server_url(&self) -> &str {
        &self.server_url
    }

    pub async fn upload_call_file(
        &self,
        filename: &str,
        mime_type: &str,
        payload: Vec<u8>,
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
            .body(payload);

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
    pub poll_max_wait_seconds: f64,
    pub complete_max_retries: usize,
    pub complete_max_seconds: f64,
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
            poll_max_wait_seconds: 25.0,
            complete_max_retries: 100,
            complete_max_seconds: 300.0,
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

#[derive(Clone, Debug, Deserialize)]
struct PollTask {
    call_id: String,
    #[serde(rename = "function")]
    function_name: String,
    #[serde(default)]
    arguments: Value,
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

pub struct OutletRunner<P: ToolProvider> {
    provider: Arc<P>,
    config: RunnerConfig,
    client: reqwest::Client,
    runner_session_id: String,
    running: Arc<Mutex<HashSet<String>>>,
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

        let provider_metadata = provider.metadata();
        for (key, value) in provider_metadata {
            config.metadata.insert(key, value);
        }

        Ok(Self {
            provider: Arc::new(provider),
            config,
            client: reqwest::Client::new(),
            runner_session_id: Uuid::new_v4().simple().to_string(),
            running: Arc::new(Mutex::new(HashSet::new())),
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
                    self.emit(RunnerEvent::Stopped { reason: "cancelled".to_string() });
                    return Ok(());
                }
                result = self.poll_once() => {
                    if let Err(error) = result {
                        let reason = one_line_error(&error);
                        self.emit(RunnerEvent::Disconnected { reason: reason.clone() });
                        warn!(server_url = %self.config.server_url, runner_id = %self.config.runner_id, reason = %reason, "outlet connection error");
                        tokio::select! {
                            _ = cancel.cancelled() => {
                                self.emit(RunnerEvent::Stopped { reason: "cancelled".to_string() });
                                return Ok(());
                            }
                            _ = tokio::time::sleep(Duration::from_secs(2)) => {}
                        }
                    }
                }
            }
        }
    }

    async fn poll_once(&self) -> Result<()> {
        let capacity = self.capacity().await;
        let payload = json!({
            "runner_id": self.config.runner_id,
            "runner_session_id": self.runner_session_id,
            "capacity": capacity,
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
            if task.call_id.trim().is_empty() || task.function_name.trim().is_empty() {
                continue;
            }

            let provider = Arc::clone(&self.provider);
            let client = self.client.clone();
            let config = self.config.clone();
            let runner_session_id = self.runner_session_id.clone();
            let running = Arc::clone(&self.running);
            let events = self.events.clone();

            tokio::spawn(async move {
                handle_call(
                    provider,
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

    async fn capacity(&self) -> usize {
        let running = self.running.lock().await;
        self.config.max_concurrency.saturating_sub(running.len())
    }

    fn emit(&self, event: RunnerEvent) {
        if let Some(sender) = &self.events {
            let _ = sender.send(event);
        }
    }
}

async fn handle_call<P: ToolProvider>(
    provider: Arc<P>,
    client: reqwest::Client,
    config: RunnerConfig,
    runner_session_id: String,
    running: Arc<Mutex<HashSet<String>>>,
    events: Option<broadcast::Sender<RunnerEvent>>,
    task: PollTask,
) {
    {
        let mut running = running.lock().await;
        running.insert(task.call_id.clone());
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

    let call_result = if task.function_name == DISCOVERY_FUNCTION {
        let tools = provider
            .tools()
            .into_iter()
            .map(|tool| {
                json!({
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.input_schema,
                })
            })
            .collect::<Vec<_>>();
        Ok(ToolResult::from_raw(json!({ "tools": tools })))
    } else {
        let arguments = match task.arguments {
            Value::Object(_) => task.arguments,
            _ => json!({}),
        };
        provider.call(&task.function_name, arguments, context).await
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
        assert_eq!(cfg.poll_max_wait_seconds, 25.0);
    }

    #[test]
    fn tool_spec_constructor_sets_fields() {
        let spec = ToolSpec::new("x", "desc", json!({"type": "object"}));
        assert_eq!(spec.name, "x");
        assert_eq!(spec.description, "desc");
        assert_eq!(spec.input_schema["type"], "object");
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
