use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

static TERMINAL_EVENT_APP: OnceLock<AppHandle> = OnceLock::new();
static META_TX: OnceLock<Sender<MetaJob>> = OnceLock::new();

struct MetaJob {
    tab_id: String,
    title: Option<String>,
    cwd: Option<String>,
    running: bool,
    exit_code: Option<i16>,
    duration_ms: Option<u64>,
}

pub fn install_terminal_event_emitter(app: AppHandle) {
    let _ = TERMINAL_EVENT_APP.set(app.clone());
    // Single worker thread serializes metadata processing. Coalesces by
    // tab_id within a 30ms window so a burst of identical title escapes
    // collapses to one Tauri emit + one git_info lookup per pane.
    META_TX.get_or_init(|| {
        let (tx, rx) = channel::<MetaJob>();
        thread::spawn(move || {
            let coalesce = Duration::from_millis(30);
            loop {
                let Ok(first) = rx.recv() else { return };
                let mut latest: HashMap<String, MetaJob> = HashMap::new();
                latest.insert(first.tab_id.clone(), first);
                let deadline = Instant::now() + coalesce;
                while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
                    match rx.recv_timeout(remaining) {
                        Ok(job) => {
                            latest.insert(job.tab_id.clone(), job);
                        }
                        Err(_) => break,
                    }
                }
                let state = app.state::<TerminalNativeState>();
                for (_, job) in latest.drain() {
                    if state.is_closed(&job.tab_id) {
                        continue;
                    }
                    let snapshot = terminal_snapshot_from_parts(
                        &state,
                        job.tab_id,
                        job.title,
                        job.cwd,
                        job.running,
                        job.exit_code,
                        job.duration_ms,
                    );
                    let _ = app.emit("terminal:metadata", snapshot);
                }
            }
        });
        tx
    });
}

#[derive(Default)]
pub struct TerminalNativeState {
    latest_generation: AtomicU64,
    closed_tabs: Mutex<HashSet<String>>,
    git_cache: Mutex<HashMap<String, GitCacheEntry>>,
}

struct GitCacheEntry {
    at: Instant,
    info: Option<GitInfo>,
}

impl TerminalNativeState {
    fn observe_generation(&self, generation: u64) {
        let mut current = self.latest_generation.load(Ordering::SeqCst);
        while generation > current {
            match self.latest_generation.compare_exchange(
                current,
                generation,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break,
                Err(next) => current = next,
            }
        }
    }

    fn is_stale(&self, generation: u64) -> bool {
        generation < self.latest_generation.load(Ordering::SeqCst)
    }

    fn reset_generation(&self) {
        self.latest_generation.store(0, Ordering::SeqCst);
    }

    fn is_closed(&self, tab_id: &str) -> bool {
        self.closed_tabs
            .lock()
            .map(|closed| closed.contains(tab_id))
            .unwrap_or(true)
    }

    fn close_tab(&self, tab_id: &str) {
        if let Ok(mut closed) = self.closed_tabs.lock() {
            closed.insert(tab_id.to_string());
        }
    }

    fn git_info(&self, cwd: &str) -> Option<GitInfo> {
        let now = Instant::now();
        if let Ok(cache) = self.git_cache.lock() {
            if let Some(entry) = cache.get(cwd) {
                if now.duration_since(entry.at) < Duration::from_secs(2) {
                    return entry.info.clone();
                }
            }
        }

        let info = read_git_info(cwd);
        if let Ok(mut cache) = self.git_cache.lock() {
            cache.insert(
                cwd.to_string(),
                GitCacheEntry {
                    at: now,
                    info: info.clone(),
                },
            );
        }
        info
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitInfo {
    branch: String,
    dirty: bool,
    repo_root: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSnapshot {
    tab_id: String,
    title: Option<String>,
    display_title: String,
    cwd: Option<String>,
    path_label: Option<String>,
    git: Option<GitInfo>,
    running: bool,
    exit_code: Option<i16>,
    duration_ms: Option<u64>,
}

#[no_mangle]
pub extern "C" fn clome_terminal_focus_event(tab_id: *const std::ffi::c_char) {
    let Some(tab_id) = cstr_to_string(tab_id) else {
        return;
    };
    let Some(app) = TERMINAL_EVENT_APP.get().cloned() else {
        return;
    };
    // Called from main thread (Swift mouseDown). Emit off-thread so any
    // IPC backpressure can't stall the UI runloop.
    std::thread::spawn(move || {
        let _ = app.emit("terminal:focus", tab_id);
    });
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalShortcutPayload {
    tab_id: String,
    shortcut: String,
}

#[no_mangle]
pub extern "C" fn clome_terminal_shortcut_event(
    tab_id: *const std::ffi::c_char,
    shortcut: *const std::ffi::c_char,
) {
    let Some(tab_id) = cstr_to_string(tab_id) else {
        return;
    };
    let Some(shortcut) = cstr_to_string(shortcut) else {
        return;
    };
    let Some(app) = TERMINAL_EVENT_APP.get().cloned() else {
        return;
    };
    std::thread::spawn(move || {
        let _ = app.emit("terminal:shortcut", TerminalShortcutPayload {
            tab_id,
            shortcut,
        });
    });
}

#[no_mangle]
pub extern "C" fn clome_terminal_metadata_event(
    tab_id: *const std::ffi::c_char,
    title: *const std::ffi::c_char,
    cwd: *const std::ffi::c_char,
    running: u8,
    exit_code: i16,
    duration_ns: u64,
) {
    let Some(tab_id) = cstr_to_string(tab_id) else {
        return;
    };
    let Some(tx) = META_TX.get() else {
        return;
    };
    // Hand off to worker thread. No spawn-per-event, no main-thread block.
    let _ = tx.send(MetaJob {
        tab_id,
        title: cstr_to_string(title),
        cwd: cstr_to_string(cwd),
        running: running != 0,
        exit_code: (exit_code >= 0).then_some(exit_code),
        duration_ms: (duration_ns > 0).then_some(duration_ns / 1_000_000),
    });
}

#[cfg(target_os = "macos")]
extern "C" {
    fn clome_ghostty_show(
        ns_window: *mut std::ffi::c_void,
        tab_id: *const std::ffi::c_char,
        cwd: *const std::ffi::c_char,
        resources_root: *const std::ffi::c_char,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        focus: bool,
    ) -> bool;
    fn clome_ghostty_hide(tab_id: *const std::ffi::c_char);
    fn clome_ghostty_close(tab_id: *const std::ffi::c_char);
    fn clome_ghostty_hide_all();
    fn clome_ghostty_set_overlay_clip(
        has_rect: bool,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    );
    fn clome_ghostty_install_app_shortcuts();
    fn clome_ghostty_prewarm(resources_root: *const std::ffi::c_char);
    fn clome_window_set_traffic_lights_hidden(
        ns_window: *mut std::ffi::c_void,
        hidden: bool,
    );
    fn clome_ghostty_snapshot(
        tab_id: *const std::ffi::c_char,
        title: *mut std::ffi::c_char,
        title_capacity: usize,
        cwd: *mut std::ffi::c_char,
        cwd_capacity: usize,
        running: *mut u8,
        exit_code: *mut i16,
        duration_ns: *mut u64,
    ) -> bool;
}

#[tauri::command]
pub fn terminal_native_show(
    window: tauri::Window,
    state: tauri::State<'_, TerminalNativeState>,
    tab_id: String,
    cwd: Option<String>,
    rect: TerminalRect,
    focus: bool,
    generation: u64,
) -> Result<bool, String> {
    if state.is_stale(generation) || state.is_closed(&tab_id) {
        return Ok(false);
    }
    if rect.width < 8.0 || rect.height < 8.0 {
        return Ok(false);
    }
    state.observe_generation(generation);

    #[cfg(target_os = "macos")]
    {
        let ns_window = window.ns_window().map_err(|e| e.to_string())?;
        let tab_id = CString::new(tab_id).map_err(|_| "tab id contains NUL".to_string())?;
        let cwd = CString::new(cwd.unwrap_or_default())
            .map_err(|_| "terminal cwd contains NUL".to_string())?;
        let resources_root = CString::new(ghostty_resources_root().display().to_string())
            .map_err(|_| "ghostty resources path contains NUL".to_string())?;
        let ok = unsafe {
            clome_ghostty_show(
                ns_window,
                tab_id.as_ptr(),
                cwd.as_ptr(),
                resources_root.as_ptr(),
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                focus,
            )
        };
        Ok(ok)
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, tab_id, cwd, rect, focus, generation);
        Err("native Ghostty terminal is only available on macOS".into())
    }
}

#[tauri::command]
pub fn terminal_native_hide(
    state: tauri::State<'_, TerminalNativeState>,
    tab_id: String,
    generation: Option<u64>,
) -> Result<(), String> {
    if let Some(generation) = generation {
        state.observe_generation(generation);
    }

    #[cfg(target_os = "macos")]
    {
        let tab_id = CString::new(tab_id).map_err(|_| "tab id contains NUL".to_string())?;
        unsafe { clome_ghostty_hide(tab_id.as_ptr()) };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (tab_id, generation);
        Ok(())
    }
}

#[tauri::command]
pub fn terminal_native_close(
    state: tauri::State<'_, TerminalNativeState>,
    tab_id: String,
    generation: Option<u64>,
) -> Result<(), String> {
    if let Some(generation) = generation {
        state.observe_generation(generation);
    }
    state.close_tab(&tab_id);

    #[cfg(target_os = "macos")]
    {
        let tab_id = CString::new(tab_id).map_err(|_| "tab id contains NUL".to_string())?;
        unsafe { clome_ghostty_close(tab_id.as_ptr()) };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (tab_id, generation);
        Ok(())
    }
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OverlayClipRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Sets a rectangular clip (in WebView coords, top-left origin) that
/// every Ghostty surface excludes from its rendering — HTML overlays
/// can paint inside that rect without the surface drawing over them.
/// Pass `None` to clear. The native CALayer mask is required because
/// surfaces are sibling NSViews to the WebView; CSS z-index can't
/// influence their compositing order.
#[tauri::command]
pub fn terminal_native_set_overlay_clip(
    rect: Option<OverlayClipRect>,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let (has, x, y, w, h) = match rect {
            Some(r) => (true, r.x, r.y, r.width, r.height),
            None => (false, 0.0, 0.0, 0.0, 0.0),
        };
        unsafe { clome_ghostty_set_overlay_clip(has, x, y, w, h) };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = rect;
        Ok(())
    }
}

/// Installs a process-wide NSEvent local monitor that intercepts
/// app-level shortcuts (Cmd+K, Cmd+Shift+K, Cmd+,) before they reach
/// any focused NSView — including ghostty surfaces, which would
/// otherwise eat them.
#[tauri::command]
pub fn terminal_native_install_app_shortcuts() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        unsafe { clome_ghostty_install_app_shortcuts() };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Ok(())
    }
}

/// Pre-warms ghostty (config load, GPU pipeline, font atlas) so the
/// first user-visible terminal attach is sub-frame instead of taking
/// hundreds of milliseconds.
#[tauri::command]
pub fn terminal_native_prewarm() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let resources = std::ffi::CString::new(ghostty_resources_root().display().to_string())
            .map_err(|_| "ghostty resources path contains NUL".to_string())?;
        unsafe { clome_ghostty_prewarm(resources.as_ptr()) };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Ok(())
    }
}

/// Forwarded from Swift's app-shortcut NSEvent monitor. Emits a Tauri
/// event ("app:shortcut") with the shortcut code so the JS side can
/// route to the right handler.
#[no_mangle]
pub extern "C" fn clome_app_shortcut_event(shortcut: *const std::ffi::c_char) {
    if shortcut.is_null() {
        return;
    }
    let code = unsafe { CStr::from_ptr(shortcut) }
        .to_string_lossy()
        .into_owned();
    if let Some(app) = TERMINAL_EVENT_APP.get() {
        let _ = app.emit("app:shortcut", code);
    }
}

/// Toggles the macOS traffic-light window buttons (close / minimize /
/// zoom). Used by the sidebar peek so the floating panel isn't visually
/// overlapped by the native chrome.
#[tauri::command]
pub fn window_set_traffic_lights_hidden(
    window: tauri::Window,
    hidden: bool,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let ns_window = window.ns_window().map_err(|e| e.to_string())?;
        unsafe { clome_window_set_traffic_lights_hidden(ns_window, hidden) };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, hidden);
        Ok(())
    }
}

/// Resets the native generation epoch. Frontend calls this once on
/// boot — without it, a webview reload keeps the live Rust state but
/// resets the JS counter to 0, so every subsequent `terminal_native_show`
/// fails the staleness check until the counter catches up to the prior
/// peak. That manifests as terminals stuck on "starting terminal..." for
/// minutes after a reload.
#[tauri::command]
pub fn terminal_native_reset_generation(
    state: tauri::State<'_, TerminalNativeState>,
) -> Result<(), String> {
    state.reset_generation();
    Ok(())
}

#[tauri::command]
pub fn terminal_native_hide_all(
    state: tauri::State<'_, TerminalNativeState>,
    generation: u64,
) -> Result<(), String> {
    if state.is_stale(generation) {
        return Ok(());
    }
    state.observe_generation(generation);

    #[cfg(target_os = "macos")]
    {
        unsafe { clome_ghostty_hide_all() };
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = generation;
        Ok(())
    }
}

#[tauri::command]
pub fn terminal_native_snapshot(
    state: tauri::State<'_, TerminalNativeState>,
    tab_id: String,
) -> Result<TerminalSnapshot, String> {
    if state.is_closed(&tab_id) {
        return Ok(empty_snapshot(tab_id));
    }

    #[cfg(target_os = "macos")]
    let native = {
        let tab_id_c = CString::new(tab_id.clone()).map_err(|_| "tab id contains NUL".to_string())?;
        let mut title = vec![0_i8; 512];
        let mut cwd = vec![0_i8; 2048];
        let mut running = 0_u8;
        let mut exit_code = -1_i16;
        let mut duration_ns = 0_u64;
        let ok = unsafe {
            clome_ghostty_snapshot(
                tab_id_c.as_ptr(),
                title.as_mut_ptr(),
                title.len(),
                cwd.as_mut_ptr(),
                cwd.len(),
                &mut running,
                &mut exit_code,
                &mut duration_ns,
            )
        };
        if ok {
            Some((
                cstr_to_string(title.as_ptr()),
                cstr_to_string(cwd.as_ptr()),
                running != 0,
                (exit_code >= 0).then_some(exit_code),
                (duration_ns > 0).then_some(duration_ns / 1_000_000),
            ))
        } else {
            None
        }
    };

    #[cfg(not(target_os = "macos"))]
    let native: Option<(Option<String>, Option<String>, bool, Option<i16>, Option<u64>)> = None;

    let (title, cwd, running, exit_code, duration_ms) =
        native.unwrap_or((None, None, false, None, None));
    Ok(terminal_snapshot_from_parts(
        &state,
        tab_id,
        title,
        cwd,
        running,
        exit_code,
        duration_ms,
    ))
}

fn terminal_snapshot_from_parts(
    state: &TerminalNativeState,
    tab_id: String,
    title: Option<String>,
    cwd: Option<String>,
    running: bool,
    exit_code: Option<i16>,
    duration_ms: Option<u64>,
) -> TerminalSnapshot {
    let git = cwd.as_deref().and_then(|path| state.git_info(path));
    let path_label = cwd.as_deref().map(compact_path);
    let display_title = display_title(title.as_deref(), cwd.as_deref(), git.as_ref());

    TerminalSnapshot {
        tab_id,
        title,
        display_title,
        cwd,
        path_label,
        git,
        running,
        exit_code,
        duration_ms,
    }
}

#[cfg(target_os = "macos")]
fn ghostty_resources_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources")
}

fn empty_snapshot(tab_id: String) -> TerminalSnapshot {
    TerminalSnapshot {
        tab_id,
        title: None,
        display_title: "terminal".into(),
        cwd: None,
        path_label: None,
        git: None,
        running: false,
        exit_code: None,
        duration_ms: None,
    }
}

fn cstr_to_string(ptr: *const std::ffi::c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let value = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn read_git_info(cwd: &str) -> Option<GitInfo> {
    let cwd_path = Path::new(cwd);
    if !cwd_path.is_dir() {
        return None;
    }

    let repo_root = run_git(cwd, &["rev-parse", "--show-toplevel"])?;
    let mut branch = run_git(cwd, &["rev-parse", "--abbrev-ref", "HEAD"])?;
    if branch == "HEAD" {
        branch = run_git(cwd, &["rev-parse", "--short", "HEAD"]).unwrap_or(branch);
    }
    let dirty = run_git(cwd, &["status", "--porcelain", "--untracked-files=no"])
        .map(|status| !status.is_empty())
        .unwrap_or(false);

    Some(GitInfo {
        branch,
        dirty,
        repo_root,
    })
}

fn run_git(cwd: &str, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn compact_path(path: &str) -> String {
    if let Ok(home) = std::env::var("HOME") {
        if let Some(rest) = path.strip_prefix(&home) {
            if rest.is_empty() {
                return "~".into();
            }
            if rest.starts_with('/') {
                return format!("~{rest}");
            }
        }
    }
    path.to_string()
}

fn display_title(title: Option<&str>, cwd: Option<&str>, git: Option<&GitInfo>) -> String {
    let cleaned = title
        .map(|value| value.trim())
        .filter(|value| !value.is_empty());

    if let Some(title) = cleaned {
        if title_looks_process_like(title, cwd) {
            return title.to_string();
        }
    }

    if let Some(git) = git {
        if let Some(name) = Path::new(&git.repo_root).file_name().and_then(|n| n.to_str()) {
            return name.to_string();
        }
    }

    if let Some(cwd) = cwd {
        if let Some(name) = Path::new(cwd).file_name().and_then(|n| n.to_str()) {
            if !name.is_empty() {
                return name.to_string();
            }
        }
    }

    cleaned.unwrap_or("terminal").to_string()
}

fn title_looks_process_like(title: &str, cwd: Option<&str>) -> bool {
    let lower = title.to_lowercase();
    let shellish = matches!(
        lower.as_str(),
        "terminal" | "zsh" | "bash" | "fish" | "sh" | "login" | "shell"
    );
    if shellish {
        return false;
    }
    if lower.contains('@') && lower.contains(':') {
        return false;
    }
    if title.starts_with('/') || title.starts_with('~') {
        return false;
    }
    if let Some(cwd) = cwd {
        if title.contains(cwd) {
            return false;
        }
        if let Some(name) = Path::new(cwd).file_name().and_then(|n| n.to_str()) {
            if lower == name.to_lowercase() {
                return false;
            }
        }
    }
    true
}
