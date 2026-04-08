import SwiftUI
import ClomeModels

// MARK: - Workspace Switcher
//
// Phase 3 of the Flow Workspaces rollout. Provides:
//   - WorkspaceSwitcherChip:  the always-visible header button.
//   - WorkspaceSwitcherPopover: the dropdown list of workspaces with the
//     "+ New Workspace" affordance.
//   - NewWorkspaceSheet:      the modal for creating a workspace, with
//     name field, icon picker, and color picker.
//   - WorkspaceShortcutHost:  invisible buttons that bind Cmd+1..9 to
//     workspace switching for the first nine in pinnedOrder.

// MARK: - Chip

struct WorkspaceSwitcherChip: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                workspaceIcon
                VStack(alignment: .leading, spacing: 0) {
                    Text("WORKSPACE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundColor(FlowTokens.textHint)
                    Text(store.activeWorkspace?.name ?? "Personal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(FlowTokens.textPrimary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(FlowTokens.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(FlowTokens.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(FlowTokens.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            WorkspaceSwitcherPopover(store: store, isPresented: $showPopover)
        }
        .help("Switch workspace")
    }

    @ViewBuilder
    private var workspaceIcon: some View {
        let active = store.activeWorkspace
        let color = active?.colorKey ?? .graphite
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.tint)
                .frame(width: 22, height: 22)
            Image(systemName: active?.icon ?? "person.crop.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color.onTintTextColor)
        }
    }
}

// MARK: - Popover

struct WorkspaceSwitcherPopover: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var isPresented: Bool
    @State private var showNewSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("WORKSPACES")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundColor(FlowTokens.textTertiary)
                Spacer()
                Text("\(store.workspaces.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTokens.textHint)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Workspace rows
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            isActive: workspace.id == store.activeWorkspaceID,
                            shortcutIndex: index < 9 ? index + 1 : nil
                        ) {
                            Task {
                                await store.setActiveWorkspace(id: workspace.id)
                                isPresented = false
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 320)

            Divider().background(FlowTokens.border)

            // Footer — "+ New Workspace"
            Button {
                showNewSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(FlowTokens.accent)
                    Text("New Workspace")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(FlowTokens.textPrimary)
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textHint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(FlowTokens.bg1)
        }
        .frame(width: 280)
        .background(FlowTokens.bg2)
        .sheet(isPresented: $showNewSheet) {
            NewWorkspaceSheet(store: store) {
                showNewSheet = false
                isPresented = false
            }
        }
    }
}

// MARK: - Workspace Row

private struct WorkspaceRow: View {
    let workspace: FlowWorkspace
    let isActive: Bool
    let shortcutIndex: Int?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Color icon tile
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(workspace.colorKey.tint)
                        .frame(width: 26, height: 26)
                    Image(systemName: workspace.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(workspace.colorKey.onTintTextColor)
                }

                // Name + meta
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                        .foregroundColor(FlowTokens.textPrimary)
                        .lineLimit(1)
                    if workspace.isPersonal {
                        Text("Default workspace")
                            .font(.system(size: 9))
                            .foregroundColor(FlowTokens.textHint)
                    } else {
                        Text(workspace.colorKey.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(FlowTokens.textHint)
                    }
                }

                Spacer(minLength: 0)

                // Shortcut hint or active dot
                if isActive {
                    Circle()
                        .fill(FlowTokens.accent)
                        .frame(width: 6, height: 6)
                } else if let shortcutIndex {
                    Text("⌘\(shortcutIndex)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textHint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isActive { return FlowTokens.bg3 }
        if isHovered { return FlowTokens.bg3.opacity(0.6) }
        return Color.clear
    }
}

// MARK: - New Workspace Sheet

struct NewWorkspaceSheet: View {
    @ObservedObject var store: WorkspaceStore
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var selectedColor: WorkspaceColorKey = .teal
    @State private var selectedIcon: String = "folder.fill"
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    private let iconOptions: [String] = [
        "folder.fill", "briefcase.fill", "house.fill", "graduationcap.fill",
        "hammer.fill", "paintbrush.fill", "lightbulb.fill", "books.vertical.fill",
        "film.fill", "music.note.list", "leaf.fill", "globe", "sparkles",
        "chart.line.uptrend.xyaxis", "wrench.adjustable.fill", "person.2.fill"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selectedColor.tint)
                        .frame(width: 56, height: 56)
                    Image(systemName: selectedIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(selectedColor.onTintTextColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Workspace")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(FlowTokens.textPrimary)
                    Text("A scoped container for notes, tasks, and deadlines.")
                        .font(.system(size: 11))
                        .foregroundColor(FlowTokens.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().background(FlowTokens.border)

            VStack(alignment: .leading, spacing: 18) {
                // Name field
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(FlowTokens.textTertiary)
                    TextField("", text: $name, prompt: Text("e.g. Acme Client").foregroundColor(FlowTokens.textHint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(FlowTokens.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(FlowTokens.bg1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(nameFocused ? FlowTokens.borderFocused : FlowTokens.border, lineWidth: 0.5)
                        )
                        .focused($nameFocused)
                        .onSubmit(create)
                }

                // Color picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("COLOR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(FlowTokens.textTertiary)
                    HStack(spacing: 8) {
                        ForEach(WorkspaceColorKey.allCases, id: \.self) { key in
                            Button {
                                selectedColor = key
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(key.tint)
                                        .frame(width: 26, height: 26)
                                    if selectedColor == key {
                                        Circle()
                                            .strokeBorder(Color.white, lineWidth: 2)
                                            .frame(width: 26, height: 26)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(key.onTintTextColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(key.displayName)
                        }
                    }
                }

                // Icon picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("ICON")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(FlowTokens.textTertiary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                        ForEach(iconOptions, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(selectedIcon == icon ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(selectedIcon == icon ? FlowTokens.bg3 : FlowTokens.bg1)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                selectedIcon == icon ? FlowTokens.borderFocused : FlowTokens.border,
                                                lineWidth: 0.5
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider().background(FlowTokens.border)

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FlowTokens.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(FlowTokens.bg2)
                )
                .keyboardShortcut(.cancelAction)

                Button(isCreating ? "Creating…" : "Create") {
                    create()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(canCreate ? FlowTokens.accent : FlowTokens.bg3)
                )
                .disabled(!canCreate || isCreating)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(FlowTokens.bg0)
        .onAppear { nameFocused = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        Task {
            _ = await store.createWorkspace(
                name: name,
                colorKey: selectedColor,
                icon: selectedIcon
            )
            isCreating = false
            onDismiss()
        }
    }
}

// MARK: - Keyboard Shortcut Host
//
// SwiftUI delivers `.keyboardShortcut` to the focused window via hidden
// buttons. We mount one button per pinned workspace (capped at 9) so the
// user can switch with ⌘1…⌘9 from anywhere in the Flow tab. The buttons
// are zero-sized and absent from layout — only their key bindings count.

struct WorkspaceShortcutHost: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            ForEach(Array(store.workspaces.prefix(9).enumerated()), id: \.element.id) { index, workspace in
                Button("") {
                    Task { await store.setActiveWorkspace(id: workspace.id) }
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
