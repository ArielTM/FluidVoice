import Carbon.HIToolbox
import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

/// Covers the keycode-typing path used for remote-desktop targets, where clipboard
/// redirection is unusable because the client only re-advertises its clipboard after a focus
/// change.
final class RemoteDesktopTypingTests: XCTestCase {
    /// A deliberately small stand-in layout, so these tests do not depend on whatever keyboard
    /// the machine running them happens to have selected.
    private let asciiish: [Character: RemoteDesktopKeyStroke] = [
        "a": .init(keyCode: 0, needsShift: false),
        "A": .init(keyCode: 0, needsShift: true),
        "b": .init(keyCode: 11, needsShift: false),
        " ": .init(keyCode: 49, needsShift: false),
        "'": .init(keyCode: 39, needsShift: false),
        "\"": .init(keyCode: 39, needsShift: true),
        "-": .init(keyCode: 27, needsShift: false),
        ".": .init(keyCode: 47, needsShift: false),
    ]

    /// `.strokes` payload, or nil when the plan reported unmappable characters.
    private func strokes(_ text: String) -> [RemoteDesktopKeyStroke]? {
        switch RemoteDesktopKeyMapResolver.plan(for: text, map: self.asciiish) {
        case let .strokes(s): return s
        case .unmappable: return nil
        }
    }

    private func unmappable(_ text: String) -> [Character]? {
        switch RemoteDesktopKeyMapResolver.plan(for: text, map: self.asciiish) {
        case .strokes: return nil
        case let .unmappable(c): return c
        }
    }

    // MARK: - Transliteration

    func testSmartPunctuationIsTransliteratedToASCII() {
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("it\u{2019}s"), "it's")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("\u{201C}quoted\u{201D}"), "\"quoted\"")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("a\u{2014}b"), "a--b")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("a\u{2013}b"), "a-b")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("wait\u{2026}"), "wait...")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("a\u{00A0}b"), "a b")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("\u{2022} item"), "- item")
    }

    func testTransliterationLeavesPlainTextUntouched() {
        let plain = "Can you send me the quarterly report by Friday?"
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate(plain), plain)
    }

    func testTransliterationDoesNotInventReplacementsForRealNonASCII() {
        // Accented letters and emoji have no unambiguous ASCII spelling, so they must survive
        // untouched and be reported as unmappable rather than silently mangled.
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("caf\u{00E9}"), "caf\u{00E9}")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("hi \u{1F600}"), "hi \u{1F600}")
    }

    // MARK: - Stroke mapping

    func testStrokesSpellTheTextAndCarryShiftWhereNeeded() throws {
        let strokes = try XCTUnwrap(
            self.strokes("aAb")
        )
        XCTAssertEqual(strokes.map(\.keyCode), [0, 0, 11])
        XCTAssertEqual(strokes.map(\.needsShift), [false, true, false])
    }

    func testNewlinesAndTabsUseTheirOwnKeysRatherThanTheLayoutMap() throws {
        let strokes = try XCTUnwrap(
            self.strokes("a\nb\tb\r")
        )
        XCTAssertEqual(
            strokes.map(\.keyCode),
            [0, CGKeyCode(kVK_Return), 11, CGKeyCode(kVK_Tab), 11, CGKeyCode(kVK_Return)]
        )
        // Newline is Shift+Return: a bare Return submits in most chat clients, so a
        // multi-paragraph transcript typed with Return would send one partial message per line.
        XCTAssertEqual(strokes.map(\.needsShift), [false, true, false, false, false, true])
    }

    func testMappingIsAllOrNothing() {
        // A partially typed transcript is worse than none, so one unmappable character must
        // abort the whole attempt and let the caller fall back.
        XCTAssertNil(self.strokes("caf\u{00E9}"))
        XCTAssertNil(self.strokes("a\u{1F600}b"))
        XCTAssertNotNil(self.strokes("ab a"))
    }

    func testEmptyTextMapsToNoStrokes() throws {
        let strokes = try XCTUnwrap(self.strokes(""))
        XCTAssertTrue(strokes.isEmpty)
    }

    func testTransliteratedTextBecomesFullyTypeable() {
        // The point of transliteration: text that would otherwise abort now types cleanly.
        // Restricted to letters present in `asciiish` so this exercises transliteration
        // rather than the toy fixture's coverage.
        let raw = "ab\u{2019}a \u{201C}ba\u{201D}\u{2026}"
        XCTAssertNil(self.strokes(raw))
        let normalized = RemoteDesktopKeyMapResolver.transliterate(raw)
        XCTAssertNotNil(self.strokes(normalized))
    }

    // MARK: - Unmappable reporting

    func testUnmappableCharactersAreReportedOnceEachInOrder() throws {
        // 'c', 'f', 'l', 'i' and 'r' are absent from the toy fixture on purpose - the point is
        // first-occurrence order and de-duplication, not which letters a real layout has.
        let found = try XCTUnwrap(self.unmappable("caf\u{00E9} \u{00E9}clair \u{1F600}"))
        XCTAssertEqual(found, ["c", "f", "\u{00E9}", "l", "i", "r", "\u{1F600}"])
    }

    func testWhitespaceControlCharactersAreNotReportedAsUnmappable() {
        XCTAssertNil(self.unmappable("a\nb\tb\r"), "Newlines and tabs have their own keys")
        XCTAssertNil(self.unmappable("a\r\nb"), "CRLF is one grapheme cluster and must still map")
    }

    // MARK: - Layout resolution

    func testResolverReturnsEmptyMapForMissingLayoutData() {
        XCTAssertTrue(RemoteDesktopKeyMapResolver.resolve(layoutData: nil, keyboardType: 0).isEmpty)
        XCTAssertTrue(RemoteDesktopKeyMapResolver.resolve(layoutData: Data(), keyboardType: 0).isEmpty)
    }

    /// Reads an installed layout by identifier without enabling or switching any input source,
    /// so these assertions do not depend on which keyboard the running machine has selected.
    /// Same approach as `Tests/PasteKeyCodeResolverTests.swift`.
    private func installedLayout(_ identifier: String) throws -> Data {
        guard let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource] else {
            throw XCTSkip("Unable to enumerate installed keyboard layouts")
        }
        let match = sources.first { source in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == identifier
        }
        guard let match,
              let pointer = TISGetInputSourceProperty(match, kTISPropertyUnicodeKeyLayoutData)
        else {
            throw XCTSkip("Layout not installed: \(identifier)")
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    private func usMap() throws -> [Character: RemoteDesktopKeyStroke] {
        RemoteDesktopKeyMapResolver.resolve(
            layoutData: try self.installedLayout("com.apple.keylayout.US"),
            keyboardType: UInt32(LMGetKbdType())
        )
    }

    func testUSLayoutResolvesExpectedStrokes() throws {
        let map = try self.usMap()
        XCTAssertEqual(map["a"], RemoteDesktopKeyStroke(keyCode: 0, needsShift: false))
        XCTAssertEqual(map["A"], RemoteDesktopKeyStroke(keyCode: 0, needsShift: true))
        XCTAssertEqual(map["1"], RemoteDesktopKeyStroke(keyCode: 18, needsShift: false))
        XCTAssertEqual(map["!"], RemoteDesktopKeyStroke(keyCode: 18, needsShift: true))
        XCTAssertEqual(map["v"], RemoteDesktopKeyStroke(keyCode: 9, needsShift: false))
        XCTAssertEqual(map[" "], RemoteDesktopKeyStroke(keyCode: 49, needsShift: false))
    }

    func testUSLayoutCoversPrintableASCIIAndNothingElse() throws {
        let map = try self.usMap()
        for scalar in UInt32(0x20)...UInt32(0x7E) {
            let character = Character(UnicodeScalar(scalar)!)
            XCTAssertNotNil(map[character], "US layout must type U+\(String(scalar, radix: 16, uppercase: true))")
        }
        XCTAssertNil(map["\u{1F600}"], "No key press produces an emoji")
        XCTAssertNil(map["\u{00E9}"], "US layout cannot type a precomposed accented letter")
    }

    func testKeypadAndISOSectionKeysAreExcluded() throws {
        let map = try self.usMap()
        // '*' and '+' must come from Shift+8 and Shift+= rather than the keypad, which carries a
        // different scan code class than a person typing the same glyph.
        XCTAssertEqual(map["*"], RemoteDesktopKeyStroke(keyCode: 28, needsShift: true))
        XCTAssertEqual(map["+"], RemoteDesktopKeyStroke(keyCode: 24, needsShift: true))
        XCTAssertFalse(map.values.contains { (65...92).contains($0.keyCode) }, "No keypad key codes")
        XCTAssertFalse(map.values.contains { $0.keyCode == 10 }, "kVK_ISO_Section is excluded")
    }

    func testDeadKeysAreNotOfferedAsDirectlyTypeable() throws {
        // On US-International the quote and grave keys compose the next character instead of
        // typing a glyph, so offering them would silently corrupt text.
        let map = RemoteDesktopKeyMapResolver.resolve(
            layoutData: try self.installedLayout("com.apple.keylayout.USInternational-PC"),
            keyboardType: UInt32(LMGetKbdType())
        )
        guard !map.isEmpty else { throw XCTSkip("US-International layout unavailable") }
        for dead in ["\"", "'", "`", "\u{02C6}", "\u{02DC}"] {
            XCTAssertNil(map[Character(dead)], "Dead key \(dead) must not be typeable directly")
        }
        XCTAssertNotNil(map["a"], "Ordinary letters must still map")
    }

    func testUnshiftedStrokeIsPreferredWhenBothReachTheSameCharacter() throws {
        let map = try self.usMap()
        XCTAssertEqual(map[" "]?.needsShift, false)
        XCTAssertEqual(map["a"]?.needsShift, false)
    }

    // MARK: - Per-character delay parsing

    func testTypeDelayDefaultsAndClamps() {
        XCTAssertEqual(
            TypingService.remoteDesktopTypeDelayMicros(override: nil),
            useconds_t(TypingService.remoteDesktopTypeDelayDefaultMs * 1000)
        )
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: 5)), 5000)
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: 0)), 0)

        let maximum = useconds_t(TypingService.remoteDesktopTypeDelayMaximumMs * 1000)
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: Int32.max)), maximum)
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: -5)), 0)
    }
}
