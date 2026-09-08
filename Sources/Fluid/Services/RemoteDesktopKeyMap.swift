import AppKit
import Carbon.HIToolbox

/// One key press: a virtual key code, optionally with shift held.
struct RemoteDesktopKeyStroke: Equatable {
    let keyCode: CGKeyCode
    let needsShift: Bool
}

/// The result of spelling text out as key presses.
///
/// Modelled as a sum type rather than an optional array so the unmappable characters travel
/// with the failure and the caller can distinguish "cannot type this" from "did not try".
enum RemoteDesktopTypingPlan: Equatable {
    case strokes([RemoteDesktopKeyStroke])
    case unmappable([Character])
}

/// Maps characters to the key presses that produce them on the active keyboard layout, for
/// typing into a remote-desktop session.
///
/// Remote-desktop clients in Scancode mode forward key *positions* to the guest, so text can
/// only be delivered as real key codes - a unicode payload on a `virtualKey: 0` event has no
/// position to forward. That restricts what can be typed to characters the local layout can
/// produce with at most shift, which for a Latin layout is printable ASCII.
///
/// It also means the guest applies its *own* layout to those positions, so this is only correct
/// when the local and remote layouts agree. Non-Latin dictation needs the client's Unicode
/// keyboard mode instead, which is outside what this can influence.
enum RemoteDesktopKeyMapResolver {
    /// Virtual key codes for the numeric keypad. Excluded because they carry a different scan
    /// code class than the character keys a person would use for the same glyph, and nothing on
    /// a Latin layout is reachable only through them.
    private static let keypadKeyCodeRange: ClosedRange<UInt16> = 65...92

    /// `kVK_ISO_Section`. Excluded because ANSI Windows maps that position to backslash, so
    /// typing the glyph it produces on a Mac ISO layout would emit the wrong character.
    private static let isoSectionKeyCode: UInt16 = 10

    /// Substitutions applied before mapping, for characters that have an unambiguous plain-text
    /// spelling. These reach transcripts through AI enhancement rather than through speech, and
    /// normalising them is standard practice for destinations that only accept plain input.
    ///
    /// Every character left unmapped costs a focus-stealing clipboard fallback, so breadth here
    /// is worth having. Note for anyone extending this: two canonically-equivalent keys in a
    /// dictionary literal trap at runtime, so keep the keys to distinct single scalars.
    static let transliterations: [Character: String] = [
        // Quotes and apostrophes
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{2032}": "'", "\u{2033}": "\"",
        "\u{00AB}": "\"", "\u{00BB}": "\"",
        // Dashes and hyphens
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-",
        "\u{2013}": "-", "\u{2014}": "--", "\u{2015}": "--",
        "\u{2212}": "-",
        // Spaces
        "\u{00A0}": " ", "\u{2002}": " ", "\u{2003}": " ", "\u{2004}": " ",
        "\u{2005}": " ", "\u{2006}": " ", "\u{2007}": " ", "\u{2008}": " ",
        "\u{2009}": " ", "\u{200A}": " ", "\u{202F}": " ", "\u{3000}": " ",
        // Invisible characters that would otherwise force the fallback for no visible gain
        "\u{00AD}": "", "\u{200B}": "", "\u{200C}": "", "\u{200D}": "", "\u{FEFF}": "",
        // Line and paragraph separators
        "\u{2028}": "\n", "\u{2029}": "\n",
        // Miscellaneous
        "\u{2026}": "...", "\u{2022}": "-", "\u{00B7}": "-", "\u{2043}": "-",
        "\u{2192}": "->",
    ]

    /// Applies ``transliterations``, leaving everything else untouched.
    static func transliterate(_ text: String) -> String {
        guard text.contains(where: { self.transliterations[$0] != nil }) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            out += self.transliterations[character] ?? String(character)
        }
        return out
    }

    /// Physical key positions on a US/ANSI keyboard, as `(keyCode, unshifted, shifted)`.
    ///
    /// This is deliberately a fixed table rather than a lookup of the *local* layout. A client
    /// in Scancode mode forwards key positions and the guest applies its own layout: per
    /// Microsoft's documentation, scancode input "uses the keyboard layout of the remote
    /// session, not the keyboard of the local device". So the question is not "which local key
    /// produces this character" but "which position produces it on the guest", and the only
    /// answer available without inspecting the guest is the standard ANSI arrangement.
    ///
    /// Deriving the map from the local layout instead would silently corrupt text whenever the
    /// two disagree - a Cyrillic or Dvorak local layout would report characters as typeable
    /// whose positions mean something else in the guest. Using a fixed reference means such
    /// characters are simply absent from the map and take the lossless fallback.
    private static let ansiKeyPositions: [(keyCode: CGKeyCode, unshifted: Character, shifted: Character)] = [
        (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"),
        (5, "g", "G"), (6, "z", "Z"), (7, "x", "X"), (8, "c", "C"), (9, "v", "V"),
        (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"), (15, "r", "R"),
        (16, "y", "Y"), (17, "t", "T"), (31, "o", "O"), (32, "u", "U"), (34, "i", "I"),
        (35, "p", "P"), (37, "l", "L"), (38, "j", "J"), (40, "k", "K"), (45, "n", "N"),
        (46, "m", "M"),
        (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"), (23, "5", "%"),
        (22, "6", "^"), (26, "7", "&"), (28, "8", "*"), (25, "9", "("), (29, "0", ")"),
        (24, "=", "+"), (27, "-", "_"), (30, "]", "}"), (33, "[", "{"), (39, "'", "\""),
        (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"), (44, "/", "?"), (47, ".", ">"),
        (50, "`", "~"),
    ]

    /// Character to key press, built from ``ansiKeyPositions``. Unshifted wins where a
    /// character is reachable both ways.
    static let ansiKeyMap: [Character: RemoteDesktopKeyStroke] = {
        var map: [Character: RemoteDesktopKeyStroke] = [
            " ": RemoteDesktopKeyStroke(keyCode: CGKeyCode(kVK_Space), needsShift: false),
        ]
        for position in Self.ansiKeyPositions {
            if map[position.unshifted] == nil {
                map[position.unshifted] = RemoteDesktopKeyStroke(keyCode: position.keyCode, needsShift: false)
            }
            if map[position.shifted] == nil {
                map[position.shifted] = RemoteDesktopKeyStroke(keyCode: position.keyCode, needsShift: true)
            }
        }
        return map
    }()

    /// Spells `text` out as key presses, or reports every character that has no key on this
    /// layout.
    ///
    /// All-or-nothing on purpose: a partially typed transcript is worse than none, so the caller
    /// falls back rather than emitting a prefix.
    ///
    /// Return and Tab are deliberately **never typed** into a remote session; text containing
    /// them is reported as unmappable instead.
    ///
    /// Every other key this can press (codes 0-50: letters, digits, punctuation) only inserts a
    /// character. Return *commits* and Tab *moves focus*, so if the guest's focus is not a text
    /// field - a dialog, a menu, a search field - a transcript containing a newline can activate
    /// whatever happens to be highlighted. The guest exposes no accessibility information
    /// through the client, so there is no way to confirm where keystrokes are landing before
    /// sending them. Refusing to send an activating key bounds the worst case to "wrong text
    /// typed somewhere" rather than "an action taken in the guest".
    /// - Parameter capsLockActive: inverts shift for alphabetic characters. RDP synchronises
    ///   lock state between client and guest (`TS_SYNCHRONIZE_EVENT`), so when Caps Lock is on
    ///   the guest applies it to the forwarded scan codes and an unshifted `a` position arrives
    ///   as `A`. Without this the case of every letter is inverted.
    static func plan(
        for text: String,
        map: [Character: RemoteDesktopKeyStroke],
        capsLockActive: Bool = false
    ) -> RemoteDesktopTypingPlan {
        var strokes: [RemoteDesktopKeyStroke] = []
        strokes.reserveCapacity(text.count)
        var unmappable: [Character] = []
        var seenUnmappable: Set<Character> = []

        for character in text {
            switch character {
            case "\n", "\r", "\r\n", "\t":
                // Never typed - see the note above. "\r\n" is a single grapheme cluster in
                // Swift and is not equal to "\n", so it has to be matched explicitly.
                if seenUnmappable.insert(character).inserted { unmappable.append(character) }
            default:
                guard let stroke = map[character] else {
                    if seenUnmappable.insert(character).inserted { unmappable.append(character) }
                    continue
                }
                if capsLockActive, character.isLetter {
                    strokes.append(
                        RemoteDesktopKeyStroke(keyCode: stroke.keyCode, needsShift: !stroke.needsShift)
                    )
                } else {
                    strokes.append(stroke)
                }
            }
        }

        guard unmappable.isEmpty else { return .unmappable(unmappable) }
        return .strokes(strokes)
    }
}
