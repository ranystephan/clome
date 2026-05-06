//! On-disk store for raw RFC 822 messages and attachment blobs.
//!
//! Layout (mirrors a Maildir, simpler):
//!   <root>/                            ← MailDb::root()
//!     <account-id>/
//!       <folder-slug>/
//!         <uid>.eml
//!         <uid>.<content-id>.bin       ← attachment blobs (lazy)
//!
//! `<folder-slug>` is the IMAP folder name with `/` replaced by `__`
//! and any other illegal-on-APFS characters URL-encoded — IMAP allows
//! `/` as hierarchy separator but on disk we want a flat directory
//! tree per account.

use std::path::{Path, PathBuf};

use sha2::Digest;
use tokio::fs;
use tokio::io::AsyncWriteExt;

/// Compose the filesystem path for an .eml file. Slot it under the
/// maildir root rather than the account row's home so backup utilities
/// see one tree, not many.
pub fn eml_path(root: &Path, account_id: &str, folder: &str, uid: u32) -> PathBuf {
    root.join(sanitize_id(account_id))
        .join(sanitize_folder(folder))
        .join(format!("{uid}.eml"))
}

/// Same scheme for attachment blobs. `content_id` is whatever the MIME
/// part announced (with surrounding `<>` stripped) or, when missing, a
/// stable hash of the part filename + index. The store doesn't care
/// which — only that callers always pass the same one for the same
/// part.
pub fn attachment_path(
    root: &Path,
    account_id: &str,
    folder: &str,
    uid: u32,
    content_id: &str,
) -> PathBuf {
    root.join(sanitize_id(account_id))
        .join(sanitize_folder(folder))
        .join(format!("{uid}.{}.bin", sanitize_content_id(content_id)))
}

/// Atomic write: bytes land in `<path>.tmp`, then rename onto the
/// final name. APFS guarantees rename is atomic within the same
/// volume, which is the only place we ever store mail.
pub async fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut f = fs::File::create(&tmp)
            .await
            .map_err(|e| format!("create {}: {e}", tmp.display()))?;
        f.write_all(bytes)
            .await
            .map_err(|e| format!("write {}: {e}", tmp.display()))?;
        f.flush()
            .await
            .map_err(|e| format!("flush {}: {e}", tmp.display()))?;
    }
    fs::rename(&tmp, path)
        .await
        .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))?;
    Ok(())
}

/// SHA-256 of the bytes, hex-encoded. Stored on `message.eml_sha256`
/// at write time and re-checked on read so a corrupted .eml surfaces
/// as a verifiable failure (versus quietly returning bogus body bytes
/// to the renderer).
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = sha2::Sha256::new();
    hasher.update(bytes);
    hex_encode(&hasher.finalize())
}

/// Read .eml, verify SHA-256 against `expected_hex` if provided.
pub async fn read_verified(path: &Path, expected_hex: Option<&str>) -> Result<Vec<u8>, String> {
    let bytes = fs::read(path)
        .await
        .map_err(|e| format!("read {}: {e}", path.display()))?;
    if let Some(expected) = expected_hex {
        let actual = sha256_hex(&bytes);
        if actual != expected {
            return Err(format!(
                "sha256 mismatch for {}: expected {expected}, got {actual}",
                path.display()
            ));
        }
    }
    Ok(bytes)
}

fn sanitize_id(id: &str) -> String {
    // Account ids come from SurrealDB Things which are already
    // ASCII-safe, but defence in depth: drop anything not in the
    // allowlist so a future id format can't escape via `..`.
    id.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect()
}

fn sanitize_folder(folder: &str) -> String {
    let mut out = String::with_capacity(folder.len());
    for ch in folder.chars() {
        match ch {
            '/' => out.push_str("__"),
            // Disallow path-traversal triggers and APFS-forbidden chars.
            '\0' | ':' => out.push('_'),
            // Spaces are legal on APFS; encode for consistency.
            ' ' => out.push('_'),
            c if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') => out.push(c),
            other => {
                // Percent-encode anything else so weird Unicode folder
                // names round-trip without filesystem lossiness.
                let mut buf = [0u8; 4];
                for byte in other.encode_utf8(&mut buf).as_bytes() {
                    out.push_str(&format!("%{:02X}", byte));
                }
            }
        }
    }
    out
}

fn sanitize_content_id(cid: &str) -> String {
    cid.chars()
        .filter_map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                Some(c)
            } else {
                None
            }
        })
        .collect::<String>()
        // Empty after sanitisation? fall back to a placeholder so the
        // path stays predictable.
        .pipe(|s| if s.is_empty() { "noid".into() } else { s })
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

// Tiny method-chain helper to keep `sanitize_content_id` linear.
trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}
impl<T> Pipe for T {}
