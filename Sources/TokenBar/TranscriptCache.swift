import CryptoKit
import Foundation

enum TranscriptCache {
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Token Bar/Ledgers", isDirectory: true)

    private static func url(for key: String) -> URL {
        guard let base = StorageKeys.profileLedgers.first(where: { key.hasPrefix($0 + ".") }) else {
            return directory.appendingPathComponent(key).appendingPathExtension("json")
        }
        // Profile keys contain a directory path, which cannot be a file name.
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = base + "." + digest
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        (try? Data(contentsOf: url(for: key))).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let destination = url(for: key)
        if data == (try? Data(contentsOf: destination)) { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            NSLog("Token Bar could not save a transcript ledger: %@", error.localizedDescription)
        }
    }

    private struct Window: Decodable { var resetsAt: Date }

    static func removeObsolete() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let key = file.deletingPathExtension().lastPathComponent
            // A weekly window ledger is reused only for its own window, so it is dead once that window resets.
            // Usage ledgers stay: they can hold history whose source files are gone.
            let isWindow = [StorageKeys.claudeWindowLedger, StorageKeys.codexWindowLedger]
                .contains { key == $0 || key.hasPrefix($0 + ".") }
            let expired = isWindow && (try? Data(contentsOf: file))
                .flatMap { try? JSONDecoder().decode(Window.self, from: $0) }
                .map { $0.resetsAt < Date() } == true
            if StorageKeys.isObsolete(key) || expired {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
