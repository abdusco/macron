import Darwin
import Foundation

@main
struct Macron {
    static func main() {
        do { try run() }
        catch {
            serviceLog.error(String(describing: error))
            FileHandle.standardError.write(Data("macron: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let paths = Paths(home: FileManager.default.homeDirectoryForCurrentUser)
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first ?? "help" {
        case "version", "--version": print("macron \(currentVersion)")
        case "install": try install(paths: paths)
        case "uninstall": try uninstall(paths: paths)
        case "reload": try reload(paths: paths)
        case "edit":
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "/usr/bin/vi"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "exec \(editor) \"$1\"", "macron", paths.config.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw MacronError("Editor exited with \(process.terminationStatus)") }
            _ = try Configuration.read(paths.config)
            print("Configuration valid. Run macron reload to update schedules.")
        case "validate":
            let url = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : paths.config
            _ = try Configuration.read(url)
            print("Configuration valid.")
        case "list":
            for job in try Configuration.read(paths.config).jobs {
                print("\(job.name)\t\(job.isEnabled ? "enabled" : "disabled")\t\(job.schedule)")
            }
        case "run", "execute":
            guard arguments.count == 2 else { throw MacronError("Usage: macron \(arguments[0]) <job>") }
            exit(try execute(name: arguments[1], paths: paths))
        case "status":
            guard arguments.count == 2 else { throw MacronError("Usage: macron status <job>") }
            let name = arguments[1]
            guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil else {
                throw MacronError("Invalid job name")
            }
            if FileManager.default.fileExists(atPath: paths.result(name).path) {
                let result = try JSONDecoder().decode(RunResult.self, from: Data(contentsOf: paths.result(name)))
                let date = ISO8601DateFormatter().string(from: result.startedAt)
                print("Latest run: \(result.runID) at \(date)")
                if let code = result.exitCode { print("Exit: \(code)") }
                else if let error = result.error { print("Failed to start: \(error)") }
                else { print("No completion recorded (running or interrupted).") }
            } else { print("No recorded runs.") }
            print(try launchctl(["print", "\(paths.domain)/\(paths.label(name))"], allowFailure: true))
        case "help", "--help", "-h":
            print("""
            macron — calendar jobs managed by launchd
            install              Install the executable and configured launchd jobs
            uninstall            Remove agents and binary; keep config and run results
            edit                 Edit jobs.json using $EDITOR
            validate [path]      Validate config without installing jobs
            reload               Validate config and update launchd jobs
            list                 List configured jobs
            run <job>            Run an applied job now; return its exit code
            status <job>         Show the latest run and launchd status
            version              Show the build version
            Logs: Console → search subsystem:\(appIdentifier)
                  Console → Log Reports → macron.log
            """)
        default: throw MacronError("Unknown command. Run macron help.")
        }
    }
}
