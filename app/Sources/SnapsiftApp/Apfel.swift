import Foundation

/// Optional natural-language layer over the Similar-sets categories, powered by
/// `apfel` (Apple Intelligence from the command line) if it's installed AND
/// working. It maps a free-text query ("kittens", "receipts", "whiteboards") to
/// the Vision category labels that match — so search understands meaning, not
/// just substrings. If apfel is missing or Apple Intelligence is off, every
/// caller falls back to plain substring matching; nothing breaks.
enum Apfel {
    /// Located apfel binary, if any. Subprocesses don't exist on iOS —
    /// `url == nil` there routes every caller onto the substring fallback,
    /// exactly like a Mac without apfel installed.
    static let url: URL? = {
        #if os(macOS)
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/apfel", "/usr/local/bin/apfel",
                     (fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/apfel")).path]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        return nil
    }()

    static var isInstalled: Bool { url != nil }

    /// Labels (a subset of `labels`) whose meaning matches `query`, or nil if
    /// apfel can't run (caller should fall back to substring matching).
    static func match(query: String, labels: [String]) async -> [String]? {
        guard isInstalled else { return nil }
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

    /// A short, friendly album name for a set of photos described by Vision tags
    /// (e.g. ["cat","basket","indoor"] → "Cat in a basket"). nil if apfel can't
    /// run — caller falls back to the top tag.
    static func albumName(tags: [String], language: Language) async -> String? {
        guard url != nil, !tags.isEmpty else { return nil }
        let system: String
        switch language {
        case .en:
            system = """
                You name a photo album in 2–4 words from content tags. Reply with ONLY \
                the name — no quotes, no punctuation, Title Case. Be natural, not a tag list.
                """
        case .ja:
            system = """
                内容タグから写真アルバムの名前を付けます。名前だけを返してください \
                — 引用符や句読点なし、日本語で、自然に（2〜6語程度）。タグの羅列にしないこと。
                """
        case .zhTW:
            system = """
                根據內容標籤為相簿取一個簡短名稱。只回覆名稱本身 —— 不要引號或標點， \
                用繁體中文，自然一點，別像在列標籤。
                """
        }
        let prompt = "TAGS: \(tags.joined(separator: ", "))"
        guard let out = await run(["-q", "--temperature", "0.3", "-s", system, prompt]) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        let firstLine = name.split(whereSeparator: \.isNewline).first.map(String.init) ?? name
        return firstLine.isEmpty || firstLine.count > 40 ? nil : firstLine
    }

    private static func run(_ args: [String]) async -> String? {
        #if !os(macOS)
        return nil   // Process is unavailable on iOS; callers fall back
        #else
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
        #endif
    }
}
