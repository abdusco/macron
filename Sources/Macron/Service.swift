import Darwin
import Foundation
import OSLog

let serviceLog = Logger(subsystem: "local.macron", category: "service")

struct Paths {
    let home: URL
    var config: URL { home.appendingPathComponent(".config/macron/jobs.json") }
    var root: URL { home.appendingPathComponent("Library/Application Support/Macron") }
    var binary: URL { root.appendingPathComponent("bin/macron") }
    var jobs: URL { root.appendingPathComponent("jobs") }
    var results: URL { root.appendingPathComponent("results") }
    var locks: URL { root.appendingPathComponent("locks") }
    var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    var domain: String { "gui/\(getuid())" }
    func label(_ name: String) -> String { "local.macron.job.\(name)" }
    func plist(_ name: String) -> URL { agents.appendingPathComponent("\(label(name)).plist") }
    func job(_ name: String) -> URL { jobs.appendingPathComponent("\(name).json") }
    func result(_ name: String) -> URL { results.appendingPathComponent("\(name).json") }

    func prepare() throws {
        for url in [config.deletingLastPathComponent(), binary.deletingLastPathComponent(), jobs, results, locks, agents] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        }
    }
}

struct LockBusy: Error, CustomStringConvertible {
    let description: String
}

final class FileLock {
    private let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MacronError("Cannot open lock: \(url.path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw LockBusy(description: "Busy: \(url.lastPathComponent)") }
            throw MacronError("Cannot lock: \(url.path) (errno \(code))")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

@discardableResult
func launchctl(_ arguments: [String], allowFailure: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    if process.terminationStatus != 0 && !allowFailure {
        throw MacronError("launchctl \(arguments.joined(separator: " ")): \(text)")
    }
    return text
}

func writePlist(_ dictionary: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        .write(to: url, options: .atomic)
}

func agent(for job: Job, paths: Paths) throws -> [String: Any] {
    ["Label": paths.label(job.name),
     "ProgramArguments": [paths.binary.path, "execute", job.name],
     "StartCalendarInterval": try Cron(job.schedule).intervals,
     "ProcessType": "Background"]
}

func reconcile(_ configuration: Configuration, paths: Paths) throws {
    try configuration.validate()
    let reconciliationLock = try FileLock(paths.locks.appendingPathComponent("configuration.lock"))
    defer { withExtendedLifetime(reconciliationLock) {} }
    let files = try FileManager.default.contentsOfDirectory(at: paths.jobs, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    var existing = [String: Job]()
    for file in files { existing[file.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode(Job.self, from: Data(contentsOf: file)) }
    let desired = Dictionary(uniqueKeysWithValues: configuration.jobs.filter(\.isEnabled).map { ($0.name, $0) })
    let changes = Set(existing.keys).union(desired.keys).filter { existing[$0] != desired[$0] }
    // Hold all affected job locks before altering any agents. Reload can be retried after active runs finish.
    let jobLocks = try changes.sorted().map { try FileLock(paths.locks.appendingPathComponent("\($0).lock")) }
    defer { withExtendedLifetime(jobLocks) {} }
    for name in changes.sorted() {
        try launchctl(["bootout", "\(paths.domain)/\(paths.label(name))"], allowFailure: true)
        if let job = desired[name] {
            try writePlist(agent(for: job, paths: paths), to: paths.plist(name))
            // A bootstrapped calendar job reads the new snapshot at its next invocation.
            try writeJSON(job, to: paths.job(name))
            do { try launchctl(["bootstrap", paths.domain, paths.plist(name).path]) }
            catch {
                // Remove the snapshot so the next reconciliation retries this agent.
                try? FileManager.default.removeItem(at: paths.job(name))
                throw error
            }
        } else {
            try FileManager.default.removeItem(at: paths.job(name))
            try? FileManager.default.removeItem(at: paths.plist(name))
        }
        serviceLog.notice("Applied job \(name, privacy: .public)")
    }
    // Restore unloaded jobs, even when their stored configuration is unchanged.
    for job in desired.values where !changes.contains(job.name) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(paths.domain)/\(paths.label(job.name))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            try writePlist(agent(for: job, paths: paths), to: paths.plist(job.name))
            try launchctl(["bootstrap", paths.domain, paths.plist(job.name).path])
        }
    }
}

// Clean up installations of the earlier polling version.
func removeLegacyWatcher(paths: Paths) throws {
    let plist = paths.agents.appendingPathComponent("local.macron.watcher.plist")
    if FileManager.default.fileExists(atPath: plist.path) {
        try launchctl(["bootout", "\(paths.domain)/local.macron.watcher"], allowFailure: true)
        try FileManager.default.removeItem(at: plist)
    }
}

func reload(paths: Paths) throws {
    let configuration = try Configuration.read(paths.config)
    guard FileManager.default.isExecutableFile(atPath: paths.binary.path) else {
        throw MacronError("Run macron install before reloading schedules")
    }
    try paths.prepare()
    try removeLegacyWatcher(paths: paths)
    try reconcile(configuration, paths: paths)
    serviceLog.notice("Configuration reloaded")
    print("Configuration reloaded.")
}

func install(paths: Paths) throws {
    try paths.prepare()
    if !FileManager.default.fileExists(atPath: paths.config.path) {
        try writeJSON(Configuration(jobs: [Job(name: "example", schedule: "0 9 * * *", command: "date", enabled: false)]), to: paths.config)
    }
    let configuration = try Configuration.read(paths.config)
    guard let executable = Bundle.main.executableURL else { throw MacronError("Cannot locate this executable") }
    let source = executable.standardizedFileURL.resolvingSymlinksInPath()
    if source != paths.binary {
        try Data(contentsOf: source).write(to: paths.binary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.binary.path)
    }
    try removeLegacyWatcher(paths: paths)
    try reconcile(configuration, paths: paths)
    print("Installed. Edit \(paths.config.path), then run macron reload.")
}

func uninstall(paths: Paths) throws {
    try paths.prepare()
    let configurationLock = try FileLock(paths.locks.appendingPathComponent("configuration.lock"))
    defer { withExtendedLifetime(configurationLock) {} }
    let agents = try FileManager.default.contentsOfDirectory(at: paths.agents, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("local.macron.job.") && $0.pathExtension == "plist" }
    let names = agents.map { String($0.deletingPathExtension().lastPathComponent.dropFirst("local.macron.job.".count)) }
    let locks = try names.sorted().map { try FileLock(paths.locks.appendingPathComponent("\($0).lock")) }
    defer { withExtendedLifetime(locks) {} }
    try removeLegacyWatcher(paths: paths)
    for name in names {
        try launchctl(["bootout", "\(paths.domain)/\(paths.label(name))"], allowFailure: true)
        try FileManager.default.removeItem(at: paths.plist(name))
        try? FileManager.default.removeItem(at: paths.job(name))
    }
    for url in [paths.binary] {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    print("Uninstalled. Configuration and latest run results retained.")
}
