import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw MacronError("Test failed: \(message)") }
}

@main
struct Tests {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macron-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.prepare()

        var missingJobError: Error?
        do { _ = try execute(name: "announce_time", paths: paths) }
        catch { missingJobError = error }
        try check(missingJobError is MacronError, "Missing job produces a friendly error")
        try check(String(describing: missingJobError!) == "Unknown job: 'announce_time'. Check 'macron list'; run 'macron reload' if you recently added or enabled it.",
                  "Missing job message names the job and explains how to resolve it")
        try check(!FileManager.default.fileExists(atPath: paths.result("announce_time").path), "Missing job does not record a run")

        try Data("{".utf8).write(to: paths.job("corrupt"))
        var corruptJobError: Error?
        do { _ = try execute(name: "corrupt", paths: paths) }
        catch { corruptJobError = error }
        try check(corruptJobError is DecodingError, "Corrupt job is not misreported as unknown")

        let cases: [(String, [[String: Int]])] = [
            ("* * * * *", [[:]]),
            ("0 9 * * *", [["Minute": 0, "Hour": 9]]),
            ("*/30 9 * * 1-2", [
                ["Minute": 0, "Hour": 9, "Weekday": 1], ["Minute": 0, "Hour": 9, "Weekday": 2],
                ["Minute": 30, "Hour": 9, "Weekday": 1], ["Minute": 30, "Hour": 9, "Weekday": 2],
            ]),
            ("5,10 8 * 1 0,7", [["Minute": 5, "Hour": 8, "Month": 1, "Weekday": 0],
                                    ["Minute": 10, "Hour": 8, "Month": 1, "Weekday": 0]]),
            ("0 0 1 * 1", [["Minute": 0, "Hour": 0, "Day": 1, "Weekday": 1]]),
            ("55/3 * * * *", [["Minute": 55], ["Minute": 58]]),
        ]
        for (expression, expected) in cases {
            let actual = try Cron(expression).intervals
            try check(actual == expected, "cron \(expression): \(actual)")
        }
        let fullDays = try Cron("0 0 1-31 * 1").intervals
        try check(fullDays.count == 31 && fullDays.allSatisfy { $0["Day"] != nil && $0["Weekday"] == 1 },
                  "Explicit day range preserves OR behavior")
        for expression in ["* * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8",
                           "*/0 * * * *", "3-1 * * * *", "1, * * * *", "@daily", "0 0 * * MON",
                           "0/ * * * *", "0-58 0-22 1-30 1-11 0-6"] {
            let accepted = (try? Cron(expression)) != nil
            try check(!accepted, "Rejected cron: \(expression)")
        }
        let duplicate = Configuration(jobs: [Job(name: "same", schedule: "* * * * *", command: "date"),
                                              Job(name: "same", schedule: "* * * * *", command: "date")])
        try check((try? duplicate.validate()) == nil, "Duplicate jobs rejected")
        let caseDuplicate = Configuration(jobs: [Job(name: "same", schedule: "* * * * *", command: "date"),
                                                  Job(name: "SAME", schedule: "* * * * *", command: "date")])
        try check((try? caseDuplicate.validate()) == nil, "Names cannot collide on case-insensitive filesystems")
        let unsafe = Configuration(jobs: [Job(name: "../bad", schedule: "* * * * *", command: "date")])
        try check((try? unsafe.validate()) == nil, "Unsafe names rejected")

        let first = Configuration(jobs: [Job(name: "one", schedule: "0 9 * * *", command: "date")])
        try writeJSON(first, to: paths.config)
        let saved = try Configuration.read(paths.config)
        try check(saved.jobs == first.jobs, "Read valid config")
        try Data("{".utf8).write(to: paths.config, options: .atomic)
        try check((try? Configuration.read(paths.config)) == nil, "Malformed config rejected")
        try writeJSON(unsafe, to: paths.config)
        try check((try? Configuration.read(paths.config)) == nil, "Semantically invalid config rejected")

        for (name, command, expectedCode) in [
            ("success", "printf '%s' \"$TEST_VALUE\" > result.txt; printf 'hello\\n'; printf 'warning\\n' >&2", Int32(0)),
            ("failure", "printf 'failed\\n' >&2; exit 7", Int32(7)),
            ("signal", "kill -TERM $$", Int32(143)),
            ("volume", "i=0; while ((i < 2000)); do printf 'out %s\\n' \"$i\"; printf 'err %s\\n' \"$i\" >&2; ((i++)); done; exit 0", Int32(0)),
            ("longline", "printf '%10000s' 'end'; exit 0", Int32(0)),
        ] {
            let job = Job(name: name, schedule: "* * * * *", command: command,
                          directory: home.path, environment: ["TEST_VALUE": "working"])
            try writeJSON(job, to: paths.job(name))
            let code = try execute(name: name, paths: paths)
            try check(code == expectedCode, "Runner exit: \(name)")
            let result = try JSONDecoder().decode(RunResult.self, from: Data(contentsOf: paths.result(name)))
            try check(result.exitCode == expectedCode && result.finishedAt != nil, "Persisted result: \(name)")
        }
        let environmentOutput = try String(contentsOf: home.appendingPathComponent("result.txt"), encoding: .utf8)
        try check(environmentOutput == "working", "Environment and directory")
        let lock = try FileLock(paths.locks.appendingPathComponent("success.lock"))
        let before = try Data(contentsOf: paths.result("success"))
        let skippedCode = try execute(name: "success", paths: paths)
        try check(skippedCode == 0, "Overlap skipped")
        let after = try Data(contentsOf: paths.result("success"))
        try check(after == before, "Overlap preserves result")
        withExtendedLifetime(lock) {}
        let missingDirectory = Job(name: "missing", schedule: "* * * * *", command: "true", directory: home.appendingPathComponent("missing").path)
        try writeJSON(missingDirectory, to: paths.job("missing"))
        do { _ = try execute(name: "missing", paths: paths) } catch {}
        let failure = try JSONDecoder().decode(RunResult.self, from: Data(contentsOf: paths.result("missing")))
        try check(failure.error != nil && failure.finishedAt != nil, "Start failure recorded")

        let log = try String(contentsOf: home.appendingPathComponent("Library/Logs/macron.log"), encoding: .utf8)
        for expected in ["[success] notice: run=", "stdout hello", "stderr warning", "finished exit=0",
                         "[failure] error: run=", "finished exit=7", "failed to start:", "Skipped:"] {
            try check(log.contains(expected), "Log contains \(expected)")
        }
        let lines = log.split(separator: "\n")
        try check(lines.filter { $0.contains("stdout out ") }.count == 2000, "All stdout lines logged")
        try check(lines.filter { $0.contains("stderr err ") }.count == 2000, "All stderr lines logged")
        try check(lines.allSatisfy { $0.contains("] ") }, "Concurrent writes preserve complete lines")

        let plist = try agent(for: first.jobs[0], paths: paths)
        try check(plist["Label"] as? String == "dev.abdus.apps.macron.job.one", "Agent identifier")
        try check(plist["StartCalendarInterval"] as? [[String: Int]] == [["Minute": 0, "Hour": 9]], "Calendar agent")
        try check(plist["StartInterval"] == nil && plist["RunAtLoad"] == nil, "No interval timer or unsolicited run")
        print("All tests passed.")
    }
}
