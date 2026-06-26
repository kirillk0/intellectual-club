use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde_json::Value;
use sha2::{Digest, Sha256};
use url::Url;

pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const AUTHORIZE_URL: &str = "https://auth.openai.com/oauth/authorize";
pub const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
pub const REDIRECT_URI: &str = "http://localhost:1455/auth/callback";
pub const SCOPE: &str = "openid profile email offline_access";
pub const PORT: u16 = 1455;
pub const CALLBACK_PATH: &str = "/auth/callback";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PkcePair {
    pub code_verifier: String,
    pub code_challenge: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallbackStatus {
    Code {
        code: String,
        state: String,
    },
    OAuthError {
        error: String,
        error_description: String,
    },
    NotFound,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenDisplayInfo {
    pub email: Option<String>,
    pub chatgpt_account_id: Option<String>,
    pub refresh_token: String,
    pub access_token: String,
    pub expires_in: String,
    pub token_type: String,
}

pub fn generate_pkce() -> Result<PkcePair> {
    let mut verifier_bytes = [0u8; 32];
    getrandom::getrandom(&mut verifier_bytes)
        .map_err(|error| anyhow!("failed to generate PKCE verifier: {error}"))?;
    let code_verifier = URL_SAFE_NO_PAD.encode(verifier_bytes);
    let code_challenge = pkce_challenge(&code_verifier);

    Ok(PkcePair {
        code_verifier,
        code_challenge,
    })
}

pub fn generate_state() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes)
        .map_err(|error| anyhow!("failed to generate OAuth state: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub fn pkce_challenge(code_verifier: &str) -> String {
    let digest = Sha256::digest(code_verifier.as_bytes());
    URL_SAFE_NO_PAD.encode(digest)
}

pub fn build_auth_url(code_challenge: &str, state: &str) -> Result<String> {
    let mut url = Url::parse(AUTHORIZE_URL).context("invalid authorization URL")?;
    url.query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", CLIENT_ID)
        .append_pair("redirect_uri", REDIRECT_URI)
        .append_pair("scope", SCOPE)
        .append_pair("code_challenge", code_challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("state", state)
        .append_pair("id_token_add_organizations", "true")
        .append_pair("codex_cli_simplified_flow", "true")
        .append_pair("originator", "codex_cli_rs");
    Ok(url.into())
}

pub fn parse_callback_target(target: &str) -> CallbackStatus {
    let Ok(url) = Url::parse(&format!("http://localhost{target}")) else {
        return CallbackStatus::NotFound;
    };

    if url.path() != CALLBACK_PATH {
        return CallbackStatus::NotFound;
    }

    let mut code = None;
    let mut state = None;
    let mut error = None;
    let mut error_description = String::new();

    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "code" => code = Some(value.into_owned()),
            "state" => state = Some(value.into_owned()),
            "error" => error = Some(value.into_owned()),
            "error_description" => error_description = value.into_owned(),
            _ => {}
        }
    }

    if let Some(error) = error {
        return CallbackStatus::OAuthError {
            error,
            error_description,
        };
    }

    match (code, state) {
        (Some(code), Some(state)) if !code.is_empty() => CallbackStatus::Code { code, state },
        _ => CallbackStatus::NotFound,
    }
}

pub fn validate_callback_state(status: CallbackStatus, expected_state: &str) -> Result<String> {
    match status {
        CallbackStatus::Code { code, state } if state == expected_state => Ok(code),
        CallbackStatus::Code { .. } => Err(anyhow!("OAuth state mismatch")),
        CallbackStatus::OAuthError {
            error,
            error_description,
        } => {
            if error_description.is_empty() {
                Err(anyhow!("{error}"))
            } else {
                Err(anyhow!("{error}: {error_description}"))
            }
        }
        CallbackStatus::NotFound => Err(anyhow!("OAuth callback was not found")),
    }
}

pub fn authorization_code_form(code: &str, code_verifier: &str) -> Vec<(&'static str, String)> {
    vec![
        ("grant_type", "authorization_code".to_string()),
        ("client_id", CLIENT_ID.to_string()),
        ("code", code.to_string()),
        ("code_verifier", code_verifier.to_string()),
        ("redirect_uri", REDIRECT_URI.to_string()),
    ]
}

pub fn refresh_token_form(refresh_token: &str) -> Vec<(&'static str, String)> {
    vec![
        ("grant_type", "refresh_token".to_string()),
        ("refresh_token", refresh_token.to_string()),
        ("client_id", CLIENT_ID.to_string()),
    ]
}

pub async fn post_token_form(
    client: &reqwest::Client,
    form: &[(&'static str, String)],
    failure_label: &str,
) -> Result<Value> {
    let response = client
        .post(TOKEN_URL)
        .form(form)
        .timeout(Duration::from_secs(30))
        .send()
        .await
        .with_context(|| format!("{failure_label}: request failed"))?;

    let status = response.status();
    let body = response
        .text()
        .await
        .with_context(|| format!("{failure_label}: failed to read response body"))?;

    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|value| {
                value
                    .get("error_description")
                    .and_then(Value::as_str)
                    .or_else(|| value.get("error").and_then(Value::as_str))
                    .map(str::to_string)
            })
            .unwrap_or(body);
        return Err(anyhow!("{failure_label}: {detail}"));
    }

    serde_json::from_str(&body).with_context(|| format!("{failure_label}: invalid JSON response"))
}

pub fn decode_jwt_claims(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    serde_json::from_slice(&bytes).ok()
}

pub fn token_display_info(tokens: &Value) -> TokenDisplayInfo {
    let claims = tokens
        .get("id_token")
        .and_then(Value::as_str)
        .and_then(decode_jwt_claims);
    let email = claims
        .as_ref()
        .and_then(|claims| claims.get("email"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let chatgpt_account_id = claims
        .as_ref()
        .and_then(|claims| claims.get("https://api.openai.com/auth"))
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .and_then(Value::as_str)
        .map(str::to_string);

    TokenDisplayInfo {
        email,
        chatgpt_account_id,
        refresh_token: token_field(tokens, "refresh_token"),
        access_token: token_field(tokens, "access_token"),
        expires_in: token_field(tokens, "expires_in"),
        token_type: token_field(tokens, "token_type"),
    }
}

fn token_field(tokens: &Value, key: &str) -> String {
    match tokens.get(key) {
        Some(Value::String(value)) => value.clone(),
        Some(value) if value.is_number() || value.is_boolean() => value.to_string(),
        _ => "N/A".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn pkce_challenge_matches_known_value() {
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn auth_url_contains_expected_params() {
        let url = build_auth_url("challenge", "state").unwrap();
        let parsed = Url::parse(&url).unwrap();
        let pairs = parsed.query_pairs().collect::<Vec<_>>();

        assert_eq!(parsed.as_str().split('?').next().unwrap(), AUTHORIZE_URL);
        assert!(pairs
            .iter()
            .any(|(key, value)| key == "client_id" && value == CLIENT_ID));
        assert!(pairs
            .iter()
            .any(|(key, value)| key == "code_challenge" && value == "challenge"));
        assert!(pairs
            .iter()
            .any(|(key, value)| key == "state" && value == "state"));
        assert!(pairs
            .iter()
            .any(|(key, value)| key == "originator" && value == "codex_cli_rs"));
    }

    #[test]
    fn callback_parser_extracts_code_and_state() {
        assert_eq!(
            parse_callback_target("/auth/callback?code=abc%20123&state=expected"),
            CallbackStatus::Code {
                code: "abc 123".to_string(),
                state: "expected".to_string()
            }
        );
    }

    #[test]
    fn callback_validation_rejects_wrong_state() {
        let result = validate_callback_state(
            CallbackStatus::Code {
                code: "code".to_string(),
                state: "wrong".to_string(),
            },
            "expected",
        );

        assert!(result.unwrap_err().to_string().contains("state mismatch"));
    }

    #[test]
    fn token_forms_match_oauth_grants() {
        assert_eq!(
            authorization_code_form("code", "verifier"),
            vec![
                ("grant_type", "authorization_code".to_string()),
                ("client_id", CLIENT_ID.to_string()),
                ("code", "code".to_string()),
                ("code_verifier", "verifier".to_string()),
                ("redirect_uri", REDIRECT_URI.to_string()),
            ]
        );
        assert_eq!(
            refresh_token_form("refresh"),
            vec![
                ("grant_type", "refresh_token".to_string()),
                ("refresh_token", "refresh".to_string()),
                ("client_id", CLIENT_ID.to_string()),
            ]
        );
    }

    #[test]
    fn display_info_reads_jwt_claims() {
        let claims = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&json!({
                "email": "person@example.com",
                "https://api.openai.com/auth": {
                    "chatgpt_account_id": "acct_123"
                }
            }))
            .unwrap(),
        );
        let tokens = json!({
            "id_token": format!("header.{claims}.sig"),
            "refresh_token": "refresh",
            "access_token": "access",
            "expires_in": 3600,
            "token_type": "Bearer"
        });
        let info = token_display_info(&tokens);

        assert_eq!(info.email.as_deref(), Some("person@example.com"));
        assert_eq!(info.chatgpt_account_id.as_deref(), Some("acct_123"));
        assert_eq!(info.refresh_token, "refresh");
        assert_eq!(info.access_token, "access");
        assert_eq!(info.expires_in, "3600");
        assert_eq!(info.token_type, "Bearer");
    }
}
