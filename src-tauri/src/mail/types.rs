//! Shared data types crossing the Rust↔TS boundary. All fields use
//! camelCase via `#[serde(rename_all = "camelCase")]` to match the
//! existing convention from `legacy.rs` and the rest of the frontend.

use serde::{Deserialize, Serialize};

/// What `mail::autoconfig` resolves for a given email address. The
/// frontend renders this back to the user as confirmation before
/// kicking off OAuth so a wrong server isn't silently used.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AutoconfigResult {
    pub email: String,
    pub display_name: Option<String>,
    pub provider: ProviderKind,
    pub imap: ServerConfig,
    pub smtp: ServerConfig,
    /// `Some(_)` when the provider is one of our well-known OAuth
    /// providers (gmail / outlook). `None` means the user must complete
    /// onboarding via app-specific password (iCloud) or basic auth.
    pub oauth: Option<OAuthEndpoints>,
    /// Where the autoconfig data came from — surfaced in the UI so the
    /// user can tell "we recognised your provider" from "we guessed".
    pub source: AutoconfigSource,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Gmail,
    Outlook,
    ICloud,
    Fastmail,
    Yahoo,
    /// Falls through to plain IMAP+SMTP w/ explicit server config.
    Imap,
}

impl ProviderKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ProviderKind::Gmail => "gmail",
            ProviderKind::Outlook => "outlook",
            ProviderKind::ICloud => "icloud",
            ProviderKind::Fastmail => "fastmail",
            ProviderKind::Yahoo => "yahoo",
            ProviderKind::Imap => "imap",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    /// `tls` = implicit TLS on connect (port 993 / 465).
    /// `starttls` = plain connect, upgrade via STARTTLS (port 143 / 587).
    /// We never accept `plain` — the autoconfig layer rejects entries
    /// that would put credentials over cleartext.
    pub security: TlsMode,
    /// Username template from autoconfig (`%EMAILADDRESS%` etc.) is
    /// expanded before storage; this field holds the resolved username.
    pub username: String,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TlsMode {
    Tls,
    Starttls,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthEndpoints {
    pub auth_url: String,
    pub token_url: String,
    pub client_id: String,
    /// Google issues a `client_secret` for Desktop-app OAuth clients
    /// and requires it in the token-exchange call, despite RFC 8252
    /// §6 saying PKCE replaces the need. From Google's own docs:
    /// *"Although the client_secret is not actually a secret for
    /// installed applications, we still require you to specify it
    /// for the token request."* Microsoft public clients do follow
    /// RFC 8252 — `None` for those.
    #[serde(default)]
    pub client_secret: Option<String>,
    pub scopes: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AutoconfigSource {
    /// Hardcoded provider preset (Gmail, Outlook, …). Highest trust.
    Builtin,
    /// `https://autoconfig.thunderbird.net/v1.1/<domain>` — Mozilla ISPDB.
    Ispdb,
    /// RFC 6186 DNS SRV (`_imaps._tcp`, `_submission._tcp`).
    Srv,
    /// Microsoft autodiscover XML. Catches Office 365 tenants that
    /// don't appear in the static Outlook provider config.
    Autodiscover,
    Manual,
}

/// Account row as visible to the frontend. Mirrors the SurrealDB
/// `email_account` schema minus the `keychain_ref` (intentionally
/// hidden from the renderer process).
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub email: String,
    pub display_name: Option<String>,
    pub provider: ProviderKind,
    pub imap_host: String,
    pub imap_port: u16,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub signature: Option<String>,
    pub notify_enabled: bool,
    pub attachment_auto_dl_max_mb: u32,
    pub created_at: String,
    pub last_sync_at: Option<String>,
}

/// Phase 1 onboarding intermediate state. `mail_oauth_start` returns
/// it; the loopback redirect handler consumes it once the browser
/// completes auth, then `mail_oauth_complete` finalises by writing the
/// account row + Keychain entry.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthHandoff {
    pub state: String,
    pub auth_url: String,
    pub redirect_uri: String,
}
