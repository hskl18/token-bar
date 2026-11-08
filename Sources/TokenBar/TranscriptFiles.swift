import Foundation

struct TranscriptFile {
    var url: URL
    var size: UInt64

    static func list(in roots: [URL], since: Date? = nil) -> [TranscriptFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [TranscriptFile] = []
        for root in roots {
            guard AccountSource.isAllowedDirectory(root),
                  let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
                  ) else { continue }
            for case let url as URL in enumerator {
                // The root is resolved and checked; the listing neither enters linked folders nor counts linked
                // files as regular, so each entry needs only its own name checked.
                guard url.lastPathComponent.lowercased() != "trash" else {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let size = values.fileSize, size > 0,
                      since.map({ (values.contentModificationDate ?? .distantPast) >= $0 }) ?? true
                else { continue }
                files.append(TranscriptFile(url: url, size: UInt64(size)))
            }
        }
        return files.sorted { $0.url.path < $1.url.path }
    }
}
