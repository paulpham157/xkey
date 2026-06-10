//
//  MacroManagerTests.swift
//  XKeyTests
//
//  Tests for MacroManager case-insensitive trigger and auto-caps output.
//

import XCTest
@testable import XKey

final class MacroManagerTests: XCTestCase {

    private var manager: MacroManager!

    override func setUp() {
        super.setUp()
        manager = MacroManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build a search key array as VNEngine would emit it after resolution:
    /// raw Unicode scalars tagged with CHAR_CODE_MASK so MacroManager's
    /// `getCharacterCode` returns the scalar directly.
    private func searchKey(_ str: String) -> [UInt32] {
        return str.unicodeScalars.map { UInt32($0.value) | VNEngine.CHAR_CODE_MASK }
    }

    /// Decode macro content codes back to a string (strips the 0x2000000 flag).
    private func decode(_ codes: [UInt32]) -> String {
        var result = ""
        for code in codes {
            let value = code & 0xFFFF
            if let scalar = UnicodeScalar(value) {
                result.append(Character(scalar))
            }
        }
        return result
    }

    // MARK: - Exact match

    func testExactLowercaseMatch() {
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        let result = manager.findMacro(key: searchKey("xrev"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "by the way")
    }

    func testNoMatchReturnsNil() {
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        XCTAssertNil(manager.findMacro(key: searchKey("nope")))
    }

    // MARK: - AutoCaps disabled

    func testAutoCapsDisabledIgnoresUppercase() {
        manager.setAutoCapsMacro(false)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        // Uppercase trigger should NOT match when auto-caps disabled.
        XCTAssertNil(manager.findMacro(key: searchKey("XREV")))
        XCTAssertNil(manager.findMacro(key: searchKey("Xrev")))
    }

    // MARK: - AutoCaps enabled

    func testAllCapsTriggerProducesAllCapsOutput() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        let result = manager.findMacro(key: searchKey("XREV"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "BY THE WAY")
    }

    func testFirstCharCapTriggerProducesTitleCase() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        let result = manager.findMacro(key: searchKey("Xrev"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "By The Way")
    }

    func testMixedCaseTriggerFallsBackToLowercase() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        // First char lowercase, second uppercase — neither all-caps nor first-cap.
        let result = manager.findMacro(key: searchKey("xRev"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "by the way")
    }

    // MARK: - Digit / punctuation in trigger

    func testAllCapsWithDigitInTrigger() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev1", content: "by the way"))
        // Digit is neutral; all letters uppercase → all-caps output.
        let result = manager.findMacro(key: searchKey("XREV1"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "BY THE WAY")
    }

    func testAllCapsWithPunctuationInTrigger() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xr-ev", content: "by the way"))
        let result = manager.findMacro(key: searchKey("XR-EV"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "BY THE WAY")
    }

    // MARK: - Single-letter trigger

    func testSingleUppercaseLetterTrigger() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "x", content: "hello world"))
        // Single letter uppercase → all-caps wins over title-case.
        let result = manager.findMacro(key: searchKey("X"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "HELLO WORLD")
    }

    // MARK: - Title case word boundaries

    func testTitleCaseMultipleWords() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "g", content: "good morning everyone"))
        let result = manager.findMacro(key: searchKey("G"))
        XCTAssertNotNil(result)
        // Single-letter trigger → all-caps wins.
        XCTAssertEqual(decode(result!), "GOOD MORNING EVERYONE")
    }

    func testTitleCaseWithLeadingSpace() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: " by the way"))
        let result = manager.findMacro(key: searchKey("Xrev"))
        XCTAssertNotNil(result)
        // Leading space — first non-space char gets cap.
        XCTAssertEqual(decode(result!), " By The Way")
    }

    func testTitleCasePreservesNonAlpha() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "hello, world!"))
        let result = manager.findMacro(key: searchKey("Xrev"))
        XCTAssertNotNil(result)
        // Comma is non-whitespace; "world" stays lowercase because it follows ", ".
        // Space before "world" resets atWordStart → W gets capitalized.
        XCTAssertEqual(decode(result!), "Hello, World!")
    }

    // MARK: - Vietnamese content

    func testAllCapsProducesVietnameseUppercase() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "vn", content: "việt nam"))
        let result = manager.findMacro(key: searchKey("VN"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "VIỆT NAM")
    }

    func testTitleCaseProducesVietnameseTitleCase() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "vn", content: "việt nam"))
        let result = manager.findMacro(key: searchKey("Vn"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "Việt Nam")
    }

    // MARK: - Macro existence

    func testHasMacroAndDelete() {
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        XCTAssertTrue(manager.hasMacro(text: "xrev"))
        XCTAssertTrue(manager.deleteMacro(text: "xrev"))
        XCTAssertFalse(manager.hasMacro(text: "xrev"))
        XCTAssertNil(manager.findMacro(key: searchKey("xrev")))
    }

    // MARK: - Yield to macOS Text Replacement

    func testYieldDisabledExpandsConflictingMacro() {
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        manager.setYieldToSystemReplacement(false)
        manager.setSystemReplacementShortcuts(["xrev"])
        XCTAssertNotNil(manager.findMacro(key: searchKey("xrev")))
    }

    func testYieldEnabledSkipsConflictingMacro() {
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        manager.setYieldToSystemReplacement(true)
        manager.setSystemReplacementShortcuts(["xrev"])
        XCTAssertNil(manager.findMacro(key: searchKey("xrev")))
    }

    func testYieldEnabledKeepsNonConflictingMacro() {
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        manager.setYieldToSystemReplacement(true)
        manager.setSystemReplacementShortcuts(["omw"])
        let result = manager.findMacro(key: searchKey("xrev"))
        XCTAssertNotNil(result)
        XCTAssertEqual(decode(result!), "by the way")
    }

    func testYieldSkipsAutoCapsMatchToo() {
        manager.setAutoCapsMacro(true)
        XCTAssertTrue(manager.addMacro(text: "xrev", content: "by the way"))
        manager.setYieldToSystemReplacement(true)
        manager.setSystemReplacementShortcuts(["xrev"])
        XCTAssertNil(manager.findMacro(key: searchKey("XREV")))
        XCTAssertNil(manager.findMacro(key: searchKey("Xrev")))
    }

    func testYieldComparesCaseInsensitively() {
        // Macro stored with mixed case still yields to a lowercased TR shortcut.
        XCTAssertTrue(manager.addMacro(text: "Xrev", content: "by the way"))
        // Baseline: the mixed-case macro must match at all before yield kicks in,
        // otherwise the Nil assertion below would pass vacuously.
        XCTAssertNotNil(manager.findMacro(key: searchKey("Xrev")))
        manager.setYieldToSystemReplacement(true)
        manager.setSystemReplacementShortcuts(["xrev"])
        XCTAssertNil(manager.findMacro(key: searchKey("Xrev")))
    }
}
