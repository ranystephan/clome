//! OAuth 2.0 authorization-code + PKCE flow.
//!
//! Phase 1 lands the *machinery* — generate auth URL, spin up a
//! loopback HTTP listener, exchange code for tokens, persist via
//! `mail::keychain`. The actual user-facing onboarding command in
//! `commands.rs` orchestrates these primitives.
//!
//! PKCE: native apps cannot keep a client secret. We fall under
//! RFC 8252 §6 — the auth flow uses a per-attempt `code_verifier` so
//! intercepting the redirect URL doesn't yield a usable code.
//!
//! Loopback: the redirect URI is `http://127.0.0.1:<random-port>/cb`.
//! We bind to port 0 so the OS picks a free port and we don't fight
//! with whatever else is on 8080. The auth URL embeds the chosen
//! port verbatim so Google's redirect-URI matcher accepts it (Google
//! treats any 127.0.0.1 port as a valid redirect for "Desktop app"
//! OAuth client types).

use std::collections::HashMap;
use std::time::Duration;

use oauth2::basic::BasicClient;
use oauth2::reqwest;
use oauth2::{
    AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken, EndpointNotSet, EndpointSet,
    PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, RefreshToken, Scope, TokenResponse, TokenUrl,
};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::oneshot;

use crate::mail::keychain::TokenBundle;
use crate::mail::types::OAuthEndpoints;

/// How long the loopback listener stays open waiting for the browser
/// redirect before giving up. Five minutes is generous — most OAuth
/// completions resolve in under a minute, but the user might fight a
/// 2FA prompt or pick the wrong account on the first try.
const LOOPBACK_TIMEOUT: Duration = Duration::from_secs(300);

pub struct PendingAuth {
    pub auth_url: String,
    pub redirect_uri: String,
    /// Resolves with the `?code=…` once the browser hits the loopback.
    pub completion: oneshot::Receiver<Result<AuthRedirect, String>>,
    /// PKCE verifier — held until token exchange.
    pub pkce_verifier: PkceCodeVerifier,
    /// State token — checked against the redirect's `state` param.
    pub csrf: CsrfToken,
    pub endpoints: OAuthEndpoints,
}

pub struct AuthRedirect {
    pub code: String,
    pub state: String,
}

/// Build the auth URL + spawn the loopback listener. Returns once the
/// listener is bound (so `redirect_uri` is concrete) but BEFORE the
/// browser is opened — caller's responsibility, since the trigger
/// pattern (Tauri shell plugin? webbrowser crate?) is policy.
pub async fn begin(endpoints: OAuthEndpoints) -> Result<PendingAuth, String> {
    // Bind to 127.0.0.1:0 — kernel picks a free ephemeral port.
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("oauth loopback bind: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("oauth loopback addr: {e}"))?
        .port();
    let redirect_uri = format!("http://127.0.0.1:{port}/cb");

    let (pkce_challenge, pkce_verifier) = PkceCodeChallenge::new_random_sha256();
    let client = build_client_with_optional_secret(&endpoints, &redirect_uri)?;

    let mut auth_req = client
        .authorize_url(CsrfToken::new_random)
        .set_pkce_challenge(pkce_challenge);
    for scope in &endpoints.scopes {
        auth_req = auth_req.add_scope(Scope::new(scope.clone()));
    }
    // Google requires `access_type=offline` + `prompt=consent` to
    // emit a refresh token on first auth. Microsoft uses
    // `offline_access` as a scope (added via autoconfig). Adding
    // these for non-Google providers is a no-op.
    auth_req = auth_req
        .add_extra_param("access_type", "offline")
        .add_extra_param("prompt", "consent");
    let (auth_url, csrf) = auth_req.url();
    let auth_url = auth_url.to_string();

    let (tx, rx) = oneshot::channel();
    tokio::spawn(loopback_listener(listener, tx));

    Ok(PendingAuth {
        auth_url,
        redirect_uri,
        completion: rx,
        pkce_verifier,
        csrf,
        endpoints,
    })
}

/// Wait for the browser to redirect, exchange the code for tokens,
/// and return a `TokenBundle` ready for `mail::keychain::store`.
pub async fn finish(pending: PendingAuth, provider_tag: &str) -> Result<TokenBundle, String> {
    let redirect = tokio::time::timeout(LOOPBACK_TIMEOUT, pending.completion)
        .await
        .map_err(|_| "oauth loopback timed out — browser never redirected".to_string())?
        .map_err(|_| "oauth loopback channel dropped".to_string())??;
    if redirect.state != *pending.csrf.secret() {
        return Err("oauth state mismatch — possible CSRF, aborting".into());
    }

    let http = reqwest::ClientBuilder::new()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("oauth http client: {e}"))?;
    let client = build_client_typed(&pending.endpoints, &pending.redirect_uri)?;
    let token = client
        .exchange_code(AuthorizationCode::new(redirect.code))
        .set_pkce_verifier(pending.pkce_verifier)
        .request_async(&http)
        .await
        .map_err(|e| format!("oauth token exchange: {e}"))?;

    Ok(TokenBundle {
        access_token: token.access_token().secret().clone(),
        refresh_token: token.refresh_token().map(|t| t.secret().clone()),
        expires_at: token
            .expires_in()
            .map(|d| chrono::Utc::now().timestamp() + d.as_secs() as i64),
        provider: provider_tag.into(),
    })
}

/// Refresh window: if the access token expires within this many
/// seconds, refresh proactively. Larger window = less risk of
/// shipping an about-to-expire token to IMAP / SMTP, smaller = fewer
/// refresh round-trips.
const REFRESH_BUFFER_SECS: i64 = 60;

/// Get a definitely-fresh access token for the given account. If the
/// stored bundle is past its `expires_at` (or about to be), call the
/// refresh endpoint, persist the new bundle to Keychain, and return
/// the new access_token. Otherwise return the cached one.
///
/// `account_email` is used to resolve the OAuth endpoints (autoconfig
/// gives us auth_url / token_url / client_id / client_secret per
/// provider). The provider tag stored on the bundle gates this.
///
/// Returns `Err` only when:
///   * the bundle is missing
///   * the bundle is expired AND has no refresh_token (re-auth needed)
///   * the refresh endpoint rejected the refresh token (re-auth needed)
pub async fn ensure_fresh_access(
    account_email: &str,
    keychain_ref: &str,
) -> Result<String, String> {
    let bundle = crate::mail::keychain::load(keychain_ref).await?;
    let now = chrono::Utc::now().timestamp();

    let needs_refresh = match bundle.expires_at {
        Some(expiry) => expiry <= now + REFRESH_BUFFER_SECS,
        // Provider didn't tell us the expiry; assume valid until proven
        // otherwise. The IMAP/SMTP layer will surface 401s and we'll
        // refresh on the next sync.
        None => false,
    };
    if !needs_refresh {
        if bundle.access_token.is_empty() {
            return Err("OAuth bundle has empty access_token — re-authenticate".into());
        }
        return Ok(bundle.access_token);
    }
    let refresh_token = bundle
        .refresh_token
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            "access token expired and no refresh token — re-add the account".to_string()
        })?;

    // Resolve current OAuth endpoints. Reading env every time picks
    // up CLOME_GOOGLE_OAUTH_CLIENT_ID / _SECRET refreshed in the
    // user's shell without an app rebuild.
    let cfg = crate::mail::autoconfig::resolve(account_email)?;
    let endpoints = cfg.oauth.ok_or_else(|| {
        "provider doesn't expose OAuth refresh — credentials would need re-entry".to_string()
    })?;

    let new_bundle = refresh(&endpoints, refresh_token, &bundle.provider).await?;
    crate::mail::keychain::store(keychain_ref, &new_bundle).await?;
    Ok(new_bundle.access_token)
}

/// Exchange a refresh token for a new access token. Called by the
/// IMAP/SMTP transport when a stored bundle is past `expires_at` (or
/// gets a 401 from the server). Returns the *new* bundle the caller
/// should write back to the Keychain.
pub async fn refresh(
    endpoints: &OAuthEndpoints,
    refresh_token: &str,
    provider_tag: &str,
) -> Result<TokenBundle, String> {
    let http = reqwest::ClientBuilder::new()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("oauth http client: {e}"))?;
    let client = build_client_typed(endpoints, "http://127.0.0.1:0/unused")?;
    let token = client
        .exchange_refresh_token(&RefreshToken::new(refresh_token.to_string()))
        .request_async(&http)
        .await
        .map_err(|e| format!("oauth refresh: {e}"))?;
    Ok(TokenBundle {
        access_token: token.access_token().secret().clone(),
        // Some providers return a fresh refresh token on refresh; some
        // don't. When absent, keep the existing one.
        refresh_token: token
            .refresh_token()
            .map(|t| t.secret().clone())
            .or_else(|| Some(refresh_token.to_string())),
        expires_at: token
            .expires_in()
            .map(|d| chrono::Utc::now().timestamp() + d.as_secs() as i64),
        provider: provider_tag.into(),
    })
}

type TypedClient = oauth2::Client<
    oauth2::StandardErrorResponse<oauth2::basic::BasicErrorResponseType>,
    oauth2::StandardTokenResponse<oauth2::EmptyExtraTokenFields, oauth2::basic::BasicTokenType>,
    oauth2::StandardTokenIntrospectionResponse<
        oauth2::EmptyExtraTokenFields,
        oauth2::basic::BasicTokenType,
    >,
    oauth2::StandardRevocableToken,
    oauth2::StandardErrorResponse<oauth2::RevocationErrorResponseType>,
    EndpointSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointSet,
>;

fn build_client_typed(endpoints: &OAuthEndpoints, redirect_uri: &str) -> Result<TypedClient, String> {
    build_client_with_optional_secret(endpoints, redirect_uri)
}

/// Constructs the typed `oauth2::Client`, attaching the
/// `client_secret` if the provider config supplies one. Google's
/// Desktop-app flow demands it; Microsoft's public client doesn't.
fn build_client_with_optional_secret(
    endpoints: &OAuthEndpoints,
    redirect_uri: &str,
) -> Result<TypedClient, String> {
    let mut client = BasicClient::new(ClientId::new(endpoints.client_id.clone()));
    if let Some(secret) = &endpoints.client_secret {
        client = client.set_client_secret(ClientSecret::new(secret.clone()));
    }
    Ok(client
        .set_auth_uri(
            AuthUrl::new(endpoints.auth_url.clone())
                .map_err(|e| format!("oauth auth url: {e}"))?,
        )
        .set_token_uri(
            TokenUrl::new(endpoints.token_url.clone())
                .map_err(|e| format!("oauth token url: {e}"))?,
        )
        .set_redirect_uri(
            RedirectUrl::new(redirect_uri.to_string())
                .map_err(|e| format!("oauth redirect url: {e}"))?,
        ))
}

async fn loopback_listener(
    listener: TcpListener,
    tx: oneshot::Sender<Result<AuthRedirect, String>>,
) {
    // Single-shot: we accept exactly one connection, parse its query
    // string, send a tiny success page back, and close. Any extra
    // connection (refresh, prefetch, scanner, …) gets a 404.
    let result = match listener.accept().await {
        Ok((stream, _peer)) => handle_one(stream).await,
        Err(e) => Err(format!("loopback accept: {e}")),
    };
    let _ = tx.send(result);
}

async fn handle_one(stream: tokio::net::TcpStream) -> Result<AuthRedirect, String> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut request_line = String::new();
    reader
        .read_line(&mut request_line)
        .await
        .map_err(|e| format!("loopback read: {e}"))?;
    // Drain the rest of the headers so the kernel doesn't keep them
    // in flight while we close. Cheap and avoids a RST seen by some
    // browsers.
    let mut buf = String::new();
    loop {
        buf.clear();
        let n = reader
            .read_line(&mut buf)
            .await
            .map_err(|e| format!("loopback drain: {e}"))?;
        if n == 0 || buf == "\r\n" || buf == "\n" {
            break;
        }
    }

    // GET /cb?code=…&state=… HTTP/1.1
    let path = request_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| format!("malformed request: {request_line:?}"))?;
    let query = path.split_once('?').map(|(_, q)| q).unwrap_or("");
    let mut params: HashMap<String, String> = HashMap::new();
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            params.insert(k.to_string(), urldecode(v));
        }
    }

    let body = if let Some(err) = params.get("error") {
        format!(
            "<!doctype html><meta charset=utf-8><title>Sign-in failed</title>\
             <body style=\"font-family:-apple-system,sans-serif;padding:2rem;color:#b91c1c\">\
             <h1>Sign-in failed</h1><p>{}</p>\
             <p>You can close this window and try again in Clome.</p>",
            html_escape(err)
        )
    } else {
        "<!doctype html><meta charset=utf-8><title>Signed in</title>\
         <body style=\"font-family:-apple-system,sans-serif;padding:2rem\">\
         <h1>Signed in</h1><p>You can close this window — Clome has your account.</p>\
         <script>setTimeout(()=>window.close(), 800)</script>"
            .to_string()
    };
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = write_half.write_all(response.as_bytes()).await;
    let _ = write_half.shutdown().await;

    if let Some(err) = params.get("error") {
        return Err(format!("oauth provider error: {err}"));
    }
    let code = params
        .remove("code")
        .ok_or_else(|| "loopback redirect missing `code` param".to_string())?;
    let state = params
        .remove("state")
        .ok_or_else(|| "loopback redirect missing `state` param".to_string())?;
    Ok(AuthRedirect { code, state })
}

fn urldecode(s: &str) -> String {
    let mut out = Vec::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    out.push(byte);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
