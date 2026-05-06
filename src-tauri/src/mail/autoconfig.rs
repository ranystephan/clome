//! Provider discovery for "type your email and we figure the rest
//! out" onboarding. Lookup order:
//!
//!   1. Hardcoded provider presets (gmail, outlook, icloud, fastmail,
//!      yahoo). Highest trust — the values are baked into the binary
//!      and reviewed at code-review time, not pulled from DNS.
//!   2. Mozilla ISPDB (autoconfig.thunderbird.net). Covers thousands
//!      of providers including most universities.
//!   3. RFC 6186 DNS SRV (`_imaps._tcp`, `_submission._tcp`).
//!   4. Microsoft autodiscover (Office 365 tenants).
//!   5. Manual entry fallback in the UI (returns `Err` here).
//!
//! Phase 1 implements (1). (2)–(4) land in Phase 3 once the IMAP
//! transport is exercising the resolved values; bringing them up
//! before then would mean writing tests with no consumer.

use crate::mail::types::{
    AutoconfigResult, AutoconfigSource, OAuthEndpoints, ProviderKind, ServerConfig, TlsMode,
};

/// Extract the host from an email address. Lowercased, IDN-aware.
/// Returns `None` for malformed inputs — we don't try to sanitise.
pub fn domain_of(email: &str) -> Option<String> {
    let (_, host) = email.rsplit_once('@')?;
    if host.is_empty() {
        return None;
    }
    // IDN: cafés.example → xn--cafs-uoa.example. Lookups must hit the
    // ASCII form. `idna::domain_to_ascii` returns the input unchanged
    // when no Unicode is present, so it's a safe always-on transform.
    idna::domain_to_ascii(&host.to_ascii_lowercase()).ok()
}

/// Phase 1 entry point. Returns Ok for known providers, Err otherwise
/// — the frontend reads the Err and presents manual server entry.
pub fn resolve(email: &str) -> Result<AutoconfigResult, String> {
    let domain = domain_of(email)
        .ok_or_else(|| format!("invalid email address: {email}"))?;
    if let Some(preset) = builtin_preset(email, &domain) {
        return Ok(preset);
    }
    Err(format!(
        "no autoconfig for {domain} yet — manual entry required (ISPDB / SRV / autodiscover \
         lands in Phase 3)"
    ))
}

fn builtin_preset(email: &str, domain: &str) -> Option<AutoconfigResult> {
    match domain {
        "gmail.com" | "googlemail.com" => Some(gmail(email)),
        d if d.ends_with(".edu") && is_google_workspace(d) => Some(gmail_workspace(email)),
        "outlook.com" | "hotmail.com" | "live.com" | "msn.com" => Some(outlook(email)),
        // Stanford uses Google Workspace; bake it in so Rany's primary
        // dogfood account works without the ISPDB round-trip. Other
        // common workspace domains discovered via field testing land
        // here as we ship.
        "stanford.edu" => Some(gmail_workspace(email)),
        "icloud.com" | "me.com" | "mac.com" => Some(icloud(email)),
        "fastmail.com" | "fastmail.fm" => Some(fastmail(email)),
        "yahoo.com" | "ymail.com" | "rocketmail.com" => Some(yahoo(email)),
        _ => None,
    }
}

/// Heuristic for "is this domain pointing at Google Workspace?". For
/// Phase 1 we keep it as a stub returning false — the proper test is
/// an MX lookup of `google.com` or `googlemail.com`. Phase 3 wires
/// hickory-resolver and replaces this.
fn is_google_workspace(_domain: &str) -> bool {
    false
}

// ── OAuth client identifiers ───────────────────────────────────────
//
// Native (Desktop / Native app) OAuth clients are public per RFC 8252;
// PKCE replaces the client secret. We still need a real *registered*
// client ID for each provider — Google rejects unregistered IDs at
// the auth-URL step, before the user ever sees a consent screen.
//
// Resolution order at autoconfig time:
//   1. Env var (`CLOME_GOOGLE_OAUTH_CLIENT_ID`, `CLOME_MS_OAUTH_CLIENT_ID`)
//   2. Compile-time default (placeholder until you register your own)
//
// See `clome/scripts/oauth-setup.md` for step-by-step registration
// instructions. Bake your IDs into a wrapper (e.g. an exported shell
// var in your dev shell, or a `.env` file Tauri picks up at boot).

const PLACEHOLDER_GOOGLE: &str = "REPLACE_GOOGLE_CLIENT_ID.apps.googleusercontent.com";
const PLACEHOLDER_MICROSOFT: &str = "REPLACE_MS_CLIENT_ID";

fn google_client_id() -> String {
    std::env::var("CLOME_GOOGLE_OAUTH_CLIENT_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| PLACEHOLDER_GOOGLE.to_string())
}

/// Google's Desktop-app OAuth flow requires the client_secret in the
/// token-exchange call. The secret is not actually secret (it's emitted
/// alongside the client_id in Cloud Console); we read it from an env
/// var so each developer keeps their own pair without committing
/// either one.
fn google_client_secret() -> Option<String> {
    std::env::var("CLOME_GOOGLE_OAUTH_CLIENT_SECRET")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn microsoft_client_id() -> String {
    std::env::var("CLOME_MS_OAUTH_CLIENT_ID")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| PLACEHOLDER_MICROSOFT.to_string())
}

// ── Provider presets ────────────────────────────────────────────────

fn gmail(email: &str) -> AutoconfigResult {
    AutoconfigResult {
        email: email.to_string(),
        display_name: None,
        provider: ProviderKind::Gmail,
        imap: ServerConfig {
            host: "imap.gmail.com".into(),
            port: 993,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        smtp: ServerConfig {
            host: "smtp.gmail.com".into(),
            port: 465,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        oauth: Some(OAuthEndpoints {
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".into(),
            token_url: "https://oauth2.googleapis.com/token".into(),
            client_id: google_client_id(),
            client_secret: google_client_secret(),
            scopes: vec!["https://mail.google.com/".into()],
        }),
        source: AutoconfigSource::Builtin,
    }
}

fn gmail_workspace(email: &str) -> AutoconfigResult {
    // Same servers + OAuth endpoints as consumer Gmail — Workspace
    // domains tunnel through the same backend. The provider tag
    // remains Gmail so the rest of the codebase doesn't need to
    // branch.
    gmail(email)
}

fn outlook(email: &str) -> AutoconfigResult {
    AutoconfigResult {
        email: email.to_string(),
        display_name: None,
        provider: ProviderKind::Outlook,
        imap: ServerConfig {
            host: "outlook.office365.com".into(),
            port: 993,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        smtp: ServerConfig {
            host: "smtp.office365.com".into(),
            port: 587,
            security: TlsMode::Starttls,
            username: email.to_string(),
        },
        oauth: Some(OAuthEndpoints {
            auth_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize".into(),
            token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token".into(),
            client_id: microsoft_client_id(),
            // Microsoft public-client (native) follows RFC 8252:
            // PKCE alone, no secret in token exchange.
            client_secret: None,
            scopes: vec![
                "https://outlook.office.com/IMAP.AccessAsUser.All".into(),
                "https://outlook.office.com/SMTP.Send".into(),
                "offline_access".into(),
            ],
        }),
        source: AutoconfigSource::Builtin,
    }
}

fn icloud(email: &str) -> AutoconfigResult {
    AutoconfigResult {
        email: email.to_string(),
        display_name: None,
        provider: ProviderKind::ICloud,
        imap: ServerConfig {
            host: "imap.mail.me.com".into(),
            port: 993,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        smtp: ServerConfig {
            host: "smtp.mail.me.com".into(),
            port: 587,
            security: TlsMode::Starttls,
            username: email.to_string(),
        },
        // iCloud requires app-specific passwords (no public OAuth).
        // The frontend renders an explanatory step in onboarding when
        // `oauth.is_none()`.
        oauth: None,
        source: AutoconfigSource::Builtin,
    }
}

fn fastmail(email: &str) -> AutoconfigResult {
    AutoconfigResult {
        email: email.to_string(),
        display_name: None,
        provider: ProviderKind::Fastmail,
        imap: ServerConfig {
            host: "imap.fastmail.com".into(),
            port: 993,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        smtp: ServerConfig {
            host: "smtp.fastmail.com".into(),
            port: 465,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        // Fastmail supports OAuth via JMAP-issued bearer tokens but no
        // public OAuth endpoint for IMAP+SMTP. App-password path for v1.
        oauth: None,
        source: AutoconfigSource::Builtin,
    }
}

fn yahoo(email: &str) -> AutoconfigResult {
    AutoconfigResult {
        email: email.to_string(),
        display_name: None,
        provider: ProviderKind::Yahoo,
        imap: ServerConfig {
            host: "imap.mail.yahoo.com".into(),
            port: 993,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        smtp: ServerConfig {
            host: "smtp.mail.yahoo.com".into(),
            port: 465,
            security: TlsMode::Tls,
            username: email.to_string(),
        },
        // Yahoo restricted XOAUTH2 to "trusted" partners in 2024;
        // dogfood with app-specific password until / unless we get
        // partner approval (Open Question #2).
        oauth: None,
        source: AutoconfigSource::Builtin,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_strips_case_and_idn() {
        assert_eq!(domain_of("Foo@Example.COM").as_deref(), Some("example.com"));
        assert_eq!(domain_of("rany@Stanford.EDU").as_deref(), Some("stanford.edu"));
        assert!(domain_of("not-an-email").is_none());
    }

    #[test]
    fn gmail_preset_uses_oauth() {
        let r = resolve("user@gmail.com").unwrap();
        assert_eq!(r.provider, ProviderKind::Gmail);
        assert!(r.oauth.is_some());
        assert_eq!(r.imap.port, 993);
        assert_eq!(r.smtp.port, 465);
    }

    #[test]
    fn icloud_preset_omits_oauth() {
        let r = resolve("user@icloud.com").unwrap();
        assert_eq!(r.provider, ProviderKind::ICloud);
        assert!(r.oauth.is_none());
    }

    #[test]
    fn unknown_domain_errors_pending_phase3() {
        assert!(resolve("user@unknown-provider.example").is_err());
    }
}
