import SwiftUI
import ClomeModels

/// Redesigned notes view with category filter chips, card-based layout,
/// expandable detail views, and collapsible search.
struct FlowNotesView: View {
    @ObservedObject private var sync = FlowSyncService.shared
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var selectedNoteID: UUID?
    @State private var selectedCategory: NoteCategory?

    private var filteredNotes: [NoteEntry] {
        var result = sync.notes
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter {
                $0.rawContent.lowercased().contains(lower) ||
                $0.summary.lowercased().contains(lower)
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var categoryCounts: [NoteCategory: Int] {
        var counts: [NoteCategory: Int] = [:]
        for note in sync.notes {
            counts[note.category, default: 0] += 1
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            categoryFilterBar
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            if sync.notes.isEmpty {
                emptyState
            } else if filteredNotes.isEmpty {
                noResultsState
            } else {
                notesList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Text("Notes")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FlowTokens.textSecondary)

            if case .connecting = sync.syncStatus {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }

            Spacer()

            // Search toggle
            Button {
                withAnimation(.flowQuick) {
                    showSearch.toggle()
                    if !showSearch { searchText = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(showSearch ? FlowTokens.accent : FlowTokens.textHint)
            }
            .buttonStyle(.plain)

            Text("\(sync.notes.count)")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)
        }
        .flowHeaderBar()
    }

    // MARK: - Category Filter

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FlowTokens.spacingSM) {
                // "All" chip
                filterChip(label: "All", icon: nil, isActive: selectedCategory == nil, count: sync.notes.count) {
                    withAnimation(.flowQuick) { selectedCategory = nil }
                }

                ForEach(NoteCategory.allCases, id: \.self) { category in
                    let count = categoryCounts[category] ?? 0
                    if count > 0 {
                        filterChip(
                            label: category.displayName,
                            icon: category.icon,
                            isActive: selectedCategory == category,
                            count: count
                        ) {
                            withAnimation(.flowQuick) {
                                selectedCategory = selectedCategory == category ? nil : category
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, FlowTokens.spacingSM)
        }
        .background(FlowTokens.bg0)
    }

    private func filterChip(label: String, icon: String?, isActive: Bool, count: Int,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(label)
                    .flowFont(.micro)
                Text("\(count)")
                    .flowFont(.timestamp)
                    .foregroundColor(isActive ? FlowTokens.textSecondary : FlowTokens.textMuted)
            }
            .foregroundColor(isActive ? FlowTokens.textPrimary : FlowTokens.textTertiary)
            .padding(.horizontal, FlowTokens.spacingMD - 2)
            .padding(.vertical, 4)
            .flowControl(isActive: isActive, radius: FlowTokens.radiusControl)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notes List

    private var notesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showSearch {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(FlowTokens.textHint)
                        TextField("Search notes…", text: $searchText)
                            .textFieldStyle(.plain)
                            .flowFont(.body)
                            .foregroundColor(FlowTokens.textPrimary)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(FlowTokens.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .flowInput()
                    .padding(.horizontal, FlowTokens.spacingLG)
                    .padding(.top, FlowTokens.spacingMD)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Note cards
                LazyVStack(spacing: FlowTokens.spacingMD) {
                    ForEach(filteredNotes) { note in
                        noteCard(note)
                    }
                }
                .padding(.horizontal, FlowTokens.spacingMD)
                .padding(.top, FlowTokens.spacingMD)
                .padding(.bottom, FlowTokens.spacingMD)
            }
        }
    }

    // MARK: - Note Card

    private func noteCard(_ note: NoteEntry) -> some View {
        let isExpanded = selectedNoteID == note.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(categoryColor(note.category))
                    .frame(width: FlowTokens.accentBarWidth)

                VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                    // Header row
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: note.category.icon)
                            .font(.system(size: 9))
                            .foregroundColor(categoryColor(note.category))

                        Text(note.summary.isEmpty ? String(note.rawContent.prefix(50)) : note.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(FlowTokens.textPrimary)
                            .lineLimit(isExpanded ? 3 : 1)

                        Spacer()

                        if note.isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(FlowTokens.success.opacity(0.6))
                        }
                    }

                    // Content preview (collapsed)
                    if !isExpanded {
                        Text(note.rawContent.prefix(80).description)
                            .font(.system(size: 10))
                            .foregroundColor(FlowTokens.textTertiary)
                            .lineLimit(2)
                    }

                    // Expanded content
                    if isExpanded {
                        Text(note.rawContent)
                            .font(.system(size: 11))
                            .foregroundColor(FlowTokens.textSecondary)
                            .lineLimit(20)
                            .padding(.top, FlowTokens.spacingXS)

                        // Action items
                        if !note.actionItems.isEmpty {
                            VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
                                ForEach(note.actionItems) { item in
                                    HStack(spacing: FlowTokens.spacingSM) {
                                        Image(systemName: item.isScheduled ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 9))
                                            .foregroundColor(item.isScheduled ? FlowTokens.success.opacity(0.6) : FlowTokens.textHint)
                                        Text(item.description)
                                            .font(.system(size: 10))
                                            .foregroundColor(FlowTokens.textTertiary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(.top, FlowTokens.spacingSM)
                        }
                    }

                    // Bottom row: tags + timestamp
                    HStack(spacing: FlowTokens.spacingSM) {
                        if !isExpanded && !note.actionItems.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "checklist")
                                    .font(.system(size: 8))
                                Text("\(note.actionItems.count)")
                                    .font(.system(size: 8, design: .monospaced))
                            }
                            .foregroundColor(FlowTokens.textMuted)
                            .padding(.horizontal, FlowTokens.spacingSM)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(FlowTokens.bg3)
                            )
                        }

                        Spacer()

                        Text(note.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(FlowTokens.textMuted)
                    }
                }
                .padding(FlowTokens.spacingMD)
            }
        }
        .flowCard(isSelected: isExpanded)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.flowSpring) {
                selectedNoteID = isExpanded ? nil : note.id
            }
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: FlowTokens.spacingLG) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 28))
                .foregroundColor(FlowTokens.textDisabled)
            Text("No notes yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FlowTokens.textTertiary)
            Text("Notes from Clome Flow will appear\nhere when synced.")
                .font(.system(size: 11))
                .foregroundColor(FlowTokens.textMuted)
                .multilineTextAlignment(.center)
            if case .error(let msg) = sync.syncStatus {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.error)
                    .padding(.top, FlowTokens.spacingSM)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(FlowTokens.textDisabled)
            Text("No matching notes")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FlowTokens.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func categoryColor(_ category: NoteCategory) -> Color {
        switch category {
        case .idea: return .yellow.opacity(0.7)
        case .task: return FlowTokens.accent.opacity(0.7)
        case .reminder: return .orange.opacity(0.7)
        case .goal: return FlowTokens.success.opacity(0.8)
        case .journal: return .purple.opacity(0.7)
        case .reference: return .gray.opacity(0.7)
        }
    }
}
