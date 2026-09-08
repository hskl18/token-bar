import Foundation

struct ImageGenerationRecord: Codable, Hashable {
    var savedAt: Date
    var width: Int
    var height: Int

    var estimatedOutputTokens: Int64 {
        let w = max(16, (Double(width) / 16).rounded() * 16)
        let h = max(16, (Double(height) / 16).rounded() * 16)
        let mediumGrid = 48.0
        let grid = mediumGrid * max(1, (mediumGrid * min(w, h) / max(w, h)).rounded())
        return Int64(ceil(grid * (2_000_000 + w * h) / 4_000_000))
    }

    var estimatedCostUSD: Double {
        Double(estimatedOutputTokens) * 30 / 1_000_000
    }
}

struct ImageGenerationUsage: Codable, Hashable {
    var records: [String: ImageGenerationRecord] = [:]
    var scanError: String? = nil

    func cost(in interval: DateInterval) -> Double {
        summary(in: interval).cost
    }

    private func summary(in interval: DateInterval) -> (cost: Double, count: Int) {
        records.values.reduce(into: (cost: 0.0, count: 0)) { total, record in
            guard record.savedAt >= interval.start, record.savedAt < interval.end else { return }
            total.cost += record.estimatedCostUSD
            total.count += 1
        }
    }

    func explanation(in interval: DateInterval) -> String {
        let summary = summary(in: interval)
        let amount = summary.cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        var text = "Includes ImageGen output estimate: \(amount) for \(summary.count) saved images. "
            + "Assumes GPT Image 2 medium quality and uses saved dimensions as a size estimate. "
            + "Prompt, reference-image input, and partial-image charges are excluded. "
            + "Image estimates are not included in the displayed text-model token count."
        if let scanError { text += " Image scan incomplete: \(scanError)" }
        return text
    }
}

struct ImageGenerationSampler {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func update() async -> ImageGenerationUsage {
        await Task.detached(priority: .utility) { scan() }.value
    }

    private func scan() -> ImageGenerationUsage {
        var usage = defaults.data(forKey: StorageKeys.imageGenerationUsage)
            .flatMap { try? JSONDecoder().decode(ImageGenerationUsage.self, from: $0) }
            ?? ImageGenerationUsage()
        let previous = usage
        usage.scanError = nil
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let root = home.appendingPathComponent("generated_images", isDirectory: true)
        guard !root.pathComponents.contains(where: { $0.lowercased() == "trash" }) else {
            usage.scanError = "The configured image directory is excluded."
            return usage
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return usage }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                usage.scanError = error.localizedDescription
                return true
            }
        ) else {
            usage.scanError = "The generated image directory could not be read."
            return usage
        }

        for case let url as URL in files {
            if Task.isCancelled { break }
            if url.pathComponents.contains(where: { $0.lowercased() == "trash" }) {
                files.skipDescendants()
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension.lowercased() == "png", let id = generationID(name),
                  usage.records[id] == nil else { continue }
            do {
                let metadata = try url.resourceValues(forKeys: Set(keys))
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                      let savedAt = metadata.creationDate ?? metadata.contentModificationDate
                else { continue }
                guard let dimensions = try dimensions(of: url) else { continue }
                usage.records[id] = ImageGenerationRecord(
                    savedAt: savedAt, width: dimensions.width, height: dimensions.height
                )
            } catch {
                usage.scanError = error.localizedDescription
            }
        }
        if usage != previous, let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: StorageKeys.imageGenerationUsage)
        }
        return usage
    }

    private func generationID(_ name: String) -> String? {
        if name.hasPrefix("exec-"), let id = UUID(uuidString: String(name.dropFirst(5))) {
            return id.uuidString
        }
        if name.hasPrefix("ig_"), name.count > 19,
           name.dropFirst(3).allSatisfy({ $0.isHexDigit }) {
            return name.lowercased()
        }
        return nil
    }

    private func dimensions(of url: URL) throws -> (width: Int, height: Int)? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 24), header.count == 24,
              Array(header.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              String(data: header[12..<16], encoding: .ascii) == "IHDR" else { return nil }
        let size = try file.seekToEnd()
        guard size >= 45 else { return nil }
        try file.seek(toOffset: size - 12)
        guard let tail = try file.read(upToCount: 12), tail.count == 12,
              tail.prefix(4).allSatisfy({ $0 == 0 }),
              String(data: tail[4..<8], encoding: .ascii) == "IEND" else { return nil }
        let width = header[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let height = header[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        guard width > 0, height > 0, width <= 65536, height <= 65536 else { return nil }
        return (width, height)
    }
}
