//! macOS Keychain wrapper. OAuth access + refresh tokens never touch
//! disk in plaintext — they live in `kSecClassGenericPassword` items,
//! and `mail.db` / SurrealDB only carry the opaque `keychain_ref`
//! string we generate here.
//!
//! `keychain_ref` is the *account* part of the Keychain item:
//!
//!   service = "com.clome.app.mail"
//!   account = keychain_ref         ← unique per email account
//!   data    = JSON { access, refresh, expiry } as UTF-8 bytes
//!
//! `security-framework` is sync; we hop through `spawn_blocking` so a
//! Keychain prompt (first-write per binary signing) doesn't pin the
//! Tauri command thread.

use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};
use serde::{Deserialize, Serialize};

const SERVICE: &str = "com.clome.app.mail";

/// Persisted token bundle. We bundle access + refresh together so a
/// single Keychain access (and prompt) covers both reads.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct TokenBundle {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix-second timestamp at which `access_token` stops working.
    /// `None` means the provider didn't tell us (assume short-lived).
    pub expires_at: Option<i64>,
    /// Provider-specific marker so the OAuth refresher knows which
    /// endpoint to hit without rejoining account metadata.
    pub provider: String,
}

/// Generate a fresh `keychain_ref`. Format = `mail-<uuid v4>` so logs
/// stay readable without leaking the email address.
pub fn new_ref() -> String {
    format!("mail-{}", uuid::Uuid::new_v4())
}

pub async fn store(keychain_ref: &str, bundle: &TokenBundle) -> Result<(), String> {
    let payload = serde_json::to_vec(bundle)
        .map_err(|e| format!("keychain serialize: {e}"))?;
    let kref = keychain_ref.to_string();
    tokio::task::spawn_blocking(move || {
        set_generic_password(SERVICE, &kref, &payload)
            .map_err(|e| format!("keychain set ({SERVICE}/{kref}): {e}"))
    })
    .await
    .map_err(|e| format!("keychain store spawn: {e}"))?
}

pub async fn load(keychain_ref: &str) -> Result<TokenBundle, String> {
    let kref = keychain_ref.to_string();
    let bytes = tokio::task::spawn_blocking(move || {
        get_generic_password(SERVICE, &kref)
            .map_err(|e| format!("keychain get ({SERVICE}/{kref}): {e}"))
    })
    .await
    .map_err(|e| format!("keychain load spawn: {e}"))??;
    serde_json::from_slice::<TokenBundle>(&bytes)
        .map_err(|e| format!("keychain deserialize: {e}"))
}

pub async fn delete(keychain_ref: &str) -> Result<(), String> {
    let kref = keychain_ref.to_string();
    tokio::task::spawn_blocking(move || {
        delete_generic_password(SERVICE, &kref)
            .map_err(|e| format!("keychain delete ({SERVICE}/{kref}): {e}"))
    })
    .await
    .map_err(|e| format!("keychain delete spawn: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    // Round-trip test gated behind an env flag — running it
    // unattended on CI would prompt for Keychain access. Run locally
    // with `MAIL_KEYCHAIN_TEST=1 cargo test -p clome mail::keychain`.
    #[tokio::test]
    async fn round_trip() {
        if std::env::var("MAIL_KEYCHAIN_TEST").is_err() {
            return;
        }
        let kref = new_ref();
        let bundle = TokenBundle {
            access_token: "at-test".into(),
            refresh_token: Some("rt-test".into()),
            expires_at: Some(1_700_000_000),
            provider: "gmail".into(),
        };
        store(&kref, &bundle).await.expect("store");
        let loaded = load(&kref).await.expect("load");
        assert_eq!(loaded.access_token, "at-test");
        assert_eq!(loaded.refresh_token.as_deref(), Some("rt-test"));
        delete(&kref).await.expect("delete");
    }
}
