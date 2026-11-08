import Foundation

struct ImageGenerationRecord: Codable, Hashable {
    var savedAt: Date
    var width: Int
    var height: Int
    /// The Codex folder holding the earliest copy; nil on records saved when only `~/.codex` was scanned.
    var folder: String? = nil

    var estimatedOutputTokens: Int64 {
        let w = max(16, (Double(width) / 16).rounded(.toNearestOrEven) * 16)
        let h = max(16, (Double(height) / 16).rounded(.toNearestOrEven) * 16)
        let mediumGrid = 48.0
        let grid = mediumGrid * max(1, (mediumGrid * min(w, h) / max(w, h)).rounded(.toNearestOrEven))
        return Int64(ceil(grid * (2_000_000 + w * h) / 4_000_000))
    }

    var estimatedCostUSD: Double {
        Double(estimatedOutputTokens) * 30 / 1_000_000
    }
}

struct ImageGenerationUsage: Codable, Hashable {
    var records: [String: ImageGenerationRecord] = [:]
    var scanError: String? = nil

    /// `folders` limits the sum to images those Codex folders saved, such as one login's for its weekly estimate.
    func cost(in interval: DateInterval, folders: Set<String>? = nil) -> Double {
        summary(in: interval, folders: folders).cost
    }

    func summary(in interval: DateInterval, folders: Set<String>? = nil) -> (cost: Double, count: Int) {
        let primary = AccountSource.primaryDirectory(for: .codex).path
        return records.values.reduce(into: (cost: 0.0, count: 0)) { total, record in
            guard record.savedAt >= interval.start, record.savedAt < interval.end,
                  folders?.contains(record.folder ?? primary) ?? true else { return }
            total.cost += record.estimatedCostUSD
            total.count += 1
        }
    }
}

struct ImageGenerationSampler {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Scans `generated_images` in every Codex folder, since each login saves its own sessions' images.
    func update(codexHomes: [URL]) async -> ImageGenerationUsage {
        await Task.detached(priority: .utility) { scan(codexHomes: codexHomes) }.value
    }

    private func scan(codexHomes: [URL]) -> ImageGenerationUsage {
        var usage = defaults.data(forKey: StorageKeys.imageGenerationUsage)
            .flatMap { try? JSONDecoder().decode(ImageGenerationUsage.self, from: $0) }
            ?? ImageGenerationUsage()
        let previous = usage
        usage.scanError = nil
        // A linked folder is read once; records are keyed by generation ID, so a copied image counts once.
        var seen = Set<String>()
        for home in codexHomes.sorted(by: { $0.path < $1.path }) {
            let root = home.appendingPathComponent("generated_images", isDirectory: true).resolvingSymlinksInPath()
            guard seen.insert(root.path).inserted else { continue }
            guard !AccountSource.isExcluded(root) else {
                usage.scanError = "The configured image directory is excluded."
                continue
            }
            if FileManager.default.fileExists(atPath: root.path) { scan(root, folder: home.path, into: &usage) }
        }
        if usage != previous, let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: StorageKeys.imageGenerationUsage)
        }
        return usage
    }

    private func scan(_ root: URL, folder: String, into usage: inout ImageGenerationUsage) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
        var enumerationError: String?
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error.localizedDescription
                return true
            }
        ) else {
            usage.scanError = "The generated image directory could not be read."
            return
        }
        defer { if let enumerationError { usage.scanError = enumerationError } }

        for case let url as URL in files {
            if Task.isCancelled { break }
            if url.pathComponents.contains(where: { $0.lowercased() == "trash" }) {
                files.skipDescendants()
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension.lowercased() == "png", let id = generationID(name) else { continue }
            do {
                let metadata = try url.resourceValues(forKeys: Set(keys))
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                      let savedAt = metadata.creationDate ?? metadata.contentModificationDate
                else { continue }
                // A copy in another folder keeps the earliest save, which is when the image was made,
                // and an older record learns the folder it came from.
                if let record = usage.records[id] {
                    if savedAt < record.savedAt || (savedAt == record.savedAt && record.folder == nil) {
                        usage.records[id]?.savedAt = savedAt
                        usage.records[id]?.folder = folder
                    }
                    continue
                }
                guard let dimensions = try dimensions(of: url) else { continue }
                usage.records[id] = ImageGenerationRecord(
                    savedAt: savedAt, width: dimensions.width, height: dimensions.height, folder: folder
                )
            } catch {
                usage.scanError = error.localizedDescription
            }
        }
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
