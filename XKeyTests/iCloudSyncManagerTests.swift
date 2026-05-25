//
//  iCloudSyncManagerTests.swift
//  XKeyTests
//
//  Covers the multi-key sync surface: envelope encoding, CRDT merge with tombstones,
//  first-enable detection, and manager push/pull lifecycle against a mock KVS.
//

import XCTest
@testable import XKey

// MARK: - Mock KVS

class MockKeyValueStore: KeyValueStoreProtocol {
    var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? { storage[key] }

    func setData(_ data: Data?, forKey key: String) {
        if let data = data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }

    @discardableResult func synchronize() -> Bool { true }
}

// MARK: - Helpers

private func makeIsolatedDefaults(_ tag: String = UUID().uuidString) -> UserDefaults {
    let suiteName = "XKeyTests.iCloudSync.\(tag)"
    let d = UserDefaults(suiteName: suiteName)!
    d.removePersistentDomain(forName: suiteName)
    return d
}

// MARK: - SyncCollectionPayload (CRDT merge)

final class SyncCollectionPayloadTests: XCTestCase {

    func testMergeKeepsNewerEntry() {
        let older = SyncEntry(id: "a", updatedAt: Date(timeIntervalSince1970: 100), data: Data("v1".utf8))
        let newer = SyncEntry(id: "a", updatedAt: Date(timeIntervalSince1970: 200), data: Data("v2".utf8))
        let merged = SyncCollectionPayload(entries: [older]).merged(with: SyncCollectionPayload(entries: [newer]))
        XCTAssertEqual(merged.entries.first?.data, Data("v2".utf8))
    }

    func testMergeUnionsDisjointEntries() {
        let a = SyncEntry(id: "a", data: Data())
        let b = SyncEntry(id: "b", data: Data())
        let merged = SyncCollectionPayload(entries: [a]).merged(with: SyncCollectionPayload(entries: [b]))
        XCTAssertEqual(Set(merged.entries.map(\.id)), Set(["a", "b"]))
    }

    func testTombstoneWinsOverOlderLiveEntry() {
        let live = SyncEntry(id: "a", updatedAt: Date(timeIntervalSince1970: 100), deleted: false, data: Data())
        let tomb = SyncEntry.tombstone(id: "a", at: Date(timeIntervalSince1970: 200))
        let merged = SyncCollectionPayload(entries: [live]).merged(with: SyncCollectionPayload(entries: [tomb]))
        XCTAssertEqual(merged.entries.first?.deleted, true)
        XCTAssertEqual(merged.liveEntries.count, 0)
    }

    func testLiveEntryWinsOverOlderTombstone() {
        let tomb = SyncEntry.tombstone(id: "a", at: Date(timeIntervalSince1970: 100))
        let live = SyncEntry(id: "a", updatedAt: Date(timeIntervalSince1970: 200), deleted: false, data: Data("v".utf8))
        let merged = SyncCollectionPayload(entries: [tomb]).merged(with: SyncCollectionPayload(entries: [live]))
        XCTAssertEqual(merged.liveEntries.count, 1)
        XCTAssertEqual(merged.liveEntries.first?.data, Data("v".utf8))
    }

    func testPrunedTombstonesDropsOldDeletions() {
        let now = Date()
        let ancient = SyncEntry.tombstone(id: "a", at: now.addingTimeInterval(-60 * 24 * 3600))
        let recent = SyncEntry.tombstone(id: "b", at: now.addingTimeInterval(-1 * 24 * 3600))
        let payload = SyncCollectionPayload(entries: [ancient, recent])
            .prunedTombstones(retention: 30 * 24 * 3600, now: now)
        XCTAssertEqual(Set(payload.entries.map(\.id)), Set(["b"]))
    }

    func testPrunedTombstonesKeepsLiveEntriesIndependentOfAge() {
        let now = Date()
        let oldLive = SyncEntry(id: "a", updatedAt: now.addingTimeInterval(-365 * 24 * 3600), deleted: false, data: Data())
        let payload = SyncCollectionPayload(entries: [oldLive])
            .prunedTombstones(retention: 30 * 24 * 3600, now: now)
        XCTAssertEqual(payload.entries.count, 1)
    }
}

// MARK: - SyncEnvelope

final class SyncEnvelopeTests: XCTestCase {

    func testRoundTripPreservesFields() throws {
        let payload = Data("hello".utf8)
        let env = SyncEnvelope(payload: payload, updatedAt: Date(timeIntervalSince1970: 1234))
        let data = try env.encoded()
        let decoded = try SyncEnvelope.decode(from: data)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.updatedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(decoded.schemaVersion, SyncSchema.currentVersion)
        XCTAssertFalse(decoded.deviceId.isEmpty)
    }

    func testForwardCompatGuardRejectsNewerSchema() throws {
        // Forge a higher-version envelope manually and verify the guard catches it.
        struct ForgedEnvelope: Codable {
            let schemaVersion: Int
            let deviceId: String
            let updatedAt: Date
            let payload: Data
        }
        let forged = ForgedEnvelope(
            schemaVersion: SyncSchema.currentVersion + 99,
            deviceId: "dev",
            updatedAt: Date(),
            payload: Data())
        let data = try PropertyListEncoder().encode(forged)
        let decoded = try SyncEnvelope.decode(from: data)
        XCTAssertFalse(decoded.isCompatibleWithCurrentSchema)
    }
}

// MARK: - SyncTombstoneStore

final class SyncTombstoneStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SyncTombstoneStore!

    override func setUp() {
        super.setUp()
        defaults = makeIsolatedDefaults()
        store = SyncTombstoneStore(defaults: defaults)
    }

    func testRecordPersists() {
        store.record(category: .macros, id: "abc")
        XCTAssertNotNil(store.all(for: .macros)["abc"])
    }

    func testRemoveDropsEntry() {
        store.record(category: .macros, id: "abc")
        store.remove(category: .macros, id: "abc")
        XCTAssertNil(store.all(for: .macros)["abc"])
    }

    func testPruneDropsOldTombstones() {
        let old = Date().addingTimeInterval(-60 * 24 * 3600)
        store.record(category: .macros, id: "old", at: old)
        store.record(category: .macros, id: "new")
        store.prune(category: .macros)
        XCTAssertNil(store.all(for: .macros)["old"])
        XCTAssertNotNil(store.all(for: .macros)["new"])
    }

    func testTombstoneEntriesAreFlaggedDeleted() {
        store.record(category: .macros, id: "x")
        let entries = store.tombstoneEntries(for: .macros)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].deleted)
        XCTAssertEqual(entries[0].id, "x")
    }
}

// MARK: - SyncCategory

final class SyncCategoryTests: XCTestCase {

    func testScalarsUsesWholeBlobMerge() {
        XCTAssertFalse(SyncCategory.scalars.usesPerEntryMerge)
    }

    func testCollectionCategoriesUsePerEntryMerge() {
        for c in [SyncCategory.macros, .rules, .excludedApps, .userDict] {
            XCTAssertTrue(c.usesPerEntryMerge, "\(c) should use per-entry merge")
        }
    }

    func testSoftQuotaBelowOneMB() {
        for c in SyncCategory.allCases {
            XCTAssertLessThan(c.softQuotaBytes, 1_048_576, "\(c) soft quota must stay under iCloud's 1 MB hard cap")
        }
    }
}

// MARK: - iCloudSyncManager — first-enable & lifecycle

final class iCloudSyncManagerTests: XCTestCase {

    private var mockStore: MockKeyValueStore!
    private var defaults: UserDefaults!
    private var tombstones: SyncTombstoneStore!
    private var sut: iCloudSyncManager!

    override func setUp() {
        super.setUp()
        mockStore = MockKeyValueStore()
        defaults = makeIsolatedDefaults()
        tombstones = SyncTombstoneStore(defaults: defaults)
        sut = iCloudSyncManager(store: mockStore, tombstones: tombstones, defaults: defaults)
    }

    override func tearDown() {
        sut._resetForTesting()
        sut = nil
        mockStore = nil
        defaults = nil
        tombstones = nil
        super.tearDown()
    }

    // MARK: Initial state

    func testInitialStatusIsDisabled() {
        XCTAssertEqual(sut.status, .disabled)
    }

    func testIsEnabledDefaultsFalse() {
        XCTAssertFalse(sut.isEnabled)
    }

    func testLastSyncDateDefaultsNil() {
        XCTAssertNil(sut.lastSyncDate)
    }

    func testSyncDataSizeBytesReturnsNilWhenEmpty() {
        XCTAssertNil(sut.syncDataSizeBytes)
    }

    // MARK: First-enable detection

    func testFirstEnableNoRemoteDataPushes() {
        // No remote data → enable should push and mark hasPushedBefore.
        sut.isEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "XKey.sync.hasPushedBefore"))
    }

    func testFirstEnableWithRemoteDataAwaitsUserChoice() {
        // Seed the store with a remote envelope so the manager detects existing data.
        let envelope = SyncEnvelope(payload: Data("remote".utf8))
        mockStore.storage[SyncCategory.scalars.rawValue] = try! envelope.encoded()

        sut.isEnabled = true
        // hasPushedBefore must stay false until user resolves the prompt.
        XCTAssertFalse(defaults.bool(forKey: "XKey.sync.hasPushedBefore"))
        // Categories with remote data should be reported for the prompt.
        XCTAssertEqual(sut.categoriesWithRemoteData(), [.scalars])
    }

    func testCancelFirstEnableTurnsToggleOff() {
        let envelope = SyncEnvelope(payload: Data("remote".utf8))
        mockStore.storage[SyncCategory.scalars.rawValue] = try! envelope.encoded()
        sut.isEnabled = true

        sut.applyFirstEnableChoice(.cancel)

        XCTAssertFalse(sut.isEnabled)
        XCTAssertEqual(sut.status, .disabled)
    }

    func testFirstEnableUseRemoteMarksHasPushed() {
        let envelope = SyncEnvelope(payload: Data())
        mockStore.storage[SyncCategory.scalars.rawValue] = try! envelope.encoded()
        sut.isEnabled = true

        sut.applyFirstEnableChoice(.useRemote)

        XCTAssertTrue(defaults.bool(forKey: "XKey.sync.hasPushedBefore"))
    }

    // MARK: Disable

    func testDisableSetsStatusToDisabled() {
        sut.isEnabled = true
        sut.isEnabled = false
        XCTAssertEqual(sut.status, .disabled)
    }

    // MARK: Schema guard

    func testPullSkipsIncompatibleEnvelope() throws {
        // Forge a forward-incompatible envelope on the wire.
        struct Forged: Codable {
            let schemaVersion: Int
            let deviceId: String
            let updatedAt: Date
            let payload: Data
        }
        let forged = Forged(schemaVersion: SyncSchema.currentVersion + 1, deviceId: "x", updatedAt: Date(), payload: Data())
        mockStore.storage[SyncCategory.scalars.rawValue] = try PropertyListEncoder().encode(forged)

        sut.isEnabled = true
        sut.applyFirstEnableChoice(.useRemote)

        // Expect an error status because the envelope was rejected.
        if case .error = sut.status { XCTAssertTrue(true) } else {
            XCTFail("Expected .error status after incompatible pull, got \(sut.status)")
        }
    }

    // MARK: Push category

    func testPushCategoryWritesEnvelopeForList() {
        sut.isEnabled = true
        defaults.set(true, forKey: "XKey.sync.hasPushedBefore")

        sut.pushCategory(.macros)
        let raw = mockStore.storage[SyncCategory.macros.rawValue]
        XCTAssertNotNil(raw, "List category push should write an envelope")
        let env = try? SyncEnvelope.decode(from: raw ?? Data())
        XCTAssertEqual(env?.schemaVersion, SyncSchema.currentVersion)
    }

    func testPushDoesNothingWhenDisabled() {
        sut.pushAll()
        XCTAssertNil(mockStore.storage[SyncCategory.macros.rawValue])
    }
}
