import Foundation

/// Turns single keypresses into stroke tags while a recording runs.
///
/// The terminal is taken out of canonical mode so a key registers on press
/// rather than on Enter — a tagger watching someone cast can't be hitting Enter
/// between strokes. Two details matter:
///
/// - **ISIG stays on.** A full raw mode would swallow Ctrl-C, and Ctrl-C is how
///   a recording is stopped cleanly; without it the CSV never gets closed.
/// - **ECHO goes off**, so keys don't scatter through the live status line.
///
/// The terminal must be put back, on every exit path, or the user's shell is
/// left with no echo. `stop()` is idempotent and an `atexit` handler backs it up.
final class KeyTagger {

    /// Tagging needs a real terminal. Piped or redirected input has no keys to
    /// read and no termios to change.
    static var isAvailable: Bool {
        isatty(FileHandle.standardInput.fileDescriptor) == 1
    }

    private let fd = FileHandle.standardInput.fileDescriptor
    private let onKey: (Character) -> Void

    private var saved = termios()
    private var didEnterRawMode = false
    private var source: DispatchSourceRead?

    /// Set while any tagger holds the terminal, so the atexit backstop can find it.
    private static var active: KeyTagger?

    init(onKey: @escaping (Character) -> Void) {
        self.onKey = onKey
    }

    /// Returns false if the terminal couldn't be reconfigured; recording then
    /// continues untagged rather than failing.
    @discardableResult
    func start() -> Bool {
        guard Self.isAvailable, !didEnterRawMode else { return false }
        guard tcgetattr(fd, &saved) == 0 else { return false }

        var raw = saved
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        // Return from read() as soon as one byte is there, with no timer.
        withUnsafeMutablePointer(to: &raw.c_cc) { tuple in
            tuple.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { return false }
        didEnterRawMode = true

        Self.active = self
        atexit { KeyTagger.active?.restoreTerminal() }

        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in self?.drain() }
        s.resume()
        source = s
        return true
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return }
        for byte in buffer[0..<n] {
            // ASCII only. Arrow keys and the like arrive as escape sequences
            // whose bytes are all printable, but none of them spell a label key,
            // so they fall through the lookup harmlessly.
            guard let scalar = UnicodeScalar(UInt32(byte)), scalar.isASCII else { continue }
            onKey(Character(scalar))
        }
    }

    private func restoreTerminal() {
        guard didEnterRawMode else { return }
        didEnterRawMode = false
        tcsetattr(fd, TCSANOW, &saved)
    }

    func stop() {
        source?.cancel()
        source = nil
        restoreTerminal()
        if Self.active === self { Self.active = nil }
    }
}
