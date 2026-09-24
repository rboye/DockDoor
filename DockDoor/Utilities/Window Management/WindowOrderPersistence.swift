import AppKit
import Defaults
import Foundation

enum WindowOrderPersistence {
    struct PersistedWindowEntry: Codable, Defaults.Serializable {
        let bundleIdentifier: String
        let windowTitle: String
        let lastAccessedTime: Date
        let creationTime: Date

        var key: String {
            "\(bundleIdentifier)|\(windowTitle)"
        }
    }

    private static let lock = NSLock()
    private static var cache: [String: PersistedWindowEntry]?

    static func getPersistedTimestamp(bundleIdentifier: String, windowTitle: String?) -> PersistedWindowEntry? {
        lock.lock()
        defer { lock.unlock() }

        if cache == nil {
            let entries = Defaults[.persistedWindowOrder]
            cache = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            DebugLogger.log("WindowOrderPersistence", details: "Loaded \(entries.count) persisted entries")
        }
        let targetKey = "\(bundleIdentifier)|\(windowTitle ?? "")"
        return cache?[targetKey]
    }

    static func saveOrder(from allWindows: [WindowInfo]) {
        var entries: [PersistedWindowEntry] = []

        for window in allWindows {
            guard let bundleId = window.app.bundleIdentifier else { continue }

            let entry = PersistedWindowEntry(
                bundleIdentifier: bundleId,
                windowTitle: window.windowName ?? "",
                lastAccessedTime: window.lastAccessedTime,
                creationTime: window.creationTime
            )
            entries.append(entry)
        }

        var seenKeys = Set<String>()
        var dedupedEntries: [PersistedWindowEntry] = []
        let sortedByRecent = entries.sorted { $0.lastAccessedTime > $1.lastAccessedTime }

        for entry in sortedByRecent {
            if !seenKeys.contains(entry.key) {
                seenKeys.insert(entry.key)
                dedupedEntries.append(entry)
            }
        }

        let finalEntries = Array(dedupedEntries.prefix(500))
        Defaults[.persistedWindowOrder] = finalEntries
        DebugLogger.log("WindowOrderPersistence", details: "Saved \(finalEntries.count) entries on quit")
    }
}

// MARK: - Manual (drag & drop) window order

extension Defaults.Keys {
    /// Per-app window order arranged by the user (bundle identifier -> window IDs, first = leftmost/topmost).
    static let manualWindowOrder = Key<[String: [Int]]>("manualWindowOrder", default: [:])
}

enum ManualWindowOrder {
    private static let maxWindowsPerApp = 200

    enum Step {
        case toFront
        case earlier
        case later
        case toEnd
    }

    /// Re-applies the user's arranged order on top of an already sorted list.
    /// Arranged windows keep their arranged positions; windows the user never arranged
    /// (e.g. newly opened ones) keep the base order and follow after the arranged ones.
    static func apply(to windows: [WindowInfo]) -> [WindowInfo] {
        guard windows.count > 1 else { return windows }
        let stored = Defaults[.manualWindowOrder]
        guard !stored.isEmpty else { return windows }

        var rankByID: [CGWindowID: Int] = [:]
        for (bundleID, ids) in stored where windows.contains(where: { $0.app.bundleIdentifier == bundleID }) {
            for (rank, id) in ids.enumerated() {
                rankByID[CGWindowID(truncatingIfNeeded: id)] = rank
            }
        }
        guard !rankByID.isEmpty else { return windows }

        return windows.enumerated().sorted { lhs, rhs in
            switch (rankByID[lhs.element.id], rankByID[rhs.element.id]) {
            case let (l?, r?):
                l != r ? l < r : lhs.offset < rhs.offset
            case (.some, .none):
                true
            case (.none, .some):
                false
            case (.none, .none):
                lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Stores `windows` (in display order) as the arranged order for their app(s).
    static func record(_ windows: [WindowInfo]) {
        var stored = Defaults[.manualWindowOrder]
        var grouped: [String: [Int]] = [:]
        for window in windows {
            guard let bundleID = window.app.bundleIdentifier, !window.isWindowlessApp else { continue }
            grouped[bundleID, default: []].append(Int(window.id))
        }
        for (bundleID, ids) in grouped {
            stored[bundleID] = Array(ids.prefix(maxWindowsPerApp))
        }
        Defaults[.manualWindowOrder] = stored
    }

    /// Forgets every arranged order (windows fall back to the configured sort order).
    static func clear() {
        Defaults[.manualWindowOrder] = [:]
    }

    /// Moves the window at `fromIndex` to `toIndex` in the dock preview that is currently shown and persists the result.
    @MainActor
    static func move(fromIndex: Int, toIndex: Int, in coordinator: PreviewStateCoordinator, dockPosition: DockPosition, bestGuessMonitor: NSScreen) {
        var list = coordinator.windows
        guard fromIndex != toIndex, list.indices.contains(fromIndex), list.indices.contains(toIndex) else { return }
        let moved = list.remove(at: fromIndex)
        list.insert(moved, at: toIndex)
        record(list)
        coordinator.setWindows(list, dockPosition: dockPosition, bestGuessMonitor: bestGuessMonitor)
    }

    /// Context-menu variant: moves `window` one step (or to an end) within the active dock preview.
    @MainActor
    static func move(_ window: WindowInfo, _ step: Step) {
        guard let shared = SharedPreviewWindowCoordinator.activeInstance else { return }
        let coordinator = shared.windowSwitcherCoordinator
        guard !coordinator.windowSwitcherActive,
              let fromIndex = coordinator.windows.firstIndex(where: { $0.id == window.id })
        else { return }
        let last = coordinator.windows.count - 1
        let toIndex: Int = switch step {
        case .toFront: 0
        case .earlier: max(0, fromIndex - 1)
        case .later: min(last, fromIndex + 1)
        case .toEnd: last
        }
        guard let monitor = coordinator.lastKnownBestGuessMonitor ?? NSScreen.main ?? NSScreen.screens.first else { return }
        move(fromIndex: fromIndex, toIndex: toIndex, in: coordinator, dockPosition: DockUtils.getDockPosition(), bestGuessMonitor: monitor)
    }
}
