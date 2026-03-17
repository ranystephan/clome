# Research Report: GUI Wrappers for Coding Agents & Multi-Agent Orchestration UX Patterns

**Date:** March 2026
**Purpose:** Inform the design of Clome as a native macOS IDE with rich GUI for CLI coding agents
**Methodology:** Web search across GitHub, product pages, blog posts, documentation, and UX pattern libraries

---

## Executive Summary

**Key Finding 1:** A wave of GUI wrappers for CLI coding agents (Claude Code, Aider, Codex) emerged in mid-2025, but all use Electron/Tauri web stacks. No native macOS (AppKit/SwiftUI) wrapper exists. This is Clome's gap to fill.

**Key Finding 2:** Parallel agent execution via git worktrees has become the standard isolation pattern. Cursor 2.0, Claude Code Desktop, and Parallel Code all use worktrees. The UX challenge is showing multiple agents' status, progress, and file changes simultaneously.

**Key Finding 3:** Conversation branching/forking is an emerging UX pattern (ChatGPT, Warp, LibreChat) but no coding IDE has deeply integrated it with code state. Clome's planned Conversation DAG (Phase 2) is ahead of the field.

**Key Finding 4:** Google's A2UI protocol (January 2026) signals an industry shift toward agents generating rich, declarative UI -- not just text responses. Clome could be an early adopter of rendering agent-generated UI components natively.

**Key Finding 5:** The state-of-the-art for showing agent progress has moved from spinners to step-by-step chain-of-thought disclosure with skeleton screens, confidence indicators, and live file-change streaming. Native GPU-rendered UIs can do this at 120fps where web-based tools cannot.

---

## 1. Existing GUI Wrappers for CLI Coding Agents

### 1.1 Claudia (claudia.so)

**Stack:** Tauri 2 + React 18 + TypeScript + Rust backend
**License:** AGPL, open-source
**Install Size:** ~600KB (uses OS-native WebView, not Electron)

**Key Features:**
- Visual project browser scanning `~/.claude/projects/`
- Session versioning with checkpoints and visual timeline
- Fork sessions from any checkpoint with diff viewer
- Usage analytics dashboard (token/cost breakdown by model, project, time)
- MCP server management UI
- CLAUDE.md inline editor with live markdown rendering
- Custom agent creation with sandboxed execution

**What Clome can learn:**
- Session checkpoint/fork is a proven UX pattern -- Clome's Conversation DAG is a superset
- Usage analytics is table-stakes for power users managing API costs
- CLAUDE.md management UI is a nice touch for agent configuration

[Source: claudia.so, 2025; blog.brightcoding.dev, 2025; webpronews.com, 2025]

### 1.2 Opcode (opcode.sh)

**Stack:** Tauri 2 + React 18 + TypeScript + Rust + SQLite
**License:** Open-source

**Key Features:**
- Visual project browser with session history and metadata
- CC Agents: custom agents with custom system prompts, background execution
- Execution history with detailed logs and performance metrics
- Timeline with branching checkpoints and diff viewer
- MCP server management with connection testing
- All data stays local (privacy-first)

**What Clome can learn:**
- Background agent execution with process isolation is essential
- Per-agent execution logs with metrics let users understand cost/performance
- Import configurations from Claude Desktop for easy migration

[Source: github.com/winfunc/opcode, 2025; opcode.sh, 2025]

### 1.3 AiderDesk (aider-desk)

**Stack:** Electron + React + TypeScript + Node.js
**License:** Open-source

**Key Features:**
- Autonomous agent mode: plans and executes complex tasks, delegates to subagents
- Memory system using LanceDB vector search for persistent project knowledge
- Git worktree support for parallel isolated development
- IDE sync plugins (IntelliJ, VSCode) for automatic context file management
- Power Tools: file ops, semantic search, grep, shell commands
- Per-task cost tracking and state persistence
- Agent transparency: shows reasoning, plans, and tool usage inline in conversation
- Skills framework for domain expertise (code review, testing, docs)

**What Clome can learn:**
- Agent transparency (showing reasoning inline) is critical for trust
- IDE sync (auto-adding active editor files to context) is a powerful UX pattern
- Subagent delegation with cost optimization is sophisticated
- Memory persistence across sessions (vector search) goes beyond checkpoint/restore

[Source: github.com/hotovo/aider-desk, 2025; hotovo.com, 2025]

### 1.4 CodePilot

**Stack:** Electron + Next.js
**Key Features:** Desktop GUI for Claude Code with visual project management
**Note:** Less feature-rich than Claudia/Opcode, more of a basic chat wrapper

[Source: github.com/op7418/CodePilot, 2025]

### 1.5 CloudCLI (Claude Code UI)

**Stack:** Web-based
**Key Feature:** Remote Claude Code sessions -- agent keeps running when you close your laptop
**What Clome can learn:** Remote/persistent agent execution is a compelling use case

[Source: github.com/siteboon/claudecodeui, 2025]

### 1.6 Gap Analysis

| Feature | Claudia | Opcode | AiderDesk | Clome Opportunity |
|---------|---------|--------|-----------|-------------------|
| Native macOS | No (Tauri) | No (Tauri) | No (Electron) | YES - Metal-accelerated |
| GPU rendering | No | No | No | YES - CoreText + Metal |
| Terminal integration | No | No | No | YES - libghostty |
| Editor integration | No | No | Partial (IDE sync) | YES - built-in editor |
| Conversation DAG | Checkpoint/fork | Checkpoint/fork | No | YES - full graph |
| Multi-agent parallel | Basic | Background agents | Worktrees | Design opportunity |
| 120fps UI | No (WebView) | No (WebView) | No (Chromium) | YES |

**Conclusion:** All existing wrappers are web-tech shells. None combine terminal + editor + agent GUI natively. Clome is uniquely positioned.

---

## 2. Multi-Agent Orchestration UIs

### 2.1 LangGraph Studio

**What it is:** The first "agent IDE" -- a desktop app for visualizing, debugging, and interacting with LangGraph agents.

**Key UX Patterns:**
- **Graph Mode:** Visualizes agent execution as a directed graph with nodes (steps) and edges (transitions). Shows which nodes are active, paused, or failed
- **Real-time streaming:** As agents execute, you see steps happening live with intermediate states
- **Time-travel debugging:** Step backward through execution history to see why an agent made a decision
- **Interrupt and edit:** Pause execution, edit agent state, then resume -- before or after any node
- **Hot reload:** Detects code changes in your editor and lets you immediately rerun nodes
- **LangSmith integration:** Full observability with traces, metrics, and production monitoring

**What Clome can learn:**
- Graph visualization of agent execution is powerful for debugging
- Time-travel (stepping through history) maps well to Conversation DAG
- Interrupt-and-edit (pause agent, modify state, resume) is an advanced power-user feature
- Hot reload between code editor and agent runtime is exactly what Clome can do natively

[Source: blog.langchain.com, 2025; mem0.ai/blog, 2025; docs.langchain.com]

### 2.2 Cursor 2.0 Parallel Agents

**Released:** October 2025

**Key UX Patterns:**
- Up to 8 parallel agents running simultaneously via git worktrees
- Each agent gets isolated worktree with independent file access
- Can run same prompt across multiple models and compare results side-by-side
- After all parallel agents finish, Cursor auto-evaluates and recommends the best solution
- Agent tabs (Cmd+T) for switching between conversations
- Resource balancing: auto-adjusts based on system capacity
- File-level conflict detection: prevents multiple agents from editing same file

**What Clome can learn:**
- Auto-evaluation of parallel results is a novel pattern (let AI pick the best)
- Side-by-side model comparison is useful for power users
- Resource management (CPU/memory balancing) matters for parallel execution
- Conflict detection at file level is essential

[Source: cursor.com/docs, 2026; forum.cursor.com, 2025-2026; blog.meetneura.ai, 2026]

### 2.3 Parallel Code

**Stack:** Electron + SolidJS + TypeScript
**What it is:** Desktop app to run Claude Code, Codex, Gemini side-by-side in isolated worktrees

**Key UX Patterns:**
- Tiled panel layout with drag-to-reorder
- Each task panel shows: terminal output, changed files list, diff viewer
- Automatic git branch + worktree per task
- Symlinks shared dependencies (node_modules) across worktrees for efficiency
- Merge workflow: review changes, merge back to main from sidebar
- Remote monitoring via QR code
- 6 visual themes
- Keyboard-first navigation

**What Clome can learn:**
- Tiled layout for parallel agents is intuitive (like tmux but richer)
- Per-task changed files + diff viewer is essential UX
- Symlinked shared dependencies is a practical optimization
- QR code for remote monitoring is creative for mobile check-ins

[Source: github.com/johannesjo/parallel-code, 2025]

### 2.4 Claude Code Agentrooms (claude-code-by-agents)

**Stack:** React + Electron frontend, Deno backend
**What it is:** Multi-agent orchestration via @mentions

**Key UX Patterns:**
- @agent-name mentions for direct routing (like Slack)
- Hub-and-spoke architecture: orchestrator coordinates local + remote agents
- File-based inter-agent communication (Agent 2 reads Agent 1's output files)
- Settings UI for configuring agents with name, description, working directory
- Sequential execution planning by orchestrator
- Supports both local (localhost ports) and remote agents (other machines)

**What Clome can learn:**
- @mention routing is natural and familiar (Slack/Teams pattern)
- Mixed local + remote agent deployment is powerful
- File-based inter-agent communication is simple but effective

[Source: github.com/baryhuang/claude-code-by-agents, 2025; claudecode.run, 2025]

### 2.5 Claude Code Built-in Multi-Agent (TeammateTool)

Anthropic built a complete multi-agent orchestration system within Claude Code's own codebase -- fully implemented but initially hidden behind a disabled function. This was later exposed as official "agent teams" support with built-in worktree isolation.

**What Clome can learn:**
- Even Anthropic sees multi-agent as the future direction
- The orchestrator pattern (one lead agent spawning sub-agents) is the consensus architecture

[Source: paddo.dev, 2025; code.claude.com/docs/en/agent-teams]

---

## 3. Conversation UI Patterns for Coding Agents

### 3.1 Conversation Branching and Forking

**The Problem:** Linear chat is insufficient for coding. Developers need to explore alternatives, backtrack, and compare approaches.

**Existing Implementations:**

| Tool | Pattern | Visual Representation |
|------|---------|----------------------|
| ChatGPT | Branch from any message | Carousel arrows at branch points |
| Warp | Conversation forking | New thread inheriting full context |
| LibreChat | Fork with 3 modes | Target, from start, or include branches |
| Windsurf | Checkpoints + multiple Cascades | Named snapshots, dropdown to switch |
| Claudia/Opcode | Timeline with checkpoints | Visual timeline, one-click restore |

**UX Design Principles (from ShapeofAI.com pattern library):**
- Make branch creation explicit (user should consciously fork)
- Keep context inheritance clear (show what carries over)
- Provide comparison views (diff between branches)
- Visual maps of conversation topology help users orient themselves
- Easy merge or retire of abandoned branches

**What Clome can learn:**
- Clome's Conversation DAG (Phase 2) is the right architecture -- no one else has a true DAG
- Key UX challenge: visual graph rendering that stays comprehensible at scale
- Fork + merge operations on conversations should mirror git mental model
- Linking code state to conversation state (which code version goes with which branch) is unexplored territory

[Source: shapeof.ai, 2025; medium.com/@nikivergis, 2025; docs.warp.dev; librechat.ai]

### 3.2 Chat-in-IDE Patterns

**Cursor approach:**
- Agent mode combined chat + composer into single panel
- Inline diffs shown directly in editor for each agent action
- @-symbol for referencing files, folders, docs
- Cmd+K for inline editing prompts on selected code
- Interactive MCP UIs (charts, diagrams) render inside chat

**Windsurf/Cascade approach:**
- Side panel that tracks all user actions (edits, commands, clipboard)
- Cascade infers intent from tracked actions
- Multiple simultaneous Cascade sessions via dropdown
- Cross-conversation references via @-mention of previous conversations
- Named checkpoints for project state snapshots

**Zed approach:**
- Agent is a "multiplayer" participant -- like a collaborator in Google Docs
- Changes stream live at 120fps in the editor buffer
- Robust review interface with per-file diffs for agent changes
- Agent Client Protocol (ACP) for pluggable agent backends

**What Clome can learn:**
- Zed's "agent as collaborator" model aligns with Clome's native architecture
- Inline diffs (Cursor) are more useful than chat-only responses
- Action tracking (Windsurf) provides rich implicit context without user effort
- ACP-style protocol abstraction lets users bring their own agents

[Source: cursor.com/features, 2025; docs.windsurf.com; zed.dev/agentic, 2025]

### 3.3 Long Conversation Management

**Auto-compaction (Goose):** At 80% context window, auto-summarizes conversation preserving key parts. This is transparent to the user.

**Context engineering best practices:**
- CLAUDE.md / .cursorrules files as persistent context injection
- Structured prompts that front-load important context
- File-based context management (add/remove files from context)

**What Clome can learn:**
- Auto-compaction should be visible (show when/how summarization happened)
- Context window meter should be always-visible, like a fuel gauge
- Let users manually mark messages as "important" (never summarize away)

[Source: block.github.io/goose, 2025; sankalp.bearblog.dev, 2025]

---

## 4. File Change Visualization in Agent Contexts

### 4.1 Current Approaches

**IDE diff viewers for Claude Code:**
- Side-by-side graphical comparison of AI-suggested changes
- Essential for reviewing agent modifications before accepting
- Third-party tools (eesel.ai guide) show how to set up external diff viewers

**GitHub Copilot Workspace:**
- Progress bar underneath each file being implemented
- Delta display showing only the code changes added/modified
- UX state persistence (collapsed files, minimized timeline)
- Status indicator + stop button at bottom of "Files changed" section

**Cursor:**
- Inline diffs directly in editor (green/red highlighting)
- Agent changes appear as reviewable diffs per file
- Accept/reject per change or per file

**Zed:**
- Live streaming of file changes as agent types (120fps)
- Review interface with per-file diffs
- Changes appear like a remote collaborator editing

**Parallel Code:**
- Per-task changed files list in sidebar
- Built-in diff viewer per task
- Merge workflow back to main branch

### 4.2 Best Practices for File Change UX

1. **Real-time indicators:** Show which files an agent is currently modifying (pulsing dot, spinner)
2. **Change count badges:** Number of lines added/removed per file (like git status)
3. **File tree annotations:** Color-coded indicators in project explorer (modified, added, deleted)
4. **Grouped by agent:** When multiple agents run, group file changes by which agent made them
5. **Accept/reject granularity:** Per-line, per-hunk, per-file, or per-agent batch
6. **Undo integration:** Agent changes should be undoable as a single unit

**What Clome can learn:**
- Clome already has DiffView.swift with accept/reject -- extend it for agent-generated diffs
- FileExplorerView should show real-time modification indicators
- FileWatcher already monitors external changes -- use this for agent file monitoring
- Group changes by agent session for multi-agent scenarios

[Source: eesel.ai, 2025; githubnext.com; cursor.com; zed.dev]

---

## 5. Drag-and-Drop and Rich Input for AI Agents

### 5.1 Current Patterns

**Cursor:**
- Drag files from file explorer sidebar directly into chat
- Paste screenshots directly into chat (image understanding)
- @-symbol to reference files, folders, documentation
- Gemini 3 Pro has strongest image understanding for screenshot analysis

**MCP-based context:**
- Figma MCP: pull live design data into agent context
- v0 MCP: design-to-code via MCP integration
- Model Context Protocol standardization (2025) enables any tool to provide context

**Windsurf:**
- "Highlight code, reference files or directories" in Cascade
- Automatic tracking of clipboard contents as potential context

### 5.2 Rich Input Opportunities for Clome

| Input Type | Current State of Art | Clome Opportunity |
|------------|---------------------|-------------------|
| File drag | Cursor (basic) | Native drag from Finder + file explorer |
| Screenshots | Cursor paste | Native screenshot capture + paste |
| Code selection | All IDEs | Drag selection from editor into agent chat |
| Terminal output | None well | Drag terminal output into agent context |
| Browser content | Windsurf (partial) | Drag from BrowserPanel into agent |
| PDF/images | None | Drag from PDFPanel into agent context |
| Notebook cells | None | Drag cells from NotebookPanel |
| Diff hunks | None | Drag diff hunks as context |

**What Clome can learn:**
- Clome has unique advantage: terminal, editor, browser, PDF, notebook all in one app
- Every panel type should support "send to agent context" via drag or button
- This is a major differentiator vs web-based wrappers that only handle files

[Source: cursor.com/features; developertoolkit.ai; docs.windsurf.com]

---

## 6. Context Window Visualization

### 6.1 Current Approaches

**Goose:** Auto-compacts at 80% threshold, transparent summarization
**Letta ADE:** Visual context window inspector showing memory layout
**Claude Code:** Shows token count in status, auto-compacts
**Cursor:** No explicit visualization (handles internally)

### 6.2 Emerging UX Patterns

- **Fuel gauge metaphor:** Always-visible bar showing % of context used
- **Color transitions:** Green (plenty) -> yellow (getting full) -> red (near limit)
- **Breakdown view:** Expandable panel showing what occupies context (files, conversation, system prompt)
- **Eviction preview:** Show what will be summarized/dropped when context fills up
- **Per-source attribution:** How much context each file, conversation turn, or tool output consumes

### 6.3 What Clome Should Build

A context window visualization that shows:
1. Total capacity bar (model-dependent)
2. Breakdown by category: system prompt, conversation history, file contents, tool outputs
3. Warning threshold (configurable, default 80%)
4. "What will be evicted" preview when nearing limit
5. Manual pin/unpin for important context items
6. Per-agent context usage when running multiple agents

This is largely unexplored territory -- most tools hide context management entirely. Making it visible and controllable is a power-user differentiator.

[Source: block.github.io/goose; letta.com/blog; qodo.ai/blog]

---

## 7. Agent Progress and Status UX Patterns

### 7.1 Modern Agentic State Communication

**Emerging patterns (2025-2026):**

1. **Chain-of-Thought Disclosure:** Agent shows decomposed steps ("Step 1: Researching...", "Step 2: Implementing...") with progressive UI updates. Checkboxes or step indicators update in real-time.

2. **Skeleton Screens:** During AI inference, show skeleton layouts of expected content instead of spinners. Reduces perceived load time by ~40% in user testing.

3. **Confidence Indicators:** Visual badges showing AI certainty ("92% confidence"), color-coded borders (green=high, amber=medium, red=low).

4. **Streaming Disclosure:** Show agent's thinking/reasoning as it streams, not just the final answer. Builds trust and allows early course-correction.

5. **Agent State Machine:** Explicit states visible to user:
   - Thinking (animated indicator)
   - Planning (shows plan outline)
   - Executing (progress through steps)
   - Waiting (for user input or external tool)
   - Error (with recovery options)
   - Complete (with summary)

### 7.2 Multi-Agent Status Dashboard

For parallel agents, the UI needs:
- Per-agent status card (name, state, current action, progress)
- Aggregate progress (3 of 5 agents complete)
- Resource usage per agent (tokens consumed, time elapsed)
- File conflict warnings (two agents touching same file)
- Quick actions: pause, resume, cancel, view details

**What Clome can learn:**
- Metal-accelerated rendering can make step-by-step disclosure buttery smooth
- Native NSView hierarchy can show rich agent state without web rendering overhead
- Sidebar badges (already built) can extend to per-agent status indicators

[Source: agenticpathdesign.com, 2025; groovyweb.co, 2026; smashingmagazine.com, 2026]

---

## 8. Emerging Standards and Protocols

### 8.1 Google A2UI (Agent-to-User Interface)

**Released:** January 2026 (v0.8, Apache 2.0)

A declarative UI protocol where agents generate rich, interactive UIs that render natively across platforms. Key properties:
- Flat list of components with ID references (easy for LLMs to generate incrementally)
- Client maintains catalog of trusted component types (Card, Button, TextField)
- Agent references catalog types -- no arbitrary code execution
- Progressive rendering: incremental updates as conversation progresses
- Already used in Gemini Enterprise, Opal, Flutter GenUI

**Implication for Clome:** Clome could implement an A2UI renderer as a native component, allowing agents to generate rich UIs (data tables, charts, forms) that render with Metal acceleration instead of WebView.

[Source: developers.googleblog.com, 2026; a2ui.org; marktechpost.com, 2025]

### 8.2 Agent Client Protocol (ACP) - Zed + JetBrains

An open protocol letting AI coding agents work inside editors. Zed and JetBrains are collaborating on this standard.

**Implication for Clome:** Implementing ACP would let Clome host any compatible agent backend, not just Claude Code.

[Source: zed.dev/acp; blog.jetbrains.com, 2025]

### 8.3 Model Context Protocol (MCP)

Standardized in 2025, now widely adopted. Allows tools/services to provide context to AI agents via a standard interface.

**Implication for Clome:** MCP server management UI (like Claudia/Opcode) should be built in. Clome panels (browser, PDF, notebook) could expose MCP endpoints.

[Source: Anthropic MCP specification; multiple tool integrations in 2025]

---

## 9. Recommendations for Clome

### Immediate Opportunities (High Impact, Leverages Existing Architecture)

1. **Agent Chat Panel** -- New panel type alongside Terminal/Editor/Browser/PDF/Notebook. Wraps Claude Code CLI (or any agent) with rich rendering of responses, inline diffs, and step-by-step progress.

2. **Universal "Send to Agent" Action** -- Every panel gets a "send to agent context" button/drag target. Terminal output, code selections, browser content, PDF pages, notebook cells all become dragable context.

3. **File Change Indicators** -- Extend FileExplorerView with real-time modification indicators (colored dots, change count badges) driven by FileWatcher when agents modify files.

4. **Context Window Meter** -- Always-visible gauge in agent panel toolbar showing context usage with breakdown on click.

5. **Agent Status in Sidebar** -- Extend existing sidebar badges to show per-workspace agent status (thinking, executing, waiting, complete).

### Medium-Term (Phase 2 Alignment)

6. **Conversation DAG Visualization** -- Clome's planned Phase 2 feature is ahead of the industry. Render the conversation graph visually with Metal, supporting fork/merge/prune. Link code state to conversation branches.

7. **Parallel Agent Panels** -- Tiled layout showing multiple agents with per-agent: status, changed files, terminal, diff viewer. Git worktree isolation per agent.

8. **Agent Transparency** -- Show chain-of-thought, tool calls, and file operations inline in conversation with collapsible detail levels.

### Longer-Term (Differentiation)

9. **A2UI Renderer** -- Native renderer for Google's A2UI protocol, letting agents generate rich interactive UIs rendered with Metal instead of WebView.

10. **ACP Implementation** -- Support Agent Client Protocol for pluggable agent backends beyond Claude Code.

11. **Cross-Agent Coordination** -- @mention routing between agents, file-based inter-agent communication, orchestrator pattern for complex multi-agent workflows.

---

## 10. Competitive Landscape Summary

```
                    Native Performance
                         ^
                         |
                    Zed  |  CLOME (target)
                         |
                         |
        Terminal-only ---+--- Full IDE
                         |
        Claude Code CLI  |  Cursor
        OpenCode         |  Windsurf
        Aider            |  VS 2026
                         |
                    Web/Electron
                    Claudia, Opcode
                    AiderDesk, Parallel Code
```

Clome occupies a unique position: native macOS performance with full IDE capabilities AND agent-first design. No existing tool combines all three.

---

## Bibliography

### GUI Wrappers
- [Claudia GUI](https://claudia.so/) - Tauri-based Claude Code GUI, AGPL licensed
- [Opcode](https://opcode.sh/) / [GitHub](https://github.com/winfunc/opcode) - Tauri Claude Code toolkit
- [AiderDesk](https://github.com/hotovo/aider-desk) - Electron-based Aider GUI with autonomous agents
- [CodePilot](https://github.com/op7418/CodePilot) - Electron + Next.js Claude Code GUI
- [CloudCLI](https://github.com/siteboon/claudecodeui) - Web-based remote Claude Code UI
- [Claude Code WebUI](https://github.com/sugyan/claude-code-webui) - Web interface for Claude CLI

### Multi-Agent Tools
- [Parallel Code](https://github.com/johannesjo/parallel-code) - Multi-agent worktree runner
- [Claude Code Agentrooms](https://claudecode.run) / [GitHub](https://github.com/baryhuang/claude-code-by-agents) - @mention-based orchestration
- [LangGraph Studio](https://blog.langchain.com/langgraph-studio-the-first-agent-ide/) - Agent visualization IDE
- [Cursor Parallel Agents](https://cursor.com/docs/configuration/worktrees) - Up to 8 parallel agents
- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams) - Built-in multi-agent

### IDE and Editor References
- [Cursor Features](https://cursor.com/features) - Agent mode, inline diffs, MCP apps
- [Zed AI](https://zed.dev/ai) / [Agentic Editing](https://zed.dev/agentic) - 120fps agent collaboration
- [Zed Agent Client Protocol](https://zed.dev/acp) - Open agent protocol
- [Windsurf Cascade](https://windsurf.com/cascade) - Action-tracking agent UI
- [GitHub Copilot Workspace](https://githubnext.com/projects/copilot-workspace) - File change visualization
- [Visual Studio 2026](https://devblogs.microsoft.com/visualstudio/visual-studio-november-update-visual-studio-2026-cloud-agent-preview-and-more/) - AI-native IDE

### Standards and Protocols
- [Google A2UI](https://a2ui.org/) / [Blog Post](https://developers.googleblog.com/introducing-a2ui-an-open-project-for-agent-driven-interfaces/) - Agent-driven UI protocol
- [Anthropic MCP](https://code.claude.com/docs/en/common-workflows) - Model Context Protocol

### UX Patterns
- [ShapeofAI - Branches Pattern](https://www.shapeof.ai/patterns/branches) - Conversation branching UX
- [Agentic State UI Patterns](https://www.agenticpathdesign.com/resources/-emerging-ui-patterns-for-communicating-agentic-states) - Agent progress indicators
- [Smashing Magazine - Agentic AI UX](https://www.smashingmagazine.com/2026/02/designing-agentic-ai-practical-ux-patterns/) - Practical patterns for control and consent
- [Nikita Vergis - Branching Conversations](https://medium.com/@nikivergis/ai-chat-tools-dont-match-how-we-actually-think-exploring-the-ux-of-branching-conversations-259107496afb) - UX analysis
- [Warp Conversation Forking](https://docs.warp.dev/agent-platform/local-agents/interacting-with-agents/conversation-forking) - Implementation reference
- [Builder.io - Agentic IDEs 2026](https://www.builder.io/blog/agentic-ide) - Industry overview
- [RedMonk - 10 Things Devs Want](https://redmonk.com/kholterhoff/2025/12/22/10-things-developers-want-from-their-agentic-ides-in-2025/) - Developer preferences

### Context and Performance
- [Goose - Context Windows](https://block.github.io/goose/blog/2025/08/18/understanding-context-windows/) - Auto-compaction UX
- [Letta - Context Engineering](https://www.letta.com/blog/guide-to-context-engineering) - Visual context management
- [Git Worktrees for AI Agents](https://medium.com/@mabd.dev/git-worktrees-the-secret-weapon-for-running-multiple-ai-coding-agents-in-parallel-e9046451eb96) - Isolation pattern
