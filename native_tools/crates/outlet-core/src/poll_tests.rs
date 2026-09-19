use super::*;
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;

struct GatedProvider {
    gate: Arc<Semaphore>,
}

#[async_trait]
impl ToolProvider for GatedProvider {
    fn tools(&self) -> Vec<ToolSpec> {
        vec![ToolSpec::new("run", "Run", json!({"type": "object"}))]
    }

    async fn call(&self, _: &str, _: Value, _: CallContext) -> Result<ToolResult> {
        self.gate.acquire().await?.forget();
        Ok(ToolResult::new("done", json!({})))
    }
}

async fn request(listener: &TcpListener) -> (TcpStream, String, Value) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut bytes = Vec::new();
        let header_end = loop {
            let mut buffer = [0; 4096];
            let count = stream.read(&mut buffer).await.unwrap();
            assert_ne!(count, 0, "connection ended before request headers");
            bytes.extend_from_slice(&buffer[..count]);
            if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                break end + 4;
            }
        };
        let headers = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
        let path = headers.split_whitespace().nth(1).unwrap().to_string();
        let length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().unwrap())
            })
            .unwrap();
        while bytes.len() < header_end + length {
            let mut buffer = [0; 4096];
            let count = stream.read(&mut buffer).await.unwrap();
            assert_ne!(count, 0, "connection ended before request body");
            bytes.extend_from_slice(&buffer[..count]);
        }
        let body = serde_json::from_slice(&bytes[header_end..header_end + length]).unwrap();
        (stream, path, body)
    })
    .await
    .expect("expected an outlet request")
}

async fn respond(mut stream: TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes()).await.unwrap();
    stream.shutdown().await.unwrap();
}

fn active_ids(payload: &Value) -> Vec<String> {
    let mut ids: Vec<String> = serde_json::from_value(payload["active_call_ids"].clone()).unwrap();
    ids.sort();
    ids
}

async fn finished(events: &mut broadcast::Receiver<RunnerEvent>, count: usize) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut remaining = count;
        while remaining > 0 {
            if let RunnerEvent::CallFinished { .. } = events.recv().await.unwrap() {
                remaining -= 1;
            }
        }
    })
    .await
    .expect("calls did not finish");
}

#[tokio::test]
async fn next_poll_includes_every_accepted_call_before_workers_start() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let gate = Arc::new(Semaphore::new(0));
    let mut runner = OutletRunner::new(
        GatedProvider { gate: gate.clone() },
        RunnerConfig::new(url, "token"),
    )
    .unwrap();
    let (sender, mut events) = broadcast::channel(16);
    runner.set_event_sender(sender);
    let server = tokio::spawn(async move {
        let (stream, _, payload) = request(&listener).await;
        assert_eq!(payload["poll_sequence"], 1);
        assert!(active_ids(&payload).is_empty());
        respond(stream, "200 OK", r#"{"tasks":[{"call_id":"a","function":"run"},{"call_id":"b","function":"run"},{"call_id":"c","function":"run"}]}"#).await;

        let (stream, path, payload) = request(&listener).await;
        assert_eq!(path, "/api/outlet/poll/");
        assert_eq!(payload["poll_sequence"], 2);
        assert_eq!(active_ids(&payload), ["a", "b", "c"]);
        assert_eq!(payload["capacity"], 17);
        respond(stream, "200 OK", r#"{"tasks":[]}"#).await;

        for _ in 0..3 {
            let (stream, path, _) = request(&listener).await;
            assert_eq!(path, "/api/outlet/complete/");
            respond(stream, "200 OK", "{}").await;
        }

        let (stream, _, payload) = request(&listener).await;
        assert_eq!(payload["poll_sequence"], 3);
        assert!(active_ids(&payload).is_empty());
        respond(stream, "200 OK", r#"{"tasks":[]}"#).await;
    });

    runner.poll_once().await.unwrap();
    assert_eq!(runner.running.lock().await.len(), 3);
    runner.poll_once().await.unwrap();
    gate.add_permits(3);
    finished(&mut events, 3).await;
    runner.poll_once().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn finished_calls_remain_in_snapshots_while_completion_is_retried() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let mut runner = OutletRunner::new(
        GatedProvider {
            gate: Arc::new(Semaphore::new(1)),
        },
        RunnerConfig::new(url, "token"),
    )
    .unwrap();
    let (sender, mut events) = broadcast::channel(16);
    runner.set_event_sender(sender);
    let (completion_received, pending_completion) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _, _) = request(&listener).await;
        respond(
            stream,
            "200 OK",
            r#"{"tasks":[{"call_id":"a","function":"run"}]}"#,
        )
        .await;
        let (completion, path, first_result) = request(&listener).await;
        assert_eq!(path, "/api/outlet/complete/");
        completion_received.send(()).unwrap();

        let (stream, path, payload) = request(&listener).await;
        assert_eq!(path, "/api/outlet/poll/");
        assert_eq!(active_ids(&payload), ["a"]);
        respond(stream, "200 OK", r#"{"tasks":[]}"#).await;
        respond(completion, "503 Service Unavailable", "{}").await;

        let (stream, path, retried_result) = request(&listener).await;
        assert_eq!(path, "/api/outlet/complete/");
        assert_eq!(retried_result, first_result);
        respond(stream, "200 OK", "{}").await;

        let (stream, _, payload) = request(&listener).await;
        assert!(active_ids(&payload).is_empty());
        respond(stream, "200 OK", r#"{"tasks":[]}"#).await;
    });

    runner.poll_once().await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), pending_completion)
        .await
        .unwrap()
        .unwrap();
    runner.poll_once().await.unwrap();
    finished(&mut events, 1).await;
    runner.poll_once().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn unreadable_poll_response_is_followed_by_a_new_empty_snapshot() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let runner = OutletRunner::new(
        GatedProvider {
            gate: Arc::new(Semaphore::new(0)),
        },
        RunnerConfig::new(url, "token"),
    )
    .unwrap();
    let server = tokio::spawn(async move {
        let (stream, _, payload) = request(&listener).await;
        assert_eq!(payload["poll_sequence"], 1);
        respond(stream, "200 OK", r#"{"tasks":[{"call_id":"lost""#).await;
        let (stream, _, payload) = request(&listener).await;
        assert_eq!(payload["poll_sequence"], 2);
        assert!(active_ids(&payload).is_empty());
        respond(stream, "200 OK", r#"{"tasks":[]}"#).await;
    });

    assert!(runner
        .poll_once()
        .await
        .unwrap_err()
        .to_string()
        .contains("invalid poll JSON response"));
    runner.poll_once().await.unwrap();
    server.await.unwrap();
}
