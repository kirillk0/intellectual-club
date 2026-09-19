use super::*;

fn test_app() -> OutletDesktopApp {
    let (ui_tx, ui_rx) = mpsc::channel();
    OutletDesktopApp {
        config_path: std::env::temp_dir().join(format!("outlet-test-{}.json", Uuid::new_v4())),
        config: DesktopConfig::default(),
        runtime: tokio::runtime::Runtime::new().unwrap(),
        ui_tx,
        ui_rx,
        runners: HashMap::new(),
        statuses: HashMap::new(),
        histories: HashMap::new(),
        active_profile: None,
        scroll_to_active_tab: true,
        connection: None,
        connection_task: None,
        remove_profile: None,
        last_error: String::new(),
    }
}

#[test]
fn cancelled_connection_ignores_late_pairing_and_approval() {
    let mut app = test_app();
    app.open_connection(None);
    app.connection.as_mut().unwrap().request_id = Some("cancelled".into());
    app.close_connection();
    app.open_connection(None);
    app.connection.as_mut().unwrap().request_id = Some("current".into());
    app.ui_tx
        .send(UiEvent::PairingStarted {
            request_id: "cancelled".into(),
            user_code: "OLD".into(),
            verification_url: String::new(),
        })
        .unwrap();
    app.ui_tx
        .send(UiEvent::ConnectionReady {
            request_id: "cancelled".into(),
            server_url: "http://localhost:4000".into(),
            tool_name: "Old server".into(),
            token: "old-token".into(),
        })
        .unwrap();
    app.process_events();
    assert!(app.config.profiles.is_empty());
    assert!(app.connection.as_ref().unwrap().pairing.is_none());
    assert!(!app.config_path.exists());
}

#[test]
fn stopped_runner_ignores_queued_events() {
    let mut app = test_app();
    app.stop_profile("profile");
    app.ui_tx
        .send(UiEvent::Runner {
            profile_id: "profile".into(),
            generation: "old-run".into(),
            event: RunnerEvent::Connected,
        })
        .unwrap();
    app.process_events();
    assert!(!app.statuses["profile"].online);
    assert!(!app.statuses["profile"].running);
}

#[test]
fn invalid_manual_credentials_do_not_create_a_profile() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let server_url = format!("http://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0; 4096];
        let bytes_read = stream.read(&mut request).unwrap();
        assert!(bytes_read > 0);
        stream
            .write_all(
                b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .unwrap();
    });
    let mut app = test_app();
    app.open_connection(None);
    let form = app.connection.as_mut().unwrap();
    form.mode = ConnectionMode::Secret;
    form.server_url = server_url;
    form.secret = "invalid-secret".into();
    app.connect();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while app.connection.as_ref().unwrap().request_id.is_some()
        && std::time::Instant::now() < deadline
    {
        std::thread::sleep(std::time::Duration::from_millis(10));
        app.process_events();
    }
    assert!(app
        .connection
        .as_ref()
        .unwrap()
        .error
        .contains("Unauthorized"));
    assert!(app.config.profiles.is_empty());
    assert!(!app.config_path.exists());
    server.join().unwrap();
}

#[test]
fn server_urls_are_validated_and_normalized() {
    assert_eq!(
        validated_server_url(" https://example.com/base/ ").unwrap(),
        "https://example.com/base"
    );
    for value in [
        "",
        "example.com",
        "file:///tmp",
        "https://user:password@example.com",
        "https://example.com?token=secret",
        "https://example.com/#fragment",
    ] {
        assert!(validated_server_url(value).is_err(), "{value}");
    }
}

#[test]
fn secrets_are_random_256_bit_values() {
    let first = generate_secret().unwrap();
    assert_eq!(hex::decode(&first).unwrap().len(), 32);
    assert_ne!(first, generate_secret().unwrap());
}

#[test]
fn old_config_remains_compatible_and_duplicates_are_scoped_to_a_server() {
    let config: DesktopConfig = serde_json::from_value(serde_json::json!({
        "version": 1, "profiles": [{
            "id": "one", "name": "Server", "server_url": "http://localhost:4000/",
            "token": "secret", "runner_id": "stable", "auto_start": true,
            "created_at": "", "updated_at": ""
        }]
    }))
    .unwrap();
    assert!(duplicate_profile(
        &config,
        None,
        "http://localhost:4000",
        "secret"
    ));
    assert!(!duplicate_profile(
        &config,
        Some("one"),
        "http://localhost:4000",
        "secret"
    ));
    assert!(!duplicate_profile(
        &config,
        None,
        "http://localhost:5000",
        "secret"
    ));
    assert_eq!(config.profiles[0].runner_id, "stable");
}
