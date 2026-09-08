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
            TypingService.remoteDesktopKeyStrokes(for: "aAb", map: self.asciiish)
        )
        XCTAssertEqual(strokes.map(\.keyCode), [0, 0, 11])
        XCTAssertEqual(strokes.map(\.needsShift), [false, true, false])
    }

    func testNewlinesAndTabsUseTheirOwnKeysRatherThanTheLayoutMap() throws {
        let strokes = try XCTUnwrap(
            TypingService.remoteDesktopKeyStrokes(for: "a\nb\tb\r", map: self.asciiish)
        )
        XCTAssertEqual(
            strokes.map(\.keyCode),
            [0, CGKeyCode(kVK_Return), 11, CGKeyCode(kVK_Tab), 11, CGKeyCode(kVK_Return)]
        )
        XCTAssertTrue(strokes.allSatisfy { !$0.needsShift })
    }

    func testMappingIsAllOrNothing() {
        // A partially typed transcript is worse than none, so one unmappable character must
        // abort the whole attempt and let the caller fall back.
        XCTAssertNil(TypingService.remoteDesktopKeyStrokes(for: "caf\u{00E9}", map: self.asciiish))
        XCTAssertNil(TypingService.remoteDesktopKeyStrokes(for: "a\u{1F600}b", map: self.asciiish))
        XCTAssertNotNil(TypingService.remoteDesktopKeyStrokes(for: "ab a", map: self.asciiish))
    }

    func testEmptyTextMapsToNoStrokes() throws {
        let strokes = try XCTUnwrap(TypingService.remoteDesktopKeyStrokes(for: "", map: self.asciiish))
        XCTAssertTrue(strokes.isEmpty)
    }

    func testTransliteratedTextBecomesFullyTypeable() {
        // The point of transliteration: text that would otherwise abort now types cleanly.
        // Restricted to letters present in `asciiish` so this exercises transliteration
        // rather than the toy fixture's coverage.
        let raw = "ab\u{2019}a \u{201C}ba\u{201D}\u{2026}"
        XCTAssertNil(TypingService.remoteDesktopKeyStrokes(for: raw, map: self.asciiish))
        let normalized = RemoteDesktopKeyMapResolver.transliterate(raw)
        XCTAssertNotNil(TypingService.remoteDesktopKeyStrokes(for: normalized, map: self.asciiish))
    }

    // MARK: - Unmappable reporting

    func testUnmappableCharactersAreReportedOnceEachInOrder() {
        let found = RemoteDesktopKeyMapResolver.unmappableCharacters(
            in: "caf\u{00E9} \u{00E9}clair \u{1F600}",
            map: self.asciiish
        )
        XCTAssertEqual(found, ["c", "f", "\u{00E9}", "l", "i", "r", "\u{1F600}"])
    }

    func testWhitespaceControlCharactersAreNotReportedAsUnmappable() {
        XCTAssertTrue(
            RemoteDesktopKeyMapResolver.unmappableCharacters(in: "a\nb\tb\r", map: self.asciiish).isEmpty
        )
    }

    // MARK: - Layout resolution

    func testResolverReturnsEmptyMapForMissingLayoutData() {
        XCTAssertTrue(RemoteDesktopKeyMapResolver.resolve(layoutData: nil, keyboardType: 0).isEmpty)
        XCTAssertTrue(RemoteDesktopKeyMapResolver.resolve(layoutData: Data(), keyboardType: 0).isEmpty)
    }

    func testLiveLayoutProducesATypeableASCIIRange() {
        // Guards the UCKeyTranslate reverse scan against silently returning nothing.
        let map = RemoteDesktopKeyMapResolver.current()
        guard !map.isEmpty else {
            return XCTFail("Expected a non-empty map for the active keyboard layout")
        }
        for character in "abcxyzABCXYZ0189 .,-'" {
            XCTAssertNotNil(map[character], "Latin layouts must be able to type \(character)")
        }
        XCTAssertNil(map["\u{1F600}"], "No key press produces an emoji")
    }

    func testUnshiftedStrokeIsPreferredWhenBothReachTheSameCharacter() throws {
        let map = RemoteDesktopKeyMapResolver.current()
        guard let space = map[" "] else { throw XCTSkip("Active layout has no space mapping") }
        XCTAssertFalse(space.needsShift, "Space must be typed without shift")
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
