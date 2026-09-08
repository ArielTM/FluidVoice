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

    static func current() -> [Character: RemoteDesktopKeyStroke] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return self.resolve(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
    }

    static func resolve(layoutData: Data?, keyboardType: UInt32) -> [Character: RemoteDesktopKeyStroke] {
        guard let layoutData, !layoutData.isEmpty else { return [:] }
        return layoutData.withUnsafeBytes { bytes -> [Character: RemoteDesktopKeyStroke] in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return [:]
            }

            var map: [Character: RemoteDesktopKeyStroke] = [:]
            // Unshifted first, so a character reachable both ways prefers the simpler stroke.
            for needsShift in [false, true] {
                let modifiers = needsShift ? UInt32(shiftKey >> 8) : 0
                for key: UInt16 in 0..<128 {
                    guard self.keypadKeyCodeRange.contains(key) == false,
                          key != self.isoSectionKeyCode
                    else { continue }

                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    // Deliberately not `kUCKeyTranslateNoDeadKeysMask`: that mask reports a dead
                    // key's standalone glyph, which would map e.g. `"` on US-International to a
                    // key that actually composes the next character instead of typing a quote.
                    let status = UCKeyTranslate(
                        layout,
                        key,
                        UInt16(kUCKeyActionDisplay),
                        modifiers,
                        keyboardType,
                        0,
                        &deadKeyState,
                        characters.count,
                        &length,
                        &characters
                    )
                    guard status == noErr, deadKeyState == 0, length == 1 else { continue }
                    let scalarValue = characters[0]
                    // Printable only: control codes and delete are delivered as their own keys.
                    guard scalarValue >= 0x20, scalarValue != 0x7f,
                          let scalar = UnicodeScalar(scalarValue)
                    else { continue }
                    let character = Character(scalar)
                    if map[character] == nil {
                        map[character] = RemoteDesktopKeyStroke(keyCode: CGKeyCode(key), needsShift: needsShift)
                    }
                }
            }
            return map
        }
    }

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
    static func plan(
        for text: String,
        map: [Character: RemoteDesktopKeyStroke]
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
                strokes.append(stroke)
            }
        }

        guard unmappable.isEmpty else { return .unmappable(unmappable) }
        return .strokes(strokes)
    }
}

/// Process-wide snapshot of the layout map, refreshed at launch and on input-source changes.
/// Mirrors `PasteKeyCodeCache`: typing requests only read the snapshot and never touch the
/// main queue.
final class RemoteDesktopKeyMapCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [Character: RemoteDesktopKeyStroke] = [:]
    private var observer: NSObjectProtocol?
    private let resolve: () -> [Character: RemoteDesktopKeyStroke]
    private let notificationName: Notification.Name
    private var refreshScheduled = false

    init(
        notificationName: Notification.Name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        resolve: @escaping () -> [Character: RemoteDesktopKeyStroke] = { RemoteDesktopKeyMapResolver.current() }
    ) {
        self.notificationName = notificationName
        self.resolve = resolve
    }

    func start() {
        precondition(Thread.isMainThread)
        guard self.observer == nil else { return }
        self.observer = DistributedNotificationCenter.default().addObserver(
            forName: self.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        self.refresh()
    }

    private func scheduleRefresh() {
        precondition(Thread.isMainThread)
        guard !self.refreshScheduled else { return }
        self.refreshScheduled = true
        // Let TIS process the source-change event before reading its current layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        precondition(Thread.isMainThread)
        let updated = self.resolve()
        self.lock.lock()
        self.map = updated
        self.lock.unlock()
    }

    func snapshot() -> [Character: RemoteDesktopKeyStroke] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.map
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
