//
//  iCloudSyncTypes.swift
//  XKey
//
//  Foundation types for multi-key iCloud sync with CRDT-lite per-entry merge.
//

import Foundation

// MARK: - Schema

enum SyncSchema {
    /// Bump when payload format changes incompatibly. Older clients must refuse to pull.
    static let currentVersion: Int = 1
}

// MARK: - Categories

/// Categories of synced data. Each maps to a dedicated NSUbiquitousKeyValueStore key
/// so the 1 MB per-key limit applies separately and partial pushes are possible.
enum SyncCategory: String, CaseIterable {
    case scalars      = "XKey.sync.scalars"       // boolean/string/hotkey settings
    case macros       = "XKey.sync.macros"        // [MacroItem]
    case rules        = "XKey.sync.windowRules"   // [WindowTitleRule]
    case excludedApps = "XKey.sync.excludedApps"  // [ExcludedApp]
    case userDict     = "XKey.sync.userDict"      // Set<String>

    /// Tombstone retention after entry was deleted.
    var tombstoneRetention: TimeInterval { 30 * 24 * 3600 }

    /// Scalars use whole-blob LWW, lists use per-entry CRDT merge.
    var usesPerEntryMerge: Bool {
        switch self {
        case .scalars: return false
        default: return true
        }
    }

    /// Soft warning threshold (90% of Apple's 1 MB per-key budget).
    var softQuotaBytes: Int { 950_000 }
}

// MARK: - Device identifier

/// Stable identifier for this Mac. Local-only, never synced.
enum SyncDeviceID {
    private static let key = "XKey.sync.deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}

// MARK: - Envelope

/// Outer container persisted to KVS for every category.
/// Carries enough metadata to detect schema drift and decide merge direction.
struct SyncEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let deviceId: String
    let updatedAt: Date
    let payload: Data

    init(payload: Data, updatedAt: Date = Date()) {
        self.schemaVersion = SyncSchema.currentVersion
        self.deviceId = SyncDeviceID.current
        self.updatedAt = updatedAt
        self.payload = payload
    }

    func encoded() throws -> Data {
        // Binary plist is ~50% smaller than XML for payloads that contain Data fields
        // (XML base64-encodes them). Smaller payloads mean more headroom under the 1 MB KVS cap.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> SyncEnvelope {
        try PropertyListDecoder().decode(SyncEnvelope.self, from: data)
    }

    /// Older schema = ignore. Newer schema = refuse to consume (forward-compat guard).
    var isCompatibleWithCurrentSchema: Bool {
        schemaVersion == SyncSchema.currentVersion
    }
}

// MARK: - Per-entry record (collections only)

struct SyncEntry: Codable, Equatable {
    let id: String
    let updatedAt: Date
    let deleted: Bool
    let data: Data?

    init(id: String, updatedAt: Date = Date(), deleted: Bool = false, data: Data? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.data = data
    }

    static func tombstone(id: String, at: Date = Date()) -> SyncEntry {
        SyncEntry(id: id, updatedAt: at, deleted: true, data: nil)
    }
}

// MARK: - Collection payload

/// Inner payload for list-style categories. Decodes from envelope.payload.
struct SyncCollectionPayload: Codable, Equatable {
    var entries: [SyncEntry]

    init(entries: [SyncEntry] = []) {
        self.entries = entries
    }

    /// Per-entry last-write-wins merge. Tombstones win over live entries with older timestamps,
    /// which is how deletes propagate across devices.
    func merged(with other: SyncCollectionPayload) -> SyncCollectionPayload {
        var map: [String: SyncEntry] = [:]
        for e in entries { map[e.id] = e }
        for e in other.entries {
            if let existing = map[e.id] {
                map[e.id] = e.updatedAt > existing.updatedAt ? e : existing
            } else {
                map[e.id] = e
            }
        }
        return SyncCollectionPayload(entries: Array(map.values))
    }

    /// Drop tombstones older than retention window so payload doesn't grow unbounded.
    func prunedTombstones(retention: TimeInterval, now: Date = Date()) -> SyncCollectionPayload {
        let cutoff = now.addingTimeInterval(-retention)
        let kept = entries.filter { entry in
            !(entry.deleted && entry.updatedAt < cutoff)
        }
        return SyncCollectionPayload(entries: kept)
    }

    /// Live (non-deleted) entries only. Used when reconstructing local store.
    var liveEntries: [SyncEntry] {
        entries.filter { !$0.deleted }
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> SyncCollectionPayload {
        try PropertyListDecoder().decode(SyncCollectionPayload.self, from: data)
    }
}

// MARK: - Status per category

enum SyncCategoryStatus: Equatable {
    case disabled
    case idle
    case pushing
    case pulling
    case synced(Date)
    case error(String)
    case quotaExceeded
}

// MARK: - First-enable decision

enum SyncFirstEnableDecision: Equatable {
    case noRemoteData         // safe to push local immediately
    case remoteHasData        // need user to pick action
}

enum SyncFirstEnableAction: Equatable {
    case useLocal             // push local, overwrite remote
    case useRemote            // pull remote, overwrite local
    case merge                // CRDT merge for collections, newer-wins for scalars
    case cancel
}

// MARK: - Aggregated status (UI-facing)

/// Single status surfaced to the UI, derived from per-category statuses.
enum iCloudSyncStatus: Equatable {
    case disabled
    case idle
    case pushing
    case pulling
    case synced
    case error(String)
}

// MARK: - Key-value store abstraction

/// Indirection over NSUbiquitousKeyValueStore so the manager is testable without iCloud entitlements.
protocol KeyValueStoreProtocol: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStoreProtocol {
    func setData(_ data: Data?, forKey key: String) {
        set(data, forKey: key)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let iCloudSyncStatusDidChange = Notification.Name("XKey.iCloudSyncStatusDidChange")
    /// Posted when first-enable detects pre-existing remote data and needs user direction.
    /// UserInfo: ["categoriesWithRemote": [String]]
    static let iCloudSyncFirstEnablePrompt = Notification.Name("XKey.iCloudSyncFirstEnablePrompt")
}
