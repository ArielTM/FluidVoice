import AppKit
import Carbon.HIToolbox

/// One key press: a virtual key code, optionally with shift held.
struct RemoteDesktopKeyStroke: Equatable {
    let keyCode: CGKeyCode
    let needsShift: Bool
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
    /// Substitutions applied before mapping, for characters that have an unambiguous ASCII
    /// spelling. Transcripts pick these up from AI enhancement rather than from speech, and
    /// normalising them is standard practice when the destination only accepts plain input.
    static let transliterations: [Character: String] = [
        "\u{2018}": "'", // left single quote
        "\u{2019}": "'", // right single quote / curly apostrophe
        "\u{201A}": "'",
        "\u{201B}": "'",
        "\u{201C}": "\"", // left double quote
        "\u{201D}": "\"", // right double quote
        "\u{201E}": "\"",
        "\u{2032}": "'", // prime
        "\u{2033}": "\"", // double prime
        "\u{2013}": "-", // en dash
        "\u{2014}": "--", // em dash
        "\u{2015}": "--",
        "\u{2212}": "-", // minus sign
        "\u{2026}": "...", // ellipsis
        "\u{00A0}": " ", // non-breaking space
        "\u{202F}": " ", // narrow no-break space
        "\u{2009}": " ", // thin space
        "\u{2022}": "-", // bullet
        "\u{00B7}": "-", // middle dot
        "\u{2043}": "-",
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
        precondition(Thread.isMainThread)
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
                    var dead: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout,
                        key,
                        UInt16(kUCKeyActionDisplay),
                        modifiers,
                        keyboardType,
                        UInt32(kUCKeyTranslateNoDeadKeysMask),
                        &dead,
                        characters.count,
                        &length,
                        &characters
                    )
                    guard status == noErr, length == 1 else { continue }
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

    /// The characters in `text` that no key press on this layout can produce.
    static func unmappableCharacters(
        in text: String,
        map: [Character: RemoteDesktopKeyStroke]
    ) -> [Character] {
        var seen: Set<Character> = []
        var result: [Character] = []
        for character in text where map[character] == nil {
            // Newlines and tabs are typed as their own key codes, not through the layout map.
            if character == "\n" || character == "\r" || character == "\t" { continue }
            if seen.insert(character).inserted { result.append(character) }
        }
        return result
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
