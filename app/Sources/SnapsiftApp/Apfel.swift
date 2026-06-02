import Foundation

/// Optional natural-language layer over the Similar-sets categories, powered by
/// `apfel` (Apple Intelligence from the command line) if it's installed AND
/// working. It maps a free-text query ("kittens", "receipts", "whiteboards") to
/// the Vision category labels that match — so search understands meaning, not
/// just substrings. If apfel is missing or Apple Intelligence is off, every
/// caller falls back to plain substring matching; nothing breaks.
enum Apfel {
    /// Located apfel binary, if any.
    static let url: URL? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/apfel", "/usr/local/bin/apfel",
                     (fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/apfel")).path]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    static var isInstalled: Bool { url != nil }

    /// Labels (a subset of `labels`) whose meaning matches `query`, or nil if
    /// apfel can't run (caller should fall back to substring matching).
    static func match(query: String, labels: [String]) async -> [String]? {
        guard let url else { return nil }
        let system = """
            You map a photo-search query to category labels. Given a QUERY and a \
            list of LABELS (lowercase taxonomy ids), reply with ONLY a JSON array \
            of the labels whose meaning matches the query's intent. No prose, no \
            code fences. If none match, reply [].
            """
        let prompt = "QUERY: \(query)\nLABELS: \(labels.joined(separator: ", "))"
        guard let out = await run(["-q", "--temperature", "0", "-s", system, prompt]),
              let start = out.firstIndex(of: "["), let end = out.lastIndex(of: "]"),
              start < end,
              let data = String(out[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        let valid = Set(labels)
        let matched = decoded.filter { valid.contains($0) }
        return matched.isEmpty ? nil : matched
    }

    private static func run(_ args: [String]) async -> String? {
        guard let url else { return nil }
        return await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = url
            process.arguments = args
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run() } catch { cont.resume(returning: nil); return }
            DispatchQueue.global().async {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                // Non-zero (e.g. Apple Intelligence off) → nil → substring fallback.
                guard process.terminationStatus == 0 else { cont.resume(returning: nil); return }
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
