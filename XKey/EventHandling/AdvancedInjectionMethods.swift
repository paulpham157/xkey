//
//  AdvancedInjectionMethods.swift
//  XKey
//
//  Advanced injection methods for special apps
//  These methods are ready to be integrated when needed
//

import Cocoa
import Carbon

// MARK: - Advanced Injection Methods (Library)
// Additional injection methods for specific apps. axDirect is integrated into
// the main flow via CharacterInjector.injectSync; selectAll is not (see Usage
// Example at the bottom of this file).

/// Advanced injection utilities for special cases
/// - selectAll: For apps with aggressive autocomplete (Arc browser)
/// - axDirect: For apps where synthetic keyboard events don't work (Spotlight, Firefox)
class AdvancedInjectionMethods {
    
    static let shared = AdvancedInjectionMethods()

    /// Event marker for XKey-injected events
    private let kEventMarker: Int64 = 0x584B4559  // "XKEY" in hex

    /// Session buffer for selectAll method - tracks full text typed in session
    private var sessionBuffer: String = ""

    /// Debug callback for logging
    var debugCallback: ((String) -> Void)?

    private init() {}
    
    // MARK: - Session Buffer Management
    
    /// Update session buffer with new composed text
    /// Called before injection to track full session text
    func updateSessionBuffer(backspace: Int, newText: String) {
        if backspace > 0 && sessionBuffer.count >= backspace {
            sessionBuffer.removeLast(backspace)
        }
        sessionBuffer.append(newText)
    }
    
    /// Clear session buffer (call on focus change, submit, etc.)
    func clearSessionBuffer() {
        sessionBuffer = ""
    }
    
    /// Set session buffer to specific value (for restoring after paste, etc.)
    func setSessionBuffer(_ text: String) {
        sessionBuffer = text
    }
    
    /// Get current session buffer
    func getSessionBuffer() -> String {
        return sessionBuffer
    }
    
    // MARK: - Select All Injection
    // For apps with aggressive autocomplete (Arc browser)
    // Instead of backspace + text, this method:
    // 1. Selects all text (Cmd+Home + Shift+Cmd+End)
    // 2. Types the full session buffer to replace
    
    /// Select All injection: Select all text then type full session buffer
    /// Used for apps with aggressive autocomplete (Arc, Spotlight on macOS 13)
    /// Session buffer tracks ALL text typed in this session, not just current word
    ///
    /// - Parameter proxy: Event tap proxy for posting events
    func injectViaSelectAll(proxy: CGEventTapProxy) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        
        // Get full session buffer (all text typed in this session)
        let fullText = sessionBuffer
        guard !fullText.isEmpty else { return }
        
        // Select all using Cmd+Left (home) + Shift+Cmd+Right (select to end)
        // This works better in Arc browser than Cmd+A
        let leftArrowKeyCode: CGKeyCode = CGKeyCode(VietnameseData.KEY_LEFT)
        let rightArrowKeyCode: CGKeyCode = CGKeyCode(VietnameseData.KEY_RIGHT)
        
        // Cmd+Left = Home
        postKey(leftArrowKeyCode, source: source, flags: .maskCommand, proxy: proxy)
        usleep(5000)
        
        // Shift+Cmd+Right = Select to end
        postKey(rightArrowKeyCode, source: source, flags: [.maskCommand, .maskShift], proxy: proxy)
        usleep(5000)
        
        // Type full session buffer (replaces all selected text)
        postText(fullText, source: source, proxy: proxy)
    }
    
    // MARK: - AX Direct Injection
    // For overlay search fields (Spotlight/Raycast/Alfred) and Firefox-style content
    // areas where synthetic keyboard events race with inline autocomplete.
    // Uses the Accessibility API to replace text atomically — immune to that race.

    /// AX API injection: directly replace text in the focused field via Accessibility API.
    ///
    /// All offset arithmetic is done in **UTF-16 code units** because AX reports
    /// `kAXSelectedTextRange` in UTF-16. Vietnamese diacritics make grapheme count
    /// differ from UTF-16 count, so mixing the two (as a naive `String.count` would)
    /// corrupts the cut positions. We use `NSString`, whose indices are UTF-16 native.
    ///
    /// Two strategies are attempted (mirroring battle-tested IME behavior):
    ///   1. Selection-based: set `kAXSelectedTextRange` over the chars to replace
    ///      (including any auto-selected autocomplete suggestion), then set
    ///      `kAXSelectedText`. Cleanest; preserves the field's own undo/scroll state.
    ///   2. Full-value rewrite: read `kAXValue`, splice, write it back, restore caret.
    ///      Used when the field rejects selection-based editing.
    ///
    /// - Parameters:
    ///   - bs: Number of UTF-16 code units to delete before the cursor.
    ///     Callers pass backspace-key counts; the two match because injected
    ///     Vietnamese is precomposed BMP (1 key press == 1 UTF-16 unit). A field
    ///     holding decomposed (NFD) content would be under-deleted — acceptable,
    ///     since XKey itself always writes precomposed text.
    ///   - text: Replacement text to insert
    /// - Returns: true if successful, false if caller should fall back to synthetic events
    func injectViaAX(bs: Int, text: String) -> Bool {
        // Get focused element
        guard let axEl = AXHelper.getFocusedElement() else {
            debugCallback?("[AX] No focused element")
            return false
        }

        // Cap per-call AX IPC latency on this element, tighter than the process-wide
        // default set at startup (AXHelper.setGlobalMessagingTimeout): injection runs
        // synchronously on the event-tap thread for every keystroke, so an
        // unresponsive app (e.g. Spotlight mid-search) must fail fast here.
        AXUIElementSetMessagingTimeout(axEl, 0.1)

        // Field length in UTF-16 units. kAXNumberOfCharacters is a cheap scalar
        // query; reading kAXValue copies the whole field content, so defer that to
        // Strategy 2 — its only consumer.
        var cachedFullText: NSString?
        let total: Int
        if let count = AXHelper.getInt(axEl, attribute: kAXNumberOfCharactersAttribute as CFString) {
            total = count
        } else if let value = AXHelper.getString(axEl, attribute: kAXValueAttribute) {
            let ns = value as NSString
            cachedFullText = ns
            total = ns.length
        } else {
            debugCallback?("[AX] No character count or value attribute")
            return false
        }

        // Read cursor position and selection (UTF-16 offsets)
        guard let range = AXHelper.getRange(axEl, attribute: kAXSelectedTextRangeAttribute),
              range.location >= 0 else {
            debugCallback?("[AX] No selected text range")
            return false
        }

        // Clamp defensively against stale/inconsistent AX reports.
        let cursor = min(range.location, total)
        let selection = max(0, min(range.length, total - cursor))

        // Autocomplete handling: when selection > 0, the text from the cursor onward is
        // the inline suggestion the overlay auto-selected (e.g. "a|rc://..." where "|" is
        // the cursor and "rc://..." is selected). We replace the chars before the cursor
        // AND that selected suggestion together so it does not linger.
        let deleteStart = max(0, cursor - bs)
        let replaceLength = (cursor - deleteStart) + selection

        // Bounds check before touching the field.
        guard deleteStart >= 0, deleteStart + replaceLength <= total else {
            debugCallback?("[AX] Range out of bounds (start=\(deleteStart) len=\(replaceLength) total=\(total))")
            return false
        }

        let insert = text.precomposedStringWithCanonicalMapping

        // --- Strategy 1: selection-based replacement (surgical) ---
        // Two AX writes (set range, then set text), so not strictly atomic: the app's
        // own async suggestion refresh can still mutate the field between them. The
        // window is far smaller than the synthetic-event path, but not zero.
        var replaceRange = CFRange(location: deleteStart, length: replaceLength)
        var selectionMutated = false
        if let replaceRangeVal = AXValueCreate(.cfRange, &replaceRange),
           AXHelper.setValue(axEl, attribute: kAXSelectedTextRangeAttribute, value: replaceRangeVal) == .success {
            selectionMutated = true
            if AXHelper.setValue(axEl, attribute: kAXSelectedTextAttribute, value: insert as CFTypeRef) == .success {
                debugCallback?("[AX] Success (selection): bs=\(bs), text=\"\(text)\"")
                return true
            }
        }

        // If Strategy 1 moved the selection but could not complete the edit, restore
        // the original selection before giving up — otherwise the synthetic fallback's
        // first delete would wipe the whole leftover selection and over-delete.
        func restoreOriginalSelection() {
            guard selectionMutated else { return }
            var original = CFRange(location: cursor, length: selection)
            if let originalVal = AXValueCreate(.cfRange, &original) {
                AXHelper.setValue(axEl, attribute: kAXSelectedTextRangeAttribute, value: originalVal)
            }
        }

        // --- Strategy 2: full-value rewrite (fallback for stubborn fields) ---
        // Strategy 1 only touched the selection, never the value, so a value read
        // here is still consistent with `total` unless the app changed it under us
        // (guarded below).
        guard let fullText = cachedFullText
                ?? AXHelper.getString(axEl, attribute: kAXValueAttribute).map({ $0 as NSString }),
              fullText.length == total else {
            debugCallback?("[AX] Value unavailable or stale for full rewrite")
            restoreOriginalSelection()
            return false
        }
        let prefix = fullText.substring(to: deleteStart)
        let suffix = fullText.substring(from: deleteStart + replaceLength)
        let newText = (prefix + insert + suffix).precomposedStringWithCanonicalMapping

        guard AXHelper.setValue(axEl, attribute: kAXValueAttribute, value: newText as CFTypeRef) == .success else {
            debugCallback?("[AX] Write failed (both strategies)")
            restoreOriginalSelection()
            return false
        }

        // Restore caret to the end of the inserted text. Computed from the recomposed
        // prefix+insert because canonical recomposition can merge characters across
        // the boundary, shifting UTF-16 offsets.
        var caret = CFRange(
            location: ((prefix + insert).precomposedStringWithCanonicalMapping as NSString).length,
            length: 0
        )
        if let caretVal = AXValueCreate(.cfRange, &caret) {
            AXHelper.setValue(axEl, attribute: kAXSelectedTextRangeAttribute, value: caretVal)
        }

        debugCallback?("[AX] Success (full value): bs=\(bs), text=\"\(text)\"")
        return true
    }
    
    /// Try AX injection with retries, fallback to callback if all fail
    /// Spotlight/Raycast/Alfred can be busy searching, causing AX API to fail temporarily
    ///
    /// - Parameters:
    ///   - bs: Number of UTF-16 code units to delete before the cursor
    ///   - text: Replacement text to insert
    ///   - fallback: Closure to call if AX injection fails (synthetic-event path)
    /// - Note: Integrated via CharacterInjector.injectSync (.axDirect) for overlay
    ///   launchers and Firefox-style address bars.
    func injectViaAXWithFallback(bs: Int, text: String, fallback: () -> Void) {
        // Try AX API up to 3 times (Spotlight might be busy), but stop retrying
        // once ~250ms have elapsed: we run synchronously on the event-tap thread,
        // and retries only help with transient failures — a consistently slow app
        // should drop to the synthetic fallback instead of stalling input.
        let retryDeadline = DispatchTime.now() + .milliseconds(250)
        for attempt in 0..<3 {
            if attempt > 0 {
                if DispatchTime.now() >= retryDeadline {
                    debugCallback?("[AX] Retry budget exhausted")
                    break
                }
                usleep(5000)  // 5ms delay before retry
            }
            if injectViaAX(bs: bs, text: text) {
                return  // Success!
            }
        }
        
        // All AX attempts failed - call fallback
        debugCallback?("[AX] Fallback to synthetic events")
        fallback()
    }
    
    // MARK: - Private Helpers
    
    /// Post a single key press event
    private func postKey(_ keyCode: CGKeyCode, source: CGEventSource, flags: CGEventFlags = [], proxy: CGEventTapProxy? = nil) {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        
        keyDown.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
        
        if !flags.isEmpty {
            keyDown.flags = flags
            keyUp.flags = flags
        }
        
        if let proxy = proxy {
            keyDown.tapPostEvent(proxy)
            keyUp.tapPostEvent(proxy)
        } else {
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }
    
    /// Post text in chunks (CGEvent has 20-char limit)
    private func postText(_ text: String, source: CGEventSource, delay: UInt32 = 0, proxy: CGEventTapProxy? = nil) {
        let utf16 = Array(text.utf16)
        var offset = 0
        let chunkSize = 20
        
        while offset < utf16.count {
            let end = min(offset + chunkSize, utf16.count)
            var chunk = Array(utf16[offset..<end])
            
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { break }
            
            keyDown.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
            keyUp.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            
            if let proxy = proxy {
                keyDown.tapPostEvent(proxy)
                keyUp.tapPostEvent(proxy)
            } else {
                keyDown.post(tap: .cgSessionEventTap)
                keyUp.post(tap: .cgSessionEventTap)
            }
            
            if delay > 0 { usleep(delay) }
            offset = end
        }
    }
}

// MARK: - Usage Example
/*
 
 To integrate selectAll method:
 1. Add `.selectAll` to InjectionMethod enum in AppBehaviorDetector.swift
 2. Configure apps that need it in detectMethodForBundleId()
 3. In CharacterInjector.injectSync(), add case for .selectAll:
 
    case .selectAll:
        AdvancedInjectionMethods.shared.updateSessionBuffer(backspace: backspaceCount, newText: charPreview)
        AdvancedInjectionMethods.shared.injectViaSelectAll(proxy: proxy)
 
 To integrate axDirect method:
 1. Add `.axDirect` to InjectionMethod enum in AppBehaviorDetector.swift
 2. Configure apps that need it (Spotlight, Firefox, Arc)
 3. In CharacterInjector.injectSync(), add case for .axDirect:
 
    case .axDirect:
        AdvancedInjectionMethods.shared.injectViaAXWithFallback(bs: backspaceCount, text: charPreview) {
            // Fallback to autocomplete method
            injectViaAutocompleteInternal(count: backspaceCount, delays: delays, proxy: proxy)
            sendTextChunkedInternal(charPreview, delay: delays.text, proxy: proxy, useDirectPost: false)
        }
 
 */
