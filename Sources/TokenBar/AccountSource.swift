import Foundation

struct AccountSource: Hashable {
    let provider: ProviderScope
    let directory: String

    var url: URL { URL(fileURLWithPath: directory, isDirectory: true) }

    static func title(for directory: URL) -> String {
        let name = directory.lastPathComponent.drop(while: { $0 == "." })
        guard let first = name.first else { return "Account" }
        return String(first).uppercased() + name.dropFirst()
    }

    static func titles(for directories: [URL]) -> [String: String] {
        Dictionary(grouping: directories, by: title(for:)).reduce(into: [:]) { titles, group in
            for (index, directory) in group.value.enumerated() {
                titles[directory.path] = group.value.count > 1 ? "\(group.key) \(index + 1)" : group.key
            }
        }
    }

    static func primaryDirectory(for provider: ProviderScope) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(provider == .claude ? ".claude" : ".codex", isDirectory: true)
    }

    /// Signed-in profiles beside the primary folder, such as `~/.claude-work` or `~/.codex-work`.
    /// Only the home folder's top level is listed, and only known configuration names are checked.
    static func detected(in home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AccountSource] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.sorted().compactMap { name in
            let provider: ProviderScope
            if name.hasPrefix(".claude-") { provider = .claude }
            else if name.hasPrefix(".codex-") { provider = .codex }
            else { return nil }
            let directory = home.appendingPathComponent(name, isDirectory: true)
            let markers = provider == .claude ? [".claude.json", ".credentials.json"] : ["auth.json", "config.toml"]
            guard isAllowedDirectory(directory),
                  markers.contains(where: { isRegularFile(directory.appendingPathComponent($0)) })
            else { return nil }
            return AccountSource(provider: provider, directory: directory.path)
        }
    }

    static func isExcluded(_ url: URL) -> Bool {
        [url, url.resolvingSymlinksInPath()].contains { $0.pathComponents.contains { $0.lowercased() == "trash" } }
    }

    static func isAllowedDirectory(_ directory: URL) -> Bool {
        guard directory.isFileURL, !isExcluded(directory),
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func isRegularFile(_ file: URL) -> Bool {
        guard !isExcluded(file),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
