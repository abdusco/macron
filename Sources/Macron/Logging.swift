import Darwin
import Foundation
import OSLog

struct MacronLogger: Sendable {
    let category: String
    let home: URL

    init(category: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.category = category
        self.home = home
    }

    func log(_ message: String) { emit(message, type: .default, label: "output") }
    func notice(_ message: String) { emit(message, type: .default, label: "notice") }
    func error(_ message: String) { emit(message, type: .error, label: "error") }

    private func emit(_ message: String, type: OSLogType, label: String) {
        Logger(subsystem: appIdentifier, category: category).log(level: type, "\(message, privacy: .public)")
        do {
            let directory = home.appendingPathComponent("Library/Logs")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("macron.log")
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw MacronError("Cannot open \(url.path) (errno \(errno))") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            // Separate descriptors coordinate both streams and concurrent job processes.
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw MacronError("Cannot lock \(url.path) (errno \(errno))") }
            }
            defer { flock(descriptor, LOCK_UN) }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) [\(category)] \(label): \(message)\n"
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            FileHandle.standardError.write(Data("macron: file logging failed: \(error)\n".utf8))
        }
    }
}
