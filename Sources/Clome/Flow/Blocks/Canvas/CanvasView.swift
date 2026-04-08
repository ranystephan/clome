import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Canvas editor. Pan + zoom, draggable nodes, click-and-drag edge
/// creation from a node's handle, drop-target for files and URLs.
///
/// Design: quiet. Dotted background grid at low opacity, hairline edges,
/// tint-railed cards identical in spirit to BlockCard.
struct CanvasView: View {
    @State var doc: CanvasDoc
    var onClose: () -> Void = {}

    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0

    @State private var selectedNodeID: UUID?
    @State private var editingNodeID: UUID?

    // Edge drawing state
    @State private var edgeDragFrom: UUID?
    @State private var edgeDragPoint: CGPoint = .zero

    @State private var isDropTargeted = false

    private let minZoom: CGFloat = 0.4
    private let maxZoom: CGFloat = 2.4

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background

                // World content: nodes + edges, scaled & translated
                ZStack {
                    edgesLayer
                    nodesLayer
                    liveEdgeOverlay
                }
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(pan)

                // Overlay toolbar
                VStack {
                    HStack {
                        titleField
                        Spacer()
                        toolbarControls
                    }
                    Spacer()
                    bottomHint
                }
                .padding(16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(FlowTokens.bg0)
            .contentShape(Rectangle())
            // Pan with drag, create node on double-click
            .gesture(panGesture)
            .simultaneousGesture(magnification)
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                createNoteAtScreen(location)
            }
            .onTapGesture { selectedNodeID = nil; editingNodeID = nil }
            .onDrop(
                of: [.fileURL, .url, .text],
                isTargeted: $isDropTargeted,
                perform: { providers, loc in handleDrop(providers: providers, screen: loc) }
            )
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(FlowTokens.accent.opacity(0.6),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
        }
        .onDisappear { CanvasStore.shared.save(doc) }
    }

    // MARK: - Background

    private var background: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 24 * zoom
            let offsetX = pan.width.truncatingRemainder(dividingBy: spacing)
            let offsetY = pan.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var x = offsetX
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = offsetY
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            ctx.stroke(path, with: .color(FlowTokens.textTertiary.opacity(0.05)), lineWidth: 0.5)
        }
    }

    // MARK: - Nodes layer

    private var nodesLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(doc.nodes) { node in
                nodeView(node)
                    .position(x: node.x + node.width / 2, y: node.y + node.height / 2)
            }
        }
    }

    private func nodeView(_ node: CanvasNode) -> some View {
        let tint = Color(hex: node.colorHex) ?? FlowTokens.accent
        let isSelected = selectedNodeID == node.id
        let isEditing = editingNodeID == node.id

        return CanvasCardView(
            node: node,
            tint: tint,
            isSelected: isSelected,
            isEditing: isEditing,
            onCommitTitle: { newTitle in
                if let idx = doc.nodes.firstIndex(where: { $0.id == node.id }) {
                    doc.nodes[idx].title = newTitle
                    CanvasStore.shared.save(doc)
                }
                editingNodeID = nil
            },
            onDelete: { deleteNode(node.id) },
            onStartEdge: { startEdge(from: node.id, at: $0) }
        )
        .frame(width: node.width, height: node.height)
        .onTapGesture(count: 2) {
            editingNodeID = node.id
            selectedNodeID = node.id
        }
        .onTapGesture {
            selectedNodeID = node.id
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard editingNodeID != node.id else { return }
                    moveNode(node.id, by: value.translation)
                }
                .onEnded { _ in CanvasStore.shared.save(doc) }
        )
    }

    // MARK: - Edges

    private var edgesLayer: some View {
        Canvas { ctx, _ in
            for edge in doc.edges {
                guard let a = doc.nodes.first(where: { $0.id == edge.from }),
                      let b = doc.nodes.first(where: { $0.id == edge.to }) else { continue }
                let p1 = CGPoint(x: a.x + a.width / 2, y: a.y + a.height / 2)
                let p2 = CGPoint(x: b.x + b.width / 2, y: b.y + b.height / 2)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(path, with: .color(FlowTokens.textSecondary.opacity(0.45)), lineWidth: 1)

                // Arrowhead
                let angle = atan2(p2.y - p1.y, p2.x - p1.x)
                let size: CGFloat = 7
                let tip = CGPoint(
                    x: p2.x - cos(angle) * 16,
                    y: p2.y - sin(angle) * 16
                )
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(
                    x: tip.x - cos(angle - .pi / 6) * size,
                    y: tip.y - sin(angle - .pi / 6) * size
                ))
                head.move(to: tip)
                head.addLine(to: CGPoint(
                    x: tip.x - cos(angle + .pi / 6) * size,
                    y: tip.y - sin(angle + .pi / 6) * size
                ))
                ctx.stroke(head, with: .color(FlowTokens.textSecondary.opacity(0.55)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var liveEdgeOverlay: some View {
        if let from = edgeDragFrom,
           let src = doc.nodes.first(where: { $0.id == from }) {
            Canvas { ctx, _ in
                let p1 = CGPoint(x: src.x + src.width / 2, y: src.y + src.height / 2)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: edgeDragPoint)
                ctx.stroke(path, with: .color(FlowTokens.accent), lineWidth: 1.5)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if let from = edgeDragFrom {
                    edgeDragPoint = worldPoint(fromScreen: v.location)
                    // Snap to any node under the pointer
                    if let target = nodeAt(worldPoint: edgeDragPoint), target.id != from {
                        edgeDragPoint = CGPoint(x: target.x + target.width / 2,
                                                 y: target.y + target.height / 2)
                    }
                    return
                }
                pan = CGSize(
                    width: basePan.width + v.translation.width,
                    height: basePan.height + v.translation.height
                )
            }
            .onEnded { v in
                if let from = edgeDragFrom {
                    let p = worldPoint(fromScreen: v.location)
                    if let target = nodeAt(worldPoint: p), target.id != from {
                        let edge = CanvasEdge(id: UUID(), from: from, to: target.id)
                        doc.edges.append(edge)
                        CanvasStore.shared.save(doc)
                    }
                    edgeDragFrom = nil
                    return
                }
                basePan = pan
            }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { v in zoom = (baseZoom * v).clamped(to: minZoom...maxZoom) }
            .onEnded { _ in baseZoom = zoom }
    }

    // MARK: - Toolbar

    private var titleField: some View {
        TextField("", text: $doc.title)
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(FlowTokens.textPrimary)
            .onChange(of: doc.title) { _, _ in CanvasStore.shared.save(doc) }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlowTokens.bg1.opacity(0.7))
            )
            .frame(maxWidth: 280)
    }

    private var toolbarControls: some View {
        HStack(spacing: 6) {
            tbButton("plus", help: "New note (double-click canvas)") {
                createNoteAtCenter()
            }
            tbButton("arrow.up.left.and.arrow.down.right", help: "Reset view") {
                withAnimation(.flowSpring) { pan = .zero; basePan = .zero; zoom = 1; baseZoom = 1 }
            }
            Text("\(Int(zoom * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTokens.textTertiary)
                .padding(.horizontal, 8)
            tbButton("xmark", help: "Close") {
                CanvasStore.shared.save(doc)
                onClose()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FlowTokens.bg1.opacity(0.7))
        )
    }

    private func tbButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(FlowTokens.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var bottomHint: some View {
        HStack {
            Text("double-click to add note · drag handle to connect · drop files")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(FlowTokens.bg1.opacity(0.5))
                )
            Spacer()
        }
    }

    // MARK: - Node mutations

    private func moveNode(_ id: UUID, by translation: CGSize) {
        guard let idx = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
        doc.nodes[idx].x += translation.width / zoom
        doc.nodes[idx].y += translation.height / zoom
    }

    private func deleteNode(_ id: UUID) {
        doc.nodes.removeAll { $0.id == id }
        doc.edges.removeAll { $0.from == id || $0.to == id }
        if selectedNodeID == id { selectedNodeID = nil }
        if editingNodeID == id { editingNodeID = nil }
        CanvasStore.shared.save(doc)
    }

    private func startEdge(from id: UUID, at point: CGPoint) {
        edgeDragFrom = id
        edgeDragPoint = point
    }

    private func createNoteAtScreen(_ screen: CGPoint) {
        let p = worldPoint(fromScreen: screen)
        var node = CanvasNode.note(at: CGPoint(x: p.x - 90, y: p.y - 40))
        node.title = "Note"
        doc.nodes.append(node)
        selectedNodeID = node.id
        editingNodeID = node.id
        CanvasStore.shared.save(doc)
    }

    private func createNoteAtCenter() {
        let node = CanvasNode.note(at: CGPoint(x: 200, y: 200))
        doc.nodes.append(node)
        selectedNodeID = node.id
        editingNodeID = node.id
        CanvasStore.shared.save(doc)
    }

    // MARK: - Drop

    private func handleDrop(providers: [NSItemProvider], screen: CGPoint) -> Bool {
        let world = worldPoint(fromScreen: screen)
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        let node = CanvasNode.file(path: url.path,
                                                    at: CGPoint(x: world.x - 90, y: world.y - 28))
                        doc.nodes.append(node)
                        CanvasStore.shared.save(doc)
                    }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                p.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    var url: URL?
                    if let d = data as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = data as? URL { url = u }
                    guard let u = url else { return }
                    Task { @MainActor in
                        let node = CanvasNode.url(u, at: CGPoint(x: world.x - 100, y: world.y - 26))
                        doc.nodes.append(node)
                        CanvasStore.shared.save(doc)
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Coordinate helpers

    private func worldPoint(fromScreen p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - pan.width) / zoom,
            y: (p.y - pan.height) / zoom
        )
    }

    private func nodeAt(worldPoint p: CGPoint) -> CanvasNode? {
        doc.nodes.first { n in
            p.x >= n.x && p.x <= n.x + n.width &&
            p.y >= n.y && p.y <= n.y + n.height
        }
    }
}

// MARK: - Card

private struct CanvasCardView: View {
    let node: CanvasNode
    let tint: Color
    let isSelected: Bool
    let isEditing: Bool
    let onCommitTitle: (String) -> Void
    let onDelete: () -> Void
    let onStartEdge: (CGPoint) -> Void

    @State private var draftTitle: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint.opacity(0.95)).frame(width: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: node.kind.systemIcon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(tint.opacity(0.85))
                    if isEditing {
                        TextField("", text: $draftTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(FlowTokens.textPrimary)
                            .focused($focused)
                            .onAppear {
                                draftTitle = node.title
                                focused = true
                            }
                            .onSubmit { onCommitTitle(draftTitle) }
                    } else {
                        Text(node.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(FlowTokens.textPrimary)
                            .lineLimit(1)
                    }
                }
                if !node.body.isEmpty && node.kind != .note {
                    Text(node.body)
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FlowTokens.bg2.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.7) : FlowTokens.border,
                              lineWidth: isSelected ? 1 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if isSelected && !isEditing {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(FlowTokens.textTertiary)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(FlowTokens.bg1))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .overlay(alignment: .trailing) {
            // Edge handle
            if isSelected && !isEditing {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(FlowTokens.bg0, lineWidth: 1))
                    .offset(x: 6)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                onStartEdge(CGPoint(x: node.x + node.width / 2 + v.translation.width,
                                                    y: node.y + node.height / 2 + v.translation.height))
                            }
                    )
            }
        }
    }
}

// MARK: - Comparable clamp helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
