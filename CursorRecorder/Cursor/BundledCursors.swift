import Foundation
import CoreGraphics

/// Cursor artwork available to the picker, each with a sensible default hotspot.
struct BundledCursor: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Either a bundled resource name or an absolute file path (user-folder cursors).
    let resource: String
    let hotspot: CGPoint

    var url: URL? {
        // An absolute file path (user-folder cursor, or a bundled file we resolved by path).
        if resource.hasPrefix("/"), FileManager.default.fileExists(atPath: resource) {
            return URL(fileURLWithPath: resource)
        }
        return Bundle.main.url(forResource: resource, withExtension: "png", subdirectory: "Cursors")
            ?? Bundle.main.url(forResource: resource, withExtension: "png")
    }
}

enum BundledCursors {
    /// All cursors shipped in the app's `Cursors` resource folder, discovered at runtime so
    /// new PNGs (e.g. the OpenScreen pack) appear without code changes.
    static var all: [BundledCursor] {
        guard let dir = Bundle.main.url(forResource: "Cursors", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let cursors = items
            .filter { $0.pathExtension.lowercased() == "png" }
            .map { url -> BundledCursor in
                let stem = url.deletingPathExtension().lastPathComponent
                return BundledCursor(
                    id: stem,
                    displayName: prettify(stem),
                    resource: url.path,
                    hotspot: hotspot(for: stem)
                )
            }

        // Stable ordering: the simple built-ins first, then everything else alphabetically.
        let priority = ["arrow", "dot", "ring"]
        return cursors.sorted { a, b in
            let pa = priority.firstIndex(of: a.id) ?? Int.max
            let pb = priority.firstIndex(of: b.id) ?? Int.max
            if pa != pb { return pa < pb }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    static func matching(url: URL?) -> BundledCursor? {
        guard let url else { return nil }
        return all.first { $0.url == url }
    }

    // MARK: - Heuristics

    /// Centered hotspot for round reticles; top-left tip for arrow/pointer styles.
    private static func hotspot(for id: String) -> CGPoint {
        let lower = id.lowercased()
        if lower.contains("dot") || lower.contains("ring") || lower.contains("reticle") {
            return CGPoint(x: 0.5, y: 0.5)
        }
        if lower == "arrow" { return CGPoint(x: 0.05, y: 0.03) }
        // OpenScreen-style arrows point from the top-left corner.
        return CGPoint(x: 0.12, y: 0.08)
    }

    private static func prettify(_ stem: String) -> String {
        stem.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
