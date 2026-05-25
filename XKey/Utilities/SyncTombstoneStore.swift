//
//  SyncTombstoneStore.swift
//  XKey
//
//  Tracks locally-deleted entries so deletions propagate via per-entry merge.
//  Backed by UserDefaults — local-only, never synced (tombstones live inside the envelope payload instead).
//

import Foundation

final class SyncTombstoneStore {

    static let shared = SyncTombstoneStore()

    private let defaults: UserDefaults
    private let prefix = "XKey.sync.tombstones."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for category: SyncCategory) -> String {
        prefix + category.rawValue
    }

    /// All tombstones for a category as [entryID: deletedAt].
    func all(for category: SyncCategory) -> [String: Date] {
        guard let dict = defaults.dictionary(forKey: key(for: category)) as? [String: Date] else {
            return [:]
        }
        return dict
    }

    /// Record a deletion. Idempotent — last deletion timestamp wins.
    func record(category: SyncCategory, id: String, at: Date = Date()) {
        var current = all(for: category)
        current[id] = at
        defaults.set(current, forKey: key(for: category))
    }

    /// Drop a tombstone (e.g., when the same id is re-added).
    func remove(category: SyncCategory, id: String) {
        var current = all(for: category)
        current.removeValue(forKey: id)
        defaults.set(current, forKey: key(for: category))
    }

    /// Prune tombstones older than the category's retention window.
    func prune(category: SyncCategory, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-category.tombstoneRetention)
        let filtered = all(for: category).filter { $0.value >= cutoff }
        defaults.set(filtered, forKey: key(for: category))
    }

    /// Convert tombstones to SyncEntry records for inclusion in the outgoing collection payload.
    func tombstoneEntries(for category: SyncCategory) -> [SyncEntry] {
        all(for: category).map { id, deletedAt in
            SyncEntry.tombstone(id: id, at: deletedAt)
        }
    }

    func clear(category: SyncCategory) {
        defaults.removeObject(forKey: key(for: category))
    }

    func clearAll() {
        for c in SyncCategory.allCases { clear(category: c) }
    }
}
