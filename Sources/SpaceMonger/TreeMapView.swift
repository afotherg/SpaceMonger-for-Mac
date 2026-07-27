import SwiftUI

// 8-color palette cycling by depth — similar to the 26-color palette in the
// original (OnDraw uses depth % 8 with two sets of 4 colours per group).
private let depthColors: [Color] = [
    Color(red: 0.88, green: 0.35, blue: 0.35),  // 0 – brick red
    Color(red: 0.93, green: 0.60, blue: 0.25),  // 1 – amber
    Color(red: 0.88, green: 0.83, blue: 0.28),  // 2 – yellow
    Color(red: 0.35, green: 0.76, blue: 0.40),  // 3 – green
    Color(red: 0.28, green: 0.72, blue: 0.84),  // 4 – cyan
    Color(red: 0.35, green: 0.50, blue: 0.90),  // 5 – blue
    Color(red: 0.66, green: 0.38, blue: 0.90),  // 6 – purple
    Color(red: 0.90, green: 0.38, blue: 0.68),  // 7 – pink
]

private func colorForDepth(_ depth: Int) -> Color {
    depthColors[depth % depthColors.count]
}

/// Renders the treemap using SwiftUI Canvas and handles mouse interaction.
/// Replaces CFolderView's OnDraw() / OnLButtonDown() from FolderView.cpp.
struct TreeMapView: View {
    let root: FileNode
    let revision: Int
    let onNodeTapped: (FileNode) -> Void
    @Binding var hoveredNode: DisplayNode?

    @State private var layoutNodes: [DisplayNode] = []

    private let titleHeight = TreeMapLayoutEngine.titleHeight
    private let minLabel: CGFloat = 22   // minimum rect width to draw text

    var body: some View {
        // Read state while evaluating the SwiftUI body, not only inside Canvas's
        // deferred renderer closure. This makes a new layout invalidate the Canvas.
        let renderedNodes = layoutNodes
        let hoveredID = hoveredNode?.fileNode.id

        GeometryReader { geo in
            Canvas { ctx, size in
                // Dark background (original paints BLACKNESS first)
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(white: 0.12)))

                for node in renderedNodes {
                    draw(node: node, in: ctx,
                         hovered: hoveredID == node.fileNode.id)
                }
            }
            .contentShape(Rectangle())
            // Hover: update hoveredNode as the mouse moves (replaces WM_MOUSEMOVE)
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    hoveredNode = TreeMapLayoutEngine.hitTest(point: pt, in: renderedNodes)
                case .ended:
                    hoveredNode = nil
                }
            }
            // Click: the parent decides whether the selected node is navigable.
            .gesture(
                SpatialTapGesture().onEnded { e in
                    if let node = TreeMapLayoutEngine.hitTest(
                        point: e.location, in: renderedNodes) {
                        onNodeTapped(node.fileNode)
                    }
                }
            )
            .onChange(of: geo.size, initial: true) { _, newSize in
                updateLayout(for: newSize)
            }
            .task(id: TreeMapUpdateID(rootID: root.id, revision: revision)) {
                // The view can appear before GeometryReader has its final size. Yielding
                // one run-loop turn ensures a newly scanned root gets a visible layout
                // without waiting for an unrelated hover event to invalidate the Canvas.
                await Task.yield()
                updateLayout(for: geo.size)
            }
        }
    }

    // MARK: - Layout

    private func updateLayout(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        layoutNodes = TreeMapLayoutEngine.layout(
            root: root, in: CGRect(origin: .zero, size: size))
    }

    // MARK: - Drawing

    private func draw(node: DisplayNode, in ctx: GraphicsContext, hovered: Bool) {
        let rect = node.rect
        guard rect.width >= 1, rect.height >= 1 else { return }

        let color = colorForDepth(node.depth)

        if node.isDirectory {
            drawDirectory(node: node, rect: rect, color: color, in: ctx, hovered: hovered)
        } else {
            drawFile(node: node, rect: rect, color: color, in: ctx, hovered: hovered)
        }
    }

    private func drawDirectory(
        node: DisplayNode, rect: CGRect, color: Color,
        in ctx: GraphicsContext, hovered: Bool
    ) {
        // Background — slightly lighter per depth level
        let shade = 0.16 + CGFloat(node.depth % 5) * 0.035
        ctx.fill(Path(rect), with: .color(Color(white: shade)))

        // Title bar
        if rect.height >= titleHeight {
            let titleRect = CGRect(x: rect.minX, y: rect.minY,
                                   width: rect.width, height: titleHeight)
            ctx.fill(Path(titleRect),
                     with: .color(hovered ? color : color.opacity(0.80)))

            if rect.width >= minLabel {
                drawLabel(node.name, in: titleRect.insetBy(dx: 3, dy: 1),
                          ctx: ctx, textColor: .white, bold: true)
            }
        }

        // Border — bright white on hover (replaces the 3D-border drawing)
        let borderColor: Color = hovered ? .white.opacity(0.9) : .black.opacity(0.45)
        let lineWidth: CGFloat = hovered ? 1.5 : 0.5
        ctx.stroke(Path(rect), with: .color(borderColor), lineWidth: lineWidth)
    }

    private func drawFile(
        node: DisplayNode, rect: CGRect, color: Color,
        in ctx: GraphicsContext, hovered: Bool
    ) {
        ctx.fill(Path(rect), with: .color(hovered ? color : color.opacity(0.82)))
        ctx.stroke(Path(rect), with: .color(Color.black.opacity(0.28)), lineWidth: 0.5)

        if rect.width >= minLabel, rect.height >= 10 {
            drawLabel(node.name, in: rect.insetBy(dx: 2, dy: 2),
                      ctx: ctx, textColor: .black.opacity(0.75), bold: false)
        }
    }

    private func drawLabel(
        _ text: String, in rect: CGRect,
        ctx: GraphicsContext, textColor: Color, bold: Bool
    ) {
        guard rect.width > 4, rect.height > 5 else { return }

        let font: Font = bold
            ? .system(size: 9, weight: .semibold)
            : .system(size: 9)

        var clipped = ctx
        clipped.clip(to: Path(rect))
        clipped.draw(
            Text(text).font(font).foregroundColor(textColor),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
        )
    }
}

private struct TreeMapUpdateID: Hashable {
    let rootID: UUID
    let revision: Int
}
