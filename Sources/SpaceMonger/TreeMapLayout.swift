import CoreGraphics

/// A single rectangle in the treemap display, ready to be drawn.
struct DisplayNode {
    let name: String
    let fileNode: FileNode
    let rect: CGRect
    let depth: Int          // nesting level (0 = top-level children of root)
    let isDirectory: Bool
}

/// Pure layout engine — no drawing, no state.
///
/// Ports the greedy balanced-split treemap algorithm from SizeFolders() in
/// FolderView.cpp.  The original algorithm:
///   1. Items arrive pre-sorted by size (largest first).
///   2. Greedily assign each item to whichever of two lists has the smaller
///      running sum — this produces two groups of roughly equal total size.
///   3. The rectangle is split proportionally to the two sums.
///   4. Recurse into each half.
///   5. When a single item is a directory, recurse into its children inside
///      an inset rect (leaving room for the title bar).
enum TreeMapLayoutEngine {
    static let minRectSize: CGFloat = 3    // skip rects smaller than this
    static let titleHeight: CGFloat = 14   // directory title bar height
    static let border: CGFloat      = 1    // directory border width

    // MARK: - Public entry point

    static func layout(root: FileNode, in bounds: CGRect) -> [DisplayNode] {
        var nodes: [DisplayNode] = []
        let items = root.children.filter { $0.totalSize > 0 }
        layoutItems(items, in: bounds, depth: 0, nodes: &nodes)
        return nodes
    }

    // MARK: - Recursive layout

    private static func layoutItems(
        _ items: [FileNode],
        in rect: CGRect,
        depth: Int,
        nodes: inout [DisplayNode]
    ) {
        guard !items.isEmpty else { return }
        guard rect.width >= minRectSize, rect.height >= minRectSize else { return }

        if items.count == 1 {
            let item = items[0]
            nodes.append(DisplayNode(
                name: item.name,
                fileNode: item,
                rect: rect,
                depth: depth,
                isDirectory: item.isDirectory
            ))
            if item.isDirectory {
                let inner = innerRect(for: rect)
                let children = item.children.filter { $0.totalSize > 0 }
                if inner.width >= minRectSize, inner.height >= minRectSize {
                    layoutItems(children, in: inner, depth: depth + 1, nodes: &nodes)
                }
            }
            return
        }

        // ── Greedy balanced partition ──────────────────────────────────────
        // Items are already sorted largest-first from sortChildrenBySize().
        // Assigning alternately to whichever list is smaller quickly balances
        // the two groups (the same greedy heuristic used in the original).
        var list1: [FileNode] = []
        var list2: [FileNode] = []
        var sum1: Int64 = 0
        var sum2: Int64 = 0

        for item in items {
            if sum1 <= sum2 {
                list1.append(item)
                sum1 += item.totalSize
            } else {
                list2.append(item)
                sum2 += item.totalSize
            }
        }

        let totalSize = sum1 + sum2
        guard totalSize > 0 else { return }

        // Split ratio proportional to sum1 vs sum2
        let ratio = CGFloat(sum1) / CGFloat(totalSize)

        let rect1: CGRect
        let rect2: CGRect

        if rect.width >= rect.height {
            // Horizontal split — matches original's bias logic defaulting to
            // splitting along the longer axis.
            let splitX = (rect.minX + rect.width * ratio).rounded()
            rect1 = CGRect(x: rect.minX,  y: rect.minY,
                           width: splitX - rect.minX,  height: rect.height)
            rect2 = CGRect(x: splitX,     y: rect.minY,
                           width: rect.maxX - splitX,  height: rect.height)
        } else {
            // Vertical split
            let splitY = (rect.minY + rect.height * ratio).rounded()
            rect1 = CGRect(x: rect.minX, y: rect.minY,
                           width: rect.width, height: splitY - rect.minY)
            rect2 = CGRect(x: rect.minX, y: splitY,
                           width: rect.width, height: rect.maxY - splitY)
        }

        if !list1.isEmpty { layoutItems(list1, in: rect1, depth: depth, nodes: &nodes) }
        if !list2.isEmpty { layoutItems(list2, in: rect2, depth: depth, nodes: &nodes) }
    }

    // MARK: - Helpers

    /// Returns the usable inner rect of a directory node (below the title bar,
    /// inside the border).
    static func innerRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + border,
            y: rect.minY + titleHeight,
            width:  rect.width  - border * 2,
            height: rect.height - titleHeight - border
        )
    }

    /// Hit-test: returns the deepest (last in list) node whose rect contains
    /// the given point.  The list is in DFS pre-order so later entries are
    /// deeper; reversing finds the innermost node first.
    static func hitTest(point: CGPoint, in nodes: [DisplayNode]) -> DisplayNode? {
        for node in nodes.reversed() {
            if node.rect.contains(point) { return node }
        }
        return nil
    }
}
