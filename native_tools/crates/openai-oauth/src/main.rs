use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use openai_oauth::{
    authorization_code_form, build_auth_url, generate_pkce, generate_state, parse_callback_target,
    post_token_form, refresh_token_form, token_display_info, validate_callback_state,
    CallbackStatus, PORT,
};

const CALLBACK_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Debug, Parser)]
#[command(name = "openai-oauth")]
#[command(about = "OpenAI OAuth helper for generating and refreshing tokens")]
struct Args {
    #[arg(long, value_name = "REFRESH_TOKEN")]
    refresh: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    if let Some(refresh_token) = args.refresh {
        do_refresh_token(refresh_token.trim()).await
    } else {
        do_oauth_flow().await
    }
}

async fn do_oauth_flow() -> Result<()> {
    print_title("OpenAI OAuth - Full Authorization Flow");

    println!("\nGenerating PKCE codes...");
    let pkce = generate_pkce()?;
    let state = generate_state()?;
    println!("   code_verifier: {}...", preview(&pkce.code_verifier, 20));
    println!("   state:         {state}");

    let auth_url = build_auth_url(&pkce.code_challenge, &state)?;

    println!("\nStarting callback server on port {PORT}...");
    let listener = TcpListener::bind(("127.0.0.1", PORT)).with_context(|| {
        format!(
            "port {PORT} is already in use or cannot be bound; another OAuth flow may be running"
        )
    })?;
    listener
        .set_nonblocking(true)
        .context("failed to configure callback server")?;
    println!("   Server started!");

    println!("\nOpening browser for authentication...");
    println!("   URL: {}", preview(&auth_url, 80));
    if let Err(error) = webbrowser::open(&auth_url) {
        println!("   Browser open failed: {error}");
        println!("   Open this URL manually:\n{auth_url}");
    }

    println!("\nWaiting for callback from OpenAI (timeout: 5 minutes)...");
    println!("   (Press Ctrl+C to cancel)");
    let code = wait_for_callback(listener, &state, CALLBACK_TIMEOUT)?;

    println!("\nAuthorization code received!");
    println!("   Code: {}...", preview(&code, 20));

    println!("\nExchanging code for tokens...");
    let client = reqwest::Client::new();
    let tokens = post_token_form(
        &client,
        &authorization_code_form(&code, &pkce.code_verifier),
        "Token exchange failed",
    )
    .await?;
    print_token_info(&tokens);
    Ok(())
}

async fn do_refresh_token(refresh_token: &str) -> Result<()> {
    if refresh_token.is_empty() {
        bail!("Usage: openai-oauth --refresh <refresh_token>");
    }

    print_title("OpenAI OAuth - Token Refresh");
    println!("\nRefreshing access token...");

    let client = reqwest::Client::new();
    let tokens = post_token_form(
        &client,
        &refresh_token_form(refresh_token),
        "Token refresh failed",
    )
    .await?;
    print_token_info(&tokens);
    Ok(())
}

fn wait_for_callback(
    listener: TcpListener,
    expected_state: &str,
    timeout: Duration,
) -> Result<String> {
    let started_at = Instant::now();

    while started_at.elapsed() < timeout {
        match listener.accept() {
            Ok((stream, _addr)) => {
                if let Some(code) = handle_stream(stream, expected_state)? {
                    return Ok(code);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error).context("callback server failed"),
        }
    }

    Err(anyhow!("Timeout: no callback received within 5 minutes"))
}

fn handle_stream(mut stream: TcpStream, expected_state: &str) -> Result<Option<String>> {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .context("failed to configure callback connection")?;

    let mut buffer = [0u8; 8192];
    let read = stream
        .read(&mut buffer)
        .context("failed to read callback request")?;
    let request = String::from_utf8_lossy(&buffer[..read]);
    let Some(target) = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
    else {
        write_response(&mut stream, 400, "text/plain", b"Bad request")?;
        return Ok(None);
    };

    let status = parse_callback_target(target);
    match status {
        CallbackStatus::NotFound => {
            write_response(&mut stream, 404, "text/plain", b"Not found")?;
            Ok(None)
        }
        CallbackStatus::OAuthError {
            error,
            error_description,
        } => {
            write_error_page(&mut stream, &error, &error_description)?;
            if error_description.is_empty() {
                Err(anyhow!("OAuth Error: {error}"))
            } else {
                Err(anyhow!("OAuth Error: {error}: {error_description}"))
            }
        }
        status @ CallbackStatus::Code { .. } => {
            match validate_callback_state(status, expected_state) {
                Ok(code) => {
                    write_success_page(&mut stream)?;
                    Ok(Some(code))
                }
                Err(error) => {
                    let message = error.to_string();
                    write_error_page(&mut stream, "invalid_state", &message)?;
                    Err(error)
                }
            }
        }
    }
}

fn print_title(title: &str) {
    println!("{}", "=".repeat(70));
    println!("{title}");
    println!("{}", "=".repeat(70));
}

fn print_token_info(tokens: &serde_json::Value) {
    let info = token_display_info(tokens);

    println!("\n{}", "=".repeat(70));
    println!("SUCCESS! Tokens received:");
    println!("{}", "=".repeat(70));

    if info.email.is_some() || info.chatgpt_account_id.is_some() {
        println!("\nUser Info from ID Token:");
        if let Some(email) = info.email {
            println!("   Email: {email}");
        }
        if let Some(account_id) = info.chatgpt_account_id {
            println!("   Account ID: {account_id}");
        }
    }

    println!("\nREFRESH TOKEN (save this!):");
    println!("   {}", info.refresh_token);
    println!("\nACCESS TOKEN:");
    println!("   {}", info.access_token);
    println!("\nExpires in: {} seconds", info.expires_in);
    println!("Token type: {}", info.token_type);
    println!("\n{}", "=".repeat(70));
    println!("Save the refresh token securely!");
    println!("   It can be used to get new access tokens without re-authenticating.");
    println!("{}", "=".repeat(70));
}

fn preview(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn write_success_page(stream: &mut TcpStream) -> Result<()> {
    let body = r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Authentication Successful</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
        .box { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); text-align: center; max-width: 400px; }
        h1 { color: #10a37f; margin-bottom: 16px; }
        p { color: #666; line-height: 1.5; }
        .icon { font-size: 48px; margin-bottom: 16px; }
    </style>
</head>
<body>
    <div class="box">
        <div class="icon">OK</div>
        <h1>Authentication Successful!</h1>
        <p>You can close this window and return to the terminal.<br>
        The authorization code has been captured.</p>
    </div>
</body>
</html>"#;
    write_response(stream, 200, "text/html; charset=utf-8", body.as_bytes())
}

fn write_error_page(stream: &mut TcpStream, error: &str, description: &str) -> Result<()> {
    let body = format!(
        r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Authentication Error</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }}
        .box {{ background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); text-align: center; max-width: 400px; }}
        h1 {{ color: #dc3545; margin-bottom: 16px; }}
        p {{ color: #666; line-height: 1.5; }}
        .error {{ background: #f8f9fa; padding: 12px; border-radius: 6px; font-family: monospace; font-size: 12px; color: #dc3545; margin-top: 16px; }}
    </style>
</head>
<body>
    <div class="box">
        <h1>Authentication Failed</h1>
        <p><strong>{}</strong></p>
        <div class="error">{}</div>
    </div>
</body>
</html>"#,
        html_escape(error),
        html_escape(description)
    );
    write_response(stream, 400, "text/html; charset=utf-8", body.as_bytes())
}

fn write_response(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        _ => "OK",
    };
    let headers = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(headers.as_bytes())
        .and_then(|_| stream.write_all(body))
        .context("failed to write callback response")
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
