//! Opt-in tests against a Linux Docker Engine, including one reachable through an SSH Unix socket.
//! Run with OUTLET_TEST_DOCKER_SOCKET and OUTLET_TEST_IMAGE, using --ignored --test-threads=1.
#![cfg(unix)]

use std::collections::HashMap;
use std::future::Future;
use std::io::Cursor;
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, ensure, Context, Result};
use bollard::container::{ListContainersOptions, RemoveContainerOptions};
use bollard::{Docker, API_DEFAULT_VERSION};
use futures_util::FutureExt;
use outlet_core::{BackgroundPool, CallContext, ExecutionContext, ToolProvider, ToolResult};
use outlet_task_container::manager::{ContainerConfig, ContainerManager, ROOT_LABEL, RUNNER_LABEL};
use outlet_task_container::ContainerOutlet;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::{JoinHandle, JoinSet};

const SERVER: &str = "http://container-provider-test.invalid";
const TOKEN: &str = "container-provider-test-token";
const USER: i64 = 9001;
const CALL: &str = "docker-provider-integration-call";

struct Fixture {
    docker: Docker,
    config: ContainerConfig,
    manager: Arc<ContainerManager>,
    _data: Arc<TempDir>,
}

impl Fixture {
    async fn new() -> Result<Self> {
        let socket = std::env::var("OUTLET_TEST_DOCKER_SOCKET")
            .unwrap_or_else(|_| "/var/run/docker.sock".into());
        let docker = Docker::connect_with_unix(&socket, 60, API_DEFAULT_VERSION)?
            .negotiate_version()
            .await?;
        let data = TempDir::new()?;
        let config = ContainerConfig {
            data_dir: data.path().to_path_buf(),
            image: std::env::var("OUTLET_TEST_IMAGE")
                .unwrap_or_else(|_| "python:3.12-bookworm".into()),
            max_containers: 8,
            max_disk_bytes: 1024 * 1024 * 1024,
            guaranteed_ttl: Duration::from_secs(3600),
            memory_bytes: 512 * 1024 * 1024,
            pids_limit: 64,
            nano_cpus: 1_000_000_000,
        };
        let manager = ContainerManager::open(docker.clone(), config.clone(), SERVER, TOKEN).await?;
        Ok(Self {
            docker,
            config,
            manager,
            _data: Arc::new(data),
        })
    }
}

async fn run_case<F, Fut>(case: F)
where
    F: FnOnce(Fixture) -> Fut,
    Fut: Future<Output = Result<()>>,
{
    let fixture = Fixture::new().await.expect("Docker integration fixture");
    let docker = fixture.docker.clone();
    let namespace = fixture.manager.runner_id().to_owned();
    let config = fixture.config.clone();
    let _data = fixture._data.clone();
    let result = AssertUnwindSafe(case(fixture)).catch_unwind().await;
    let cleanup = cleanup_namespace(&docker, &namespace, &config).await;
    if let Err(error) = cleanup {
        panic!("Could not remove test containers from namespace {namespace}: {error:#}");
    }
    match result {
        Ok(result) => result.expect("Docker provider integration test"),
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

async fn namespace_containers(docker: &Docker, namespace: &str) -> Result<Vec<String>> {
    let containers = docker
        .list_containers(Some(ListContainersOptions::<String> {
            all: true,
            filters: HashMap::from([(
                "label".to_string(),
                vec![format!("{RUNNER_LABEL}={namespace}")],
            )]),
            ..Default::default()
        }))
        .await?;
    let mut ids = Vec::new();
    for container in containers {
        ensure!(
            container
                .labels
                .as_ref()
                .and_then(|labels| labels.get(RUNNER_LABEL))
                .map(String::as_str)
                == Some(namespace),
            "Docker returned a foreign namespace; refusing cleanup"
        );
        ids.push(container.id.context("Docker listed container without id")?);
    }
    Ok(ids)
}

async fn cleanup_namespace(
    docker: &Docker,
    namespace: &str,
    config: &ContainerConfig,
) -> Result<()> {
    match ContainerManager::open(docker.clone(), config.clone(), SERVER, TOKEN).await {
        Ok(manager) => {
            ensure!(
                manager.runner_id() == namespace,
                "test database changed namespace during cleanup"
            );
            for id in namespace_containers(docker, namespace).await? {
                let info = docker.inspect_container(&id, None).await?;
                let root = info
                    .config
                    .and_then(|config| config.labels)
                    .and_then(|labels| labels.get(ROOT_LABEL).cloned())
                    .context("test container root label")?
                    .parse::<i64>()?;
                let lease = manager.acquire(root, USER).await?;
                manager.destroy(&lease, "integration_test_cleanup").await?;
            }
        }
        Err(_) => {
            // A failed assertion may leave a background future holding the DB lock. Killing only
            // the exact test namespace stops that future and avoids leaking its running command.
            for id in namespace_containers(docker, namespace).await? {
                docker
                    .remove_container(
                        &id,
                        Some(RemoveContainerOptions {
                            force: true,
                            v: true,
                            ..Default::default()
                        }),
                    )
                    .await?;
            }
        }
    }
    ensure!(
        namespace_containers(docker, namespace).await?.is_empty(),
        "test namespace was not completely cleaned"
    );
    Ok(())
}

fn routing(chat: i64, root: i64) -> ExecutionContext {
    ExecutionContext {
        chat_id: Some(chat),
        root_chat_id: Some(root),
        user_id: Some(USER),
    }
}

fn call_context(server: &str, chat: i64, root: i64) -> CallContext {
    CallContext::new(reqwest::Client::new(), server.to_owned(), TOKEN, CALL)
        .with_execution_context(Some(routing(chat, root)))
}

fn provider(manager: Arc<ContainerManager>) -> Result<ContainerOutlet> {
    ContainerOutlet::new(manager, Duration::from_secs(30), 1024 * 1024)
}

fn successful(result: &ToolResult) -> Result<()> {
    ensure!(
        result.raw["exit_code"] == 0,
        "Command failed: {}",
        result.text
    );
    ensure!(
        result.raw["error"].is_null(),
        "Command transport failed: {}",
        result.text
    );
    Ok(())
}

async fn run(provider: &ContainerOutlet, chat: i64, root: i64, args: Value) -> Result<ToolResult> {
    provider
        .call("run_command", args, call_context(SERVER, chat, root))
        .await
}

#[tokio::test]
#[ignore = "requires an explicitly selected Linux Docker Engine"]
async fn command_io_and_chat_family_routing() {
    run_case(|fixture| async move {
        let provider = provider(fixture.manager.clone())?;
        ensure!(provider.tools().iter().find(|tool| tool.name == "run_command").is_some_and(|tool| tool.supports_background), "run_command must advertise background support");
        let missing = provider.call("run_command", json!({"command":"true"}), CallContext::new(reqwest::Client::new(), SERVER, TOKEN, CALL)).await;
        ensure!(missing.is_err(), "missing server routing must fail closed");
        ensure!(namespace_containers(&fixture.docker, fixture.manager.runner_id()).await?.is_empty(), "invalid context must not allocate a container");
        ensure!(run(&provider, 101, 101, json!({"command":"true", "root_chat_id": 999})).await.is_err(), "model routing override must be rejected");

        let first = run(&provider, 101, 101, json!({"command":"mkdir -p /workspace/nested && printf shared > /workspace/family"})).await?;
        successful(&first)?;
        let io = run(&provider, 101, 101, json!({
            "command":"false",
            "argv":["python3", "-c", "import os,sys; print(os.getcwd()); print(os.environ['TEST_VALUE']); print(repr(sys.argv[1:])); print(sys.stdin.read()); print('stderr-marker', file=sys.stderr)", "", "space arg"],
            "cwd":"nested", "env":{"TEST_VALUE":"environment-marker"}, "stdin":"stdin-marker\n"
        })).await?;
        successful(&io)?;
        let stdout = io.raw["stdout"].as_str().context("stdout")?;
        ensure!(stdout.contains("/workspace/nested\n") && stdout.contains("environment-marker") && stdout.contains("['', 'space arg']") && stdout.contains("stdin-marker"), "argv/env/stdin/cwd failed: {}", io.text);
        ensure!(io.raw["stderr"].as_str().unwrap_or_default().contains("stderr-marker"), "stderr must be separate");

        let (child, nested_child) = tokio::join!(
            run(&provider, 102, 101, json!({"command":"cat /workspace/family"})),
            run(&provider, 103, 101, json!({"command":"cat /workspace/family"}))
        );
        for result in [child?, nested_child?] {
            successful(&result)?;
            ensure!(result.raw["stdout"] == "shared", "subagent missed shared files");
            ensure!(result.raw["workspace"]["container_id"] == first.raw["workspace"]["container_id"], "same root received a different container");
        }
        let isolated = run(&provider, 201, 201, json!({"command":"test ! -e /workspace/family"})).await?;
        successful(&isolated)?;
        ensure!(isolated.raw["workspace"]["container_id"] != first.raw["workspace"]["container_id"], "different roots shared a container");
        let wrong_user = CallContext::new(reqwest::Client::new(), SERVER, TOKEN, CALL)
            .with_execution_context(Some(ExecutionContext { user_id: Some(USER + 1), ..routing(104, 101) }));
        ensure!(provider.call("run_command", json!({"command":"true"}), wrong_user).await.is_err(), "root ownership changed silently");
        Ok(())
    }).await;
}

#[tokio::test]
#[ignore = "requires an explicitly selected Linux Docker Engine"]
async fn missing_container_and_timeout_survive_sqlite_reopen() {
    run_case(|fixture| async move {
        let Fixture {
            docker,
            config,
            manager,
            _data,
        } = fixture;
        let outlet = provider(manager.clone())?;
        let first = run(
            &outlet,
            301,
            301,
            json!({"command":"printf retained > /workspace/document"}),
        )
        .await?;
        successful(&first)?;
        let old_id = first.raw["workspace"]["container_id"]
            .as_str()
            .context("container id")?
            .to_owned();
        let generation = first.raw["workspace"]["generation"]
            .as_i64()
            .context("generation")?;
        drop(outlet);
        drop(manager);

        let manager = ContainerManager::open(docker.clone(), config.clone(), SERVER, TOKEN).await?;
        let outlet = provider(manager.clone())?;
        let retained = run(
            &outlet,
            302,
            301,
            json!({"command":"cat /workspace/document"}),
        )
        .await?;
        successful(&retained)?;
        ensure!(
            retained.raw["stdout"] == "retained"
                && retained.raw["workspace"]["container_id"] == old_id,
            "clean restart lost the idle workspace"
        );
        docker
            .remove_container(
                &old_id,
                Some(RemoveContainerOptions {
                    force: true,
                    v: true,
                    ..Default::default()
                }),
            )
            .await?;
        drop(outlet);
        drop(manager);

        let manager = ContainerManager::open(docker.clone(), config.clone(), SERVER, TOKEN).await?;
        let outlet = provider(manager.clone())?;
        let replacement = run(
            &outlet,
            303,
            301,
            json!({"command":"test ! -e /workspace/document"}),
        )
        .await?;
        successful(&replacement)?;
        ensure!(
            replacement.raw["workspace"]["recreated"] == true,
            "missing container reset was not reported after reopen"
        );
        ensure!(
            replacement.raw["workspace"]["generation"].as_i64() == Some(generation + 1),
            "replacement generation did not advance"
        );
        ensure!(
            replacement.text.contains("WARNING")
                && replacement
                    .text
                    .contains("Previous files/processes are gone"),
            "agent did not receive an explicit reset notice"
        );

        let timeout = run(
            &outlet,
            303,
            301,
            json!({"command":"sleep 300", "timeout_seconds":1}),
        )
        .await?;
        ensure!(
            timeout.raw["timed_out"] == true && timeout.raw["container_destroyed"] == true,
            "timeout must kill the whole task container: {}",
            timeout.text
        );
        let timed_id = timeout.raw["workspace"]["container_id"]
            .as_str()
            .context("timed out container id")?;
        ensure!(
            matches!(
                docker.inspect_container(timed_id, None).await,
                Err(bollard::errors::Error::DockerResponseServerError {
                    status_code: 404,
                    ..
                })
            ),
            "timed-out exec container is still alive"
        );
        drop(outlet);
        drop(manager);

        let manager = ContainerManager::open(docker, config, SERVER, TOKEN).await?;
        let outlet = provider(manager)?;
        let next = run(&outlet, 304, 301, json!({"command":"true"})).await?;
        successful(&next)?;
        ensure!(
            next.raw["workspace"]["recreated"] == true
                && next.raw["workspace"]["reset_reason"] == "command_timeout",
            "timeout tombstone did not survive restart"
        );
        Ok(())
    })
    .await;
}

async fn wait_background<F>(
    pool: &BackgroundPool<ContainerOutlet>,
    task: &str,
    predicate: F,
) -> Result<ToolResult>
where
    F: Fn(&ToolResult) -> bool,
{
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let snapshot = pool.background_status(task, "0").await?;
            if predicate(&snapshot) {
                return Ok(snapshot);
            }
            if matches!(
                snapshot.raw["status"].as_str(),
                Some("failed" | "canceled" | "completed")
            ) {
                bail!(
                    "Background task reached unexpected terminal state: {}",
                    snapshot.text
                );
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .context("background state deadline exceeded")?
}

#[tokio::test]
#[ignore = "requires an explicitly selected Linux Docker Engine"]
async fn background_progress_idempotency_and_real_cancellation() {
    run_case(|fixture| async move {
        let outlet = Arc::new(provider(fixture.manager.clone())?);
        let pool = BackgroundPool::with_default_client(outlet.clone(), SERVER, TOKEN, 3, Duration::from_secs(60));
        let task = "background-cancel-test";
        let args = json!({"command":"printf x >> /workspace/executions; printf 'ready-marker\n'; while :; do sleep 1; done"});
        pool.start_background_with_context(task, "run_command", args.clone(), None, Some(routing(401, 401))).await?;
        let progress = wait_background(&pool, task, |snapshot| snapshot.raw["progress"].as_array().is_some_and(|entries| entries.iter().any(|entry| entry["text"].as_str().unwrap_or_default().contains("ready-marker")))).await?;
        let cursor = progress.raw["next_cursor"].as_str().context("progress cursor")?;
        let delta = pool.background_status(task, cursor).await?;
        ensure!(delta.raw["progress"].as_array().is_some_and(Vec::is_empty), "unchanged cursor replayed progress");
        pool.start_background_with_context(task, "run_command", args.clone(), None, Some(routing(401, 401))).await?;
        ensure!(pool.start_background_with_context(task, "run_command", args, None, Some(routing(999, 999))).await.is_err(), "background task id was rebound to another workspace");
        let count = run(&outlet, 402, 401, json!({"command":"wc -c < /workspace/executions"})).await?;
        successful(&count)?;
        ensure!(count.raw["stdout"].as_str().unwrap_or_default().trim() == "1", "duplicate start executed twice");
        let container_id = count.raw["workspace"]["container_id"].as_str().context("container id")?.to_string();
        pool.cancel_background(task, "0").await?;
        wait_background(&pool, task, |snapshot| snapshot.raw["status"] == "canceled").await?;
        ensure!(matches!(fixture.docker.inspect_container(&container_id, None).await, Err(bollard::errors::Error::DockerResponseServerError { status_code:404, .. })), "cancel only stopped polling, not the command container");
        let next = run(&outlet, 403, 401, json!({"command":"test ! -e /workspace/executions"})).await?;
        successful(&next)?;
        ensure!(next.raw["workspace"]["recreated"] == true && next.raw["workspace"]["reset_reason"] == "command_canceled", "background cancel did not leave a reset notice");

        let done_task = "background-completion-test";
        let done_args = json!({"command":"printf y >> /workspace/executions; printf 'finished-marker\n'"});
        pool.start_background_with_context(done_task, "run_command", done_args.clone(), None, Some(routing(404, 401))).await?;
        let done = wait_background(&pool, done_task, |snapshot| snapshot.raw["status"] == "completed").await?;
        ensure!(done.raw["result"]["raw"]["stdout"].as_str().unwrap_or_default().contains("finished-marker"), "background result missing stdout");
        pool.start_background_with_context(done_task, "run_command", done_args, None, Some(routing(404, 401))).await?;
        let count = run(&outlet, 405, 401, json!({"command":"wc -c < /workspace/executions"})).await?;
        successful(&count)?;
        ensure!(count.raw["stdout"].as_str().unwrap_or_default().trim() == "1", "completed task was executed a second time");
        pool.shutdown().await;
        Ok(())
    }).await;
}

#[derive(Clone)]
struct DownloadBody {
    bytes: Vec<u8>,
    chunked: bool,
}
#[derive(Clone)]
struct HttpRequest {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}
struct FileServer {
    url: String,
    requests: Arc<Mutex<Vec<HttpRequest>>>,
    job: JoinHandle<()>,
}
impl Drop for FileServer {
    fn drop(&mut self) {
        self.job.abort();
    }
}
impl FileServer {
    async fn start(files: HashMap<String, DownloadBody>) -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}", listener.local_addr()?);
        let requests = Arc::new(Mutex::new(Vec::new()));
        let captured = requests.clone();
        let files = Arc::new(files);
        let job = tokio::spawn(async move {
            let mut handlers = JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let Ok((socket, _)) = accepted else { break; };
                        let files = files.clone(); let captured = captured.clone();
                        handlers.spawn(async move { handle_file_request(socket, &files, &captured).await });
                    }
                    _ = handlers.join_next(), if !handlers.is_empty() => {}
                }
            }
        });
        Ok(Self { url, requests, job })
    }
    fn uploads(&self) -> Vec<HttpRequest> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request.method == "POST")
            .cloned()
            .collect()
    }
}

async fn handle_file_request(
    socket: TcpStream,
    files: &HashMap<String, DownloadBody>,
    captured: &Mutex<Vec<HttpRequest>>,
) -> Result<()> {
    let mut socket = BufReader::new(socket);
    let mut line = String::new();
    socket.read_line(&mut line).await?;
    let mut parts = line.split_whitespace();
    let method = parts.next().context("HTTP method")?.to_string();
    let path = parts.next().context("HTTP path")?.to_string();
    let mut headers = HashMap::new();
    loop {
        line.clear();
        socket.read_line(&mut line).await?;
        if line == "\r\n" {
            break;
        }
        ensure!(!line.is_empty(), "unexpected HTTP header EOF");
        let (name, value) = line.trim_end().split_once(':').context("HTTP header")?;
        headers.insert(name.to_ascii_lowercase(), value.trim().to_string());
    }
    let mut body = Vec::new();
    if headers
        .get("transfer-encoding")
        .is_some_and(|value| value.eq_ignore_ascii_case("chunked"))
    {
        loop {
            line.clear();
            socket.read_line(&mut line).await?;
            let size = usize::from_str_radix(line.trim().split(';').next().unwrap_or(""), 16)?;
            if size == 0 {
                loop {
                    line.clear();
                    socket.read_line(&mut line).await?;
                    if line == "\r\n" || line.is_empty() {
                        break;
                    }
                }
                break;
            }
            ensure!(
                body.len() + size <= 2 * 1024 * 1024,
                "test upload too large"
            );
            let start = body.len();
            body.resize(start + size, 0);
            socket.read_exact(&mut body[start..]).await?;
            let mut ending = [0u8; 2];
            socket.read_exact(&mut ending).await?;
            ensure!(ending == *b"\r\n", "invalid chunk terminator");
        }
    } else if let Some(length) = headers.get("content-length") {
        let length = length.parse::<usize>()?;
        ensure!(length <= 2 * 1024 * 1024, "test upload too large");
        body.resize(length, 0);
        socket.read_exact(&mut body).await?;
    }
    captured.lock().unwrap().push(HttpRequest {
        method: method.clone(),
        path: path.clone(),
        headers,
        body,
    });
    let socket = socket.get_mut();
    if method == "GET" {
        let id = path.rsplit('/').next().unwrap_or_default();
        let file = files
            .get(id)
            .ok_or_else(|| anyhow!("unexpected test file path: {path}"))?;
        if file.chunked {
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").await?;
            for chunk in file.bytes.chunks(97) {
                socket
                    .write_all(format!("{:x}\r\n", chunk.len()).as_bytes())
                    .await?;
                socket.write_all(chunk).await?;
                socket.write_all(b"\r\n").await?;
            }
            socket.write_all(b"0\r\n\r\n").await?;
        } else {
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", file.bytes.len()).as_bytes()).await?;
            socket.write_all(&file.bytes).await?;
        }
    } else {
        ensure!(method == "POST", "unexpected file HTTP method");
        let response = json!({"file":{"file_external_id":"01234567-89ab-4cde-8012-3456789abcde", "content_type":"application/octet-stream"}}).to_string();
        socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", response.len(), response).as_bytes()).await?;
    }
    socket.shutdown().await?;
    Ok(())
}

#[tokio::test]
#[ignore = "requires an explicitly selected Linux Docker Engine"]
async fn binary_files_images_and_streaming_safety_limits() {
    run_case(|fixture| async move {
        let document_id = uuid::Uuid::new_v4().to_string();
        let image_id = uuid::Uuid::new_v4().to_string();
        let oversized_id = uuid::Uuid::new_v4().to_string();
        let binary = (0u8..=255).cycle().take(16 * 1024).collect::<Vec<_>>();
        let mut png = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image::RgbImage::new(2, 2)).write_to(&mut png, image::ImageFormat::Png)?;
        let png = png.into_inner();
        let server = FileServer::start(HashMap::from([
            (document_id.clone(), DownloadBody { bytes: binary.clone(), chunked: false }),
            (image_id.clone(), DownloadBody { bytes: png.clone(), chunked: false }),
            (oversized_id.clone(), DownloadBody { bytes: binary.clone(), chunked: true }),
        ])).await?;
        let outlet = provider(fixture.manager.clone())?;
        let ctx = || call_context(&server.url, 501, 501);
        let downloaded = outlet.call("download_file", json!({"file_id":document_id, "local_path":"reports/document.bin"}), ctx()).await?;
        ensure!(downloaded.raw["size_bytes"] == binary.len(), "download byte count mismatch");
        let hash = run(&outlet, 502, 501, json!({"argv":["python3", "-c", "import hashlib; print(hashlib.sha256(open('/workspace/reports/document.bin','rb').read()).hexdigest())"]})).await?;
        successful(&hash)?;
        let expected_hash = format!("{:x}", Sha256::digest(&binary));
        ensure!(hash.raw["stdout"].as_str().unwrap_or_default().trim() == expected_hash, "binary data changed in Docker upload");
        let uploaded = outlet.call("upload_file", json!({"local_path":"/workspace/reports/document.bin"}), ctx()).await?;
        ensure!(uploaded.artifacts.len() == 1 && uploaded.media.is_empty(), "upload must return an artifact");
        ensure!(uploaded.raw["sha256"] == expected_hash, "uploaded sha256 changed");
        let uploads = server.uploads();
        ensure!(uploads.len() == 1 && uploads[0].body == binary, "Docker extraction or chunked HTTP upload changed binary bytes");
        ensure!(uploads[0].path.starts_with(&format!("/api/outlet/calls/{CALL}/files")), "file upload escaped call scope");
        ensure!(uploads[0].headers.get("authorization").map(String::as_str) == Some(&format!("Bearer {TOKEN}")), "outlet authentication header missing");

        outlet.call("download_file", json!({"file_id":image_id, "local_path":"/workspace/page.png"}), ctx()).await?;
        let image = outlet.call("read_image", json!({"local_path":"/workspace/page.png"}), ctx()).await?;
        ensure!(image.media.len() == 1 && image.artifacts.is_empty(), "image must return model media");
        let uploads = server.uploads();
        ensure!(uploads.len() == 2 && uploads[1].body == png, "image bytes changed");
        ensure!(uploads[1].headers.get("content-type").map(String::as_str) == Some("application/octet-stream"), "file transport must stay opaque to server body parsers");
        ensure!(uploads[1].path.contains("mime_type=image%2Fpng"), "image upload MIME metadata missing");
        ensure!(outlet.call("read_image", json!({"local_path":"/workspace/reports/document.bin"}), ctx()).await.is_err(), "binary file accepted as image");
        ensure!(outlet.call("upload_file", json!({"local_path":"/workspace/reports"}), ctx()).await.is_err(), "directory accepted as a single file");
        let symlink = run(&outlet, 501, 501, json!({"command":"ln -s /workspace/reports/document.bin /workspace/link.bin"})).await?;
        successful(&symlink)?;
        ensure!(outlet.call("upload_file", json!({"local_path":"/workspace/link.bin"}), ctx()).await.is_err(), "symlink accepted despite regular-file-only contract");

        let limited = ContainerOutlet::new(fixture.manager, Duration::from_secs(30), 512)?;
        for id in [&document_id, &oversized_id] {
            let error = limited.call("download_file", json!({"file_id":id, "local_path":"/workspace/oversized.bin"}), ctx()).await.expect_err("oversized download must fail");
            ensure!(error.to_string().contains("transfer safety limit"), "unexpected size rejection: {error:#}");
        }
        let error = limited.call("upload_file", json!({"local_path":"/workspace/reports/document.bin"}), ctx()).await.expect_err("oversized upload must fail");
        ensure!(error.to_string().contains("transfer safety limit"), "unexpected upload size rejection: {error:#}");
        ensure!(server.uploads().len() == 2, "rejected files were still uploaded");
        Ok(())
    }).await;
}

#[tokio::test]
async fn file_helper_sends_json_and_form_documents_as_opaque_bytes() {
    let server = FileServer::start(HashMap::new()).await.unwrap();
    let context = call_context(&server.url, 1, 1);
    let cases = [
        (
            "report.json",
            "application/json",
            b"{\"total\":42}".as_slice(),
        ),
        (
            "broken.json",
            "application/json",
            b"not actually JSON\0".as_slice(),
        ),
        (
            "form.txt",
            "application/x-www-form-urlencoded",
            b"x=1&y=2".as_slice(),
        ),
    ];
    for (filename, mime, bytes) in cases {
        context
            .upload_call_file(filename, mime, bytes.to_vec())
            .await
            .unwrap();
    }
    let uploads = server.uploads();
    assert_eq!(uploads.len(), cases.len());
    for (upload, (filename, mime, bytes)) in uploads.iter().zip(cases) {
        assert_eq!(upload.headers["content-type"], "application/octet-stream");
        assert_eq!(upload.body, bytes);
        let url = reqwest::Url::parse(&format!("http://localhost{}", upload.path)).unwrap();
        let query = url.query_pairs().into_owned().collect::<HashMap<_, _>>();
        assert_eq!(query["filename"], filename);
        assert_eq!(query["mime_type"], mime);
    }
}
