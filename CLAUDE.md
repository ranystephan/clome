# Clome - AI-Native Development Environment

## Project Overview
Clome is a native, GPU-accelerated development environment built for the agentic era.
Swift + AppKit for macOS UI, Zig (libghostty) for terminal rendering, Metal for GPU acceleration.

## Current Status: Phase 1 - Editor Core (Complete) → Ready for Phase 2

### Phase 0 - Foundation (Complete)

**Core App Shell**
- Native macOS AppKit application with transparent titlebar, dark theme (#0E0E12)
- Full menu bar: File (Open, New Workspace/Tab/Browser, Close), View (Split, Sidebar), Window
- Rounded corners (14px), shadow, visual effect view (HUD window)
- Sidebar modes: pinned/compact/hidden with smooth animations, hover auto-reveal (6px edge trigger)
- Session state persistence via SQLite (~/.../Clome/session.db)
- Auto-saves every 30s + on quit, restores window position on launch

**libghostty Integration**
- Built from source (vendor/ghostty submodule), linked as static library
- Full terminal emulation with Metal GPU rendering
- Keyboard/mouse input, clipboard, config from ~/.config/ghostty/config
- OSC support: title, working directory, bell, notifications, command finished
- Terminal activity monitor: state tracking, output preview caching, command detection
- Program detection (vim, node, Claude Code, etc.) with working directory tracking
- Claude Code context bridge: reads context window usage from /tmp/clome-claude-context

**Workspace System (Window → Workspace → Pane → Surface)**
- WorkspaceManager, Workspace, PaneContainerView (recursive binary split tree)
- SurfacePane with TabBarView (multi-tab per pane)
- Split navigation via coordinate geometry

**Sidebar**
- Vertical workspace list, active indicator, hover effects, SF Symbol icons
- Git branch detection, working directory display, notification badges

**Browser Panel** - WKWebView with nav bar, send-to-context support

**Keyboard Navigation** - ⌘⌥arrows splits, ⌘1-9 workspaces, ⌘⇧[] next/prev

**Notification System** - Per-workspace unread counts, desktop notifications, sidebar badges

**Socket API** - Unix socket at /tmp/clome-{pid}.sock, JSON protocol, 7 commands

**Session Restore** - SQLite persistence for window frame + workspaces

### Phase 1 - Editor Core (Complete)

**Rope Data Structure** (`Rope.swift`)
- Balanced binary tree of text chunks for O(log n) insert/delete
- Max leaf size: 512 chars, auto-rebalances when depth exceeds 2*log2(leafCount)
- Operations: insert, delete, replace, substring, character-at, line-at, lineIndex, lineStartOffset
- Split/merge for efficient editing

**Text Buffer** (`TextBuffer.swift`)
- High-level wrapper around Rope with undo/redo (500 history)
- Multi-cursor support: `cursors` array with primary `cursor` computed property
- Multi-cursor editing: `insertAtAllCursors`, `backspaceAll`, `forwardDeleteAll`
- Cursor add/collapse/deduplication, processes cursors in reverse offset order
- File I/O: open, save, saveAs, reload
- Language detection from file extension (30+ languages)
- Operations: insertAtCursor, backspace, forwardDelete, position↔offset conversion

**Editor View** (`EditorView.swift`)
- Custom CoreText-rendered code editor NSView
- Line numbers in gutter (50px), current line highlight
- Cursor with 500ms blink timer
- Selection rendering (blue highlight)
- Scroll wheel support with visible line range optimization
- Large file optimizations: adaptive rendering thresholds at 50K and 200K lines
- Scrollbar with fade animation (6px width, 30px min height)
- Keyboard: arrows, shift-select, ⌘Z/⌘⇧Z undo/redo, ⌘S save, ⌘A select all
- Mouse: click to position cursor, drag to select
- Regex-based syntax highlighting with per-language keyword lists (Swift, Rust, Python, JS/TS, Go, C/C++, Zig, Java, Kotlin, C#)
- Colors: purple keywords, orange strings, gray comments, yellow numbers, cyan types
- Conforms to `LSPClientDelegate` for diagnostic notifications

**Find & Replace** (`FindBarView.swift`, `EditorView.swift`)
- FindBarView: search/replace text fields, prev/next nav, case/regex toggles, match count
- Plain text and regex search modes
- All-match amber highlighting with current match brighter
- Replace current / replace all with reverse-order offset preservation
- Keys: ⌘F find, ⌘H find+replace, Escape dismiss, ⌘G/⌘⇧G next/prev match

**LSP Diagnostics Display** (`EditorView.swift`)
- Parses `publishDiagnostics` notifications into `[LSPDiagnostic]`
- Squiggly underlines: sine wave CGPath (red=error, yellow=warning, blue=info)
- Gutter icons: `exclamationmark.circle.fill` (error) and `exclamationmark.triangle.fill` (warning)
- Debounced `didChangeDocument` notifications (300ms) after buffer edits
- Tooltip on hover over diagnostic ranges via tracking areas

**Go-to-Definition** (`EditorView.swift`, `ProjectPanel.swift`)
- `EditorViewNavigationDelegate` protocol for cross-file navigation
- ⌘+Click: go to definition at clicked position
- F12: go to definition at cursor position
- Handles LSP `Location`, `Location[]`, and `LocationLink[]` response formats
- Same-file: moves cursor + scrolls. Different file: delegates to ProjectPanel
- `navigateTo(line:column:)` for programmatic cursor positioning

**LSP Completions UI** (`CompletionPopupView.swift`, `EditorView.swift`)
- `CompletionItem` struct with label, kind, detail, insertText, filterText
- Popup view: dark bg, max 10 visible rows, scrollable, shadow
- Per-kind SF Symbol icons with semantic colors (green functions, cyan variables, yellow types)
- Trigger: 150ms debounce after character input, calls `lspClient.completion()`
- Arrow keys navigate, Enter/Tab accept, Escape dismiss, typing filters
- Accept: replaces token from start to cursor with `insertText`

**Multi-Cursor Editing** (`TextBuffer.swift`, `EditorView.swift`)
- `cursors: [CursorState]` array with `cursor` computed property for backward compat
- ⌘+Option+Click: add cursor at click position
- ⌘D: find next occurrence of selection and add cursor with selection
- Escape: collapse to single cursor
- All edit operations (insert, backspace, delete) process cursors in reverse offset order
- Automatic offset adjustment for subsequent cursors after each edit
- Cursor deduplication after operations

**Tree-sitter Integration** (`TreeSitterHighlighter.swift`, `project.yml`)
- SwiftTreeSitter SPM package dependency configured in project.yml
- `TreeSitterHighlighter` class with language-aware parser interface
- `TokenType` enum mapping capture names to editor color scheme
- Incremental parsing API (`applyEdit`) for efficient re-highlighting
- Stub implementation: falls back to regex highlighting until grammars are bundled
- Architecture ready for: parse → query highlights.scm → map to TokenType

**Minimap** (`MinimapView.swift`, `EditorPanel.swift`)
- 80px wide view on right edge of editor area
- Renders scaled-down file: colored rectangles for syntax tokens (not glyphs)
- Adaptive line height: 2px (normal), 1.5px (>2000 lines), 1px (>5000 lines)
- Heuristic coloring: comments (gray), strings (orange), keywords (purple), default (dim)
- Visible area indicator: semi-transparent white rectangle showing current viewport
- Click/drag to scroll: converts click Y to line number, scrolls editor
- Cached bitmap rendering, invalidated on buffer changes

**Editor Panel** (`EditorPanel.swift`)
- Wraps EditorView with toolbar showing filename, dirty indicator (orange dot), language label
- Status bar: git branch, cursor position, selection info, modified indicator, encoding, line ending, line count, language
- FindBar integration: shows/hides between toolbar and editor via notifications
- Minimap integration: MinimapView as sibling view on right edge (toggle button)

**LSP Client** (`LSPClient.swift`)
- JSON-RPC 2.0 over stdin/stdout
- Methods: initialize, textDocument/didOpen, didChange, didClose, completion, hover, definition, references
- Response handling with async/await
- Auto-discovers language servers: sourcekit-lsp, pyright, typescript-language-server, rust-analyzer, gopls, clangd, zls
- Diagnostic notifications routed to delegate

**File Watcher** (`FileWatcher.swift`)
- FSEvents-based directory watcher for detecting agent file modifications
- DispatchSource-based single file watcher (write/rename/delete events)
- Auto-reloads buffer when file changes externally (if not dirty)

**Diff View** (`DiffView.swift`)
- Unified diff display with LCS-based diff computation
- Color-coded: green additions, red deletions, gray context
- Accept/Reject toolbar buttons with callbacks
- Monospaced text rendering

**LaTeX Support** (`LatexCompiler.swift`, `EditorView.swift`, `EditorPanel.swift`)
- Full syntax highlighting for .tex files: \commands (purple keywords, green functions), math mode ($...$), comments (%), environments, arguments
- BibTeX (.bib) syntax highlighting with @entry types, field names, % comments
- LaTeX compilation to PDF via pdflatex, xelatex, or lualatex (auto-discovers installed engines)
- Compile button in status bar for .tex files, keyboard shortcut ⌘⇧B
- Auto-saves before compiling, runs 2 passes for references/TOC
- Compiled PDF opens automatically in PDFPanel tab
- Error/warning parsing from LaTeX log with alert display on failure
- LSP support via texlab (auto-discovered at /usr/local/bin/texlab)
- File icons: teal "TeX" for .tex/.sty/.cls, gold "bib" for .bib
- Language registered in LanguageSupportView with highlighting status

**PDF Panel** (`PDFPanel.swift`)
- PDFKit-based viewer, auto-scale, continuous scroll
- Toolbar: prev/next page, zoom in/out, fit width/page, display mode toggle
- Outline sidebar support, find bar integration
- Status bar: page number, zoom level, file size, page count
- Dark themed

**Project Panel** (`ProjectPanel.swift`)
- Manages a directory with multiple open editor sub-tabs
- OpenFile struct supporting EditorPanel, NotebookPanel, or PDFPanel
- Tab bar for switching between open files with dirty state indicators
- Auto-detects file type on open (PDF vs code vs notebook)
- Conforms to `EditorViewNavigationDelegate` for go-to-definition across files
- Conforms to `FileExplorerDelegate` for sidebar file selection

**File Explorer** (`FileExplorerView.swift`, `FileTreeNode.swift`)
- NSOutlineView-based tree view of project directory structure
- FileTreeNode: recursive directory/file model with expand/collapse, lazy loading
- FileExplorerDelegate protocol for file selection/creation callbacks
- Custom row view with active file highlighting (left accent bar)
- Inline rename/creation text field overlay
- Git status colors: modified (yellow), staged (green), untracked (dim), conflict (red)
- Context menu for new file/folder, drag-drop support
- GitStatusTracker: runs `git status --porcelain` for per-file status tracking

**File Type Icons** (`FileTypeIconProvider.swift`)
- Colorful brand-colored language icons for 20+ file types
- Rounded rectangle icons with language abbreviation, cached rendering
- Support for extensionless files (Dockerfile, Makefile, .env)

**Appearance Settings** (`AppearanceSettings.swift`)
- Shared singleton for theme colors and opacity
- Sidebar & main panel colors + opacity, colorful file icons toggle
- Persistent via SessionState, appearance change notifications

**Settings Window** (`SettingsWindowController.swift`)
- Preferences window for appearance and language support configuration

**Language Support** (`LanguageSupportView.swift`)
- Displays highlighting + LSP status for 30+ languages
- Shows installed language servers with custom LSP path configuration

**Bookmark Manager** (`BookmarkManager.swift`)
- Bookmark storage and management

**Workspace Tab Bar** (`WorkspaceTabBar.swift`)
- Tab bar for workspace-level tab switching

**Split Drop Zone** (`SplitDropZoneView.swift`)
- Visual drop zone indicators for split pane drag operations

**Menu Integration**
- ⌘O: Open File dialog (auto-detects PDF vs code)
- Opens files in EditorPanel or PDFPanel based on extension

**Jupyter Notebook Panel** (`NotebookModel.swift`, `NotebookCellView.swift`, `NotebookPanel.swift`)
- Full .ipynb JSON parsing: cells (code/markdown/raw), outputs, metadata, kernel info
- Scrollable cell list with vertical stack layout
- Per-cell UI: execution count gutter, syntax-highlighted source editor (NSTextView), output area
- Code cell syntax coloring: Python, Julia, R keyword highlighting, strings, comments, numbers, decorators
- Markdown cell coloring: headers, bold, italic, inline code, links
- Output rendering: text (stdout/stderr), images (base64 PNG/JPEG), error tracebacks with ANSI stripping
- Cell toolbar (on focus): change type, move up/down, delete, insert code/markdown below
- Notebook toolbar: kernel name, cell count, add code/markdown, clear all outputs
- Status bar: language, code/markdown cell counts, dirty state
- Cell operations: insert, delete, move, change type, clear outputs, update source
- Save/SaveAs with proper .ipynb JSON output (pretty-printed, sorted keys)
- Integrated into file open flow (.ipynb → NotebookPanel), workspace tabs, ProjectPanel file explorer
- Focus system: blue border on active cell, toolbar visibility toggle

**Kernel Execution** (`KernelManager.swift`, `PythonEnvironmentManager.swift`)
- Full Jupyter kernel execution bridge via jupyter_client + ipykernel
- Auto-provisions private Clome venv (no global install needed)
- PythonEnvironmentManager: discovers conda/mamba, virtualenv, system, pyenv environments
- Execution queue for serializing cell runs
- State machine: disconnected → settingUp → starting → idle → busy → error
- Output streaming: text, images, error tracebacks

### Phase 2 targets (Conversation Graph)
- [ ] Conversation DAG storage in SQLite
- [ ] Fork, prune, merge operations
- [ ] Visual graph renderer
- [ ] Context assembly engine
- [ ] Code ↔ conversation linking

## Build Instructions

### Prerequisites
- macOS 14.0+
- Xcode 16+ (with Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`)
- Zig 0.15.2 (`brew install zig`)
- XcodeGen (`brew install xcodegen`)

### Build libghostty (only needed once, or after updating ghostty submodule)
```bash
cd vendor/ghostty
zig build -Demit-xcframework -Doptimize=ReleaseFast
```

### Build Clome
```bash
xcodegen generate
xcodebuild -project Clome.xcodeproj -scheme Clome -configuration Debug build
```

### Run
```bash
open $(find ~/Library/Developer/Xcode/DerivedData -name "Clome.app" -type d | head -1)
```

## Architecture

### Directory Structure
```
Sources/
  Clome/
    App/
      main.swift                  - Entry point
      ClomeAppDelegate.swift      - App lifecycle, menu bar, session save/restore
      ClomeWindow.swift           - Main window: sidebar + content layout
      KeyboardNavigation.swift    - Global keyboard shortcut handler
      NotificationSystem.swift    - Notification ring system with badges
      SocketServer.swift          - Unix socket server for external automation
      AppearanceSettings.swift    - Shared theme/color settings
      SettingsWindowController.swift - Preferences window
      LanguageSupportView.swift   - Language support status + LSP config
      BookmarkManager.swift       - Bookmark storage
    Terminal/
      GhosttyAppManager.swift     - libghostty lifecycle, callbacks, config
      TerminalSurface.swift       - NSView hosting a ghostty terminal surface
      TerminalActivityMonitor.swift - Activity tracking, output preview, command detection
      ClaudeContextBridge.swift   - Claude Code context window usage bridge
    Editor/
      Rope.swift                  - Rope data structure (balanced binary tree)
      TextBuffer.swift            - Text buffer with undo/redo + multi-cursor
      EditorView.swift            - CoreText editor: rendering, input, LSP, find, completions
      EditorPanel.swift           - Editor wrapper with toolbar, find bar, minimap
      FindBarView.swift           - Find & replace bar overlay
      CompletionPopupView.swift   - LSP completion suggestions popup
      TreeSitterHighlighter.swift - Tree-sitter syntax highlighting (stub/interface)
      MinimapView.swift           - Scaled-down file overview with viewport indicator
      LSPClient.swift             - Language Server Protocol client
      FileWatcher.swift           - FSEvents/DispatchSource file monitoring
      DiffView.swift              - Unified diff display with accept/reject
      PDFPanel.swift              - PDFKit-based PDF viewer
      NotebookModel.swift         - .ipynb JSON parsing, cell/output structs, NotebookStore
      NotebookCellView.swift      - Individual notebook cell: source editor, outputs, toolbar
      NotebookPanel.swift         - Scrollable notebook panel with toolbar and status bar
      FileTreeNode.swift          - Recursive directory/file tree model + GitStatusTracker
      ProjectPanel.swift          - Project directory manager with editor tabs
      FileExplorerView.swift      - Tree view of project directory with git status
      FileTypeIconProvider.swift  - Brand-colored language icons for 20+ file types
      LatexCompiler.swift         - LaTeX → PDF compilation (pdflatex/xelatex/lualatex)
      KernelManager.swift         - Jupyter kernel execution bridge
      PythonEnvironmentManager.swift - Python environment discovery (conda, pyenv, venv)
    Workspace/
      Workspace.swift             - Single workspace with pane tree, git detection
      WorkspaceManager.swift      - Collection of workspaces
      PaneContainerView.swift     - Recursive split layout (SplitNode binary tree)
      SurfacePane.swift           - Multi-tab pane (tab bar + content)
      TabBarView.swift            - Compact tab bar UI
      WorkspaceTabBar.swift       - Workspace-level tab switching
      SplitDropZoneView.swift     - Split pane drop zone indicators
    Sidebar/
      SidebarView.swift           - Vertical workspace list with badges + git branch
    Browser/
      BrowserPanel.swift          - WKWebView browser panel with nav bar
    Config/
      SessionState.swift          - SQLite session persistence
  CGhostty/
    include/
      Clome-Bridging-Header.h     - Imports ghostty.h for Swift
    shims.c
vendor/
  ghostty/                        - Git submodule (ghostty-org/ghostty)
Resources/
  Info.plist
project.yml                       - XcodeGen project spec (includes SwiftTreeSitter SPM dep)
```

### Key Patterns
- **@MainActor**: All UI classes are MainActor-isolated for Swift 6 concurrency
- **libghostty FFI**: C callbacks via `Unmanaged<GhosttyAppManager>` bridging
- **Split Layout**: `SplitNode` indirect enum binary tree → NSSplitView hierarchies
- **Rope**: O(log n) text operations via balanced binary tree of string chunks
- **LSP**: JSON-RPC 2.0 over stdin/stdout with async/await request handling
- **Multi-Cursor**: Process edits in reverse offset order, adjust subsequent cursors by delta
- **Syntax Highlighting**: Regex-based with tree-sitter interface ready (grammars not yet bundled)
- **Find & Replace**: NSNotification-driven show/hide between EditorPanel and FindBarView
- **Minimap**: Cached bitmap rendering with heuristic syntax coloring
