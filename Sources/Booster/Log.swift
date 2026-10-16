import Foundation

/// Appends to ~/Library/Logs/Booster.log (readable in Console.app). Main thread only.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Booster.log")

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        // Start fresh once the log passes 1 MB.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(time.string(from: Date())) \(message)\n"
        handle?.write(Data(line.utf8))
    }
}
