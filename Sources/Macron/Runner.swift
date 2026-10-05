import Foundation
import OSLog

struct RunResult: Codable {
    let runID: String
    let startedAt: Date
    var finishedAt: Date?
    var exitCode: Int32?
    var error: String?
}

// Each stream is read on its own thread so neither pipe can block the child.
final class OutputReader: @unchecked Sendable {
    let handle: FileHandle
    let logger: MacronLogger
    let prefix: String
    init(handle: FileHandle, logger: MacronLogger, prefix: String) {
        self.handle = handle
        self.logger = logger
        self.prefix = prefix
    }
    func drain() {
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                emit(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
            // Bound memory for commands that emit very long lines.
            while pending.count >= 2048 {
                emit(Data(pending.prefix(2048)))
                pending.removeFirst(2048)
            }
        }
        if !pending.isEmpty { emit(pending) }
        try? handle.close()
    }
    private func emit(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        logger.log("\(prefix) \(text)")
    }
}

func execute(name: String, paths: Paths) throws -> Int32 {
    guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil else {
        throw MacronError("Invalid job name")
    }
    try paths.prepare()
    let logger = MacronLogger(category: name, home: paths.home)
    let lock: FileLock
    do { lock = try FileLock(paths.locks.appendingPathComponent("\(name).lock")) }
    catch is LockBusy {
        logger.notice("Skipped: already running or being updated")
        return 0
    }
    defer { withExtendedLifetime(lock) {} }
    let data: Data
    do { data = try Data(contentsOf: paths.job(name)) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        throw MacronError("Unknown job: '\(name)'. Check 'macron list'; run 'macron reload' if you recently added or enabled it.")
    }
    let job = try JSONDecoder().decode(Job.self, from: data)
    let runID = UUID().uuidString
    var result = RunResult(runID: runID, startedAt: Date())
    try writeJSON(result, to: paths.result(name))
    logger.notice("run=\(runID) started")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", job.command]
    process.currentDirectoryURL = URL(fileURLWithPath: job.directory ?? paths.home.path)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment.merge(job.environment ?? [:]) { _, new in new }
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() }
    catch {
        result.finishedAt = Date()
        result.error = String(describing: error)
        try writeJSON(result, to: paths.result(name))
        logger.error("run=\(runID) failed to start: \(error)")
        throw error
    }
    try stdout.fileHandleForWriting.close()
    try stderr.fileHandleForWriting.close()
    let group = DispatchGroup()
    for (pipe, stream) in [(stdout, "stdout"), (stderr, "stderr")] {
        let reader = OutputReader(handle: pipe.fileHandleForReading, logger: logger, prefix: "run=\(runID) \(stream)")
        group.enter()
        DispatchQueue.global().async { reader.drain(); group.leave() }
    }
    process.waitUntilExit()
    group.wait()
    result.finishedAt = Date()
    result.exitCode = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    try writeJSON(result, to: paths.result(name))
    let duration = result.finishedAt!.timeIntervalSince(result.startedAt)
    if result.exitCode == 0 {
        logger.notice("run=\(runID) finished exit=0 duration=\(duration)s")
    } else {
        logger.error("run=\(runID) finished exit=\(result.exitCode!) duration=\(duration)s")
    }
    return result.exitCode!
}
