import Foundation

/// ~/Library/Logs/calmdoo.log (readable in Console.app). Main thread only.
///
/// Release builds write problems only. Events (which app was tapped, when, on which device) add up to
/// a listening history, so they are written only in test builds (`./build.sh --test-hooks`).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/calmdoo.log")

    private static let limit = 1_000_000
    private static var written = 0

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        written = Int((try? h?.seekToEnd()) ?? 0)
        return h
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func error(_ message: String) {
        write("problem: " + message)
    }

    static func event(_ message: @autoclosure () -> String) {
        #if BOOSTER_TEST_HOOKS
        write(message())
        #endif
    }

    private static func write(_ message: String) {
        guard let handle else { return }
        // One line per entry, bounded: names and errors come from other processes, and a newline
        // in one would let it write fake lines.
        let clean = String(message.map { $0.isNewline ? " " : $0 }.prefix(400))
        let data = Data("\(time.string(from: Date())) \(clean)\n".utf8)
        if written + data.count > limit {
            try? handle.truncate(atOffset: 0)
            written = 0
        }
        handle.write(data)
        written += data.count
    }
}
