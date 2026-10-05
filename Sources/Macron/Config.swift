import Foundation

struct MacronError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Configuration: Codable {
    var jobs: [Job]

    static func read(_ url: URL) throws -> Configuration {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    func validate() throws {
        var names = Set<String>()
        for job in jobs {
            guard job.name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil else {
                throw MacronError("Invalid job name: \(job.name). Use 1–64 letters, digits, underscores or hyphens.")
            }
            guard names.insert(job.name.lowercased()).inserted else { throw MacronError("Duplicate job (case-insensitive): \(job.name)") }
            guard !job.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacronError("\(job.name): command is empty")
            }
            if let directory = job.directory, !directory.hasPrefix("/") {
                throw MacronError("\(job.name): directory must be an absolute path")
            }
            for (key, value) in job.environment ?? [:] {
                guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
                    throw MacronError("\(job.name): invalid environment entry")
                }
            }
            guard !job.command.contains("\0") else { throw MacronError("\(job.name): command contains NUL") }
            _ = try Cron(job.schedule)
        }
    }
}

struct Job: Codable, Equatable {
    var name: String
    var schedule: String
    var command: String
    var directory: String? = nil
    var environment: [String: String]? = nil
    var enabled: Bool? = nil

    var isEnabled: Bool { enabled ?? true }
}

struct Cron {
    let intervals: [[String: Int]]

    init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else { throw MacronError("Cron requires five fields: \(expression)") }
        let specifications: [(String, ClosedRange<Int>)] = [
            ("Minute", 0...59), ("Hour", 0...23), ("Day", 1...31), ("Month", 1...12), ("Weekday", 0...7),
        ]
        var result: [[String: Int]] = [[:]]
        for (index, specification) in specifications.enumerated() {
            let (key, bounds) = specification
            var values = try Self.parse(fields[index], bounds: bounds)
            if key == "Weekday" { values = Set(values.map { $0 == 7 ? 0 : $0 }) }
            let allValues = key == "Weekday" ? Set(0...6) : Set(bounds)
            // An explicit full Day/Weekday range still participates in cron's OR rule.
            if fields[index] == "*" || (values == allValues && key != "Day" && key != "Weekday") { continue }
            guard result.count * values.count <= 10_000 else {
                throw MacronError("Cron expands to more than 10,000 calendar entries: \(expression)")
            }
            result = result.flatMap { interval in
                values.sorted().map { value in
                    var copy = interval
                    copy[key] = value
                    return copy
                }
            }
        }
        // launchd applies OR when both Day and Weekday are present, like cron.
        intervals = result
    }

    private static func parse(_ field: String, bounds: ClosedRange<Int>) throws -> Set<Int> {
        var values = Set<Int>()
        for item in field.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), !parts[0].isEmpty else { throw MacronError("Invalid cron field: \(field)") }
            let step: Int
            if parts.count == 2 {
                guard let number = Int(parts[1]), number > 0 else { throw MacronError("Invalid cron step: \(field)") }
                step = number
            } else { step = 1 }
            let start: Int
            let end: Int
            if parts[0] == "*" {
                start = bounds.lowerBound
                end = bounds.upperBound
            } else {
                let range = parts[0].split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(range.count), let lower = Int(range[0]), bounds.contains(lower) else {
                    throw MacronError("Invalid cron field: \(field)")
                }
                start = lower
                if range.count == 2 {
                    guard let upper = Int(range[1]), bounds.contains(upper), upper >= lower else {
                        throw MacronError("Invalid cron range: \(field)")
                    }
                    end = upper
                } else { end = parts.count == 2 ? bounds.upperBound : lower }
            }
            for value in stride(from: start, through: end, by: step) { values.insert(value) }
        }
        return values
    }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}
