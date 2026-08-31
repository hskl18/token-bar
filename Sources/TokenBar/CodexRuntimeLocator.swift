import AppKit
import Foundation

enum CodexRuntimeSource: String, Hashable {
    case override
    case remembered
    case path
    case commonLocation
    case desktopApp
}

struct CodexRuntimeCandidate: Hashable {
    var executableURL: URL
    var source: CodexRuntimeSource
}

struct CodexRuntimeLocator {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let desktopApplicationURL: URL?
    private let rememberedExecutable: String?
    private let isExecutable: (String) -> Bool

    init(
        environment: [String: String],
        homeDirectory: URL,
        desktopApplicationURL: URL?,
        rememberedExecutable: String?,
        isExecutable: @escaping (String) -> Bool
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.desktopApplicationURL = desktopApplicationURL
        self.rememberedExecutable = rememberedExecutable
        self.isExecutable = isExecutable
    }

    static func live() -> CodexRuntimeLocator {
        CodexRuntimeLocator(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            desktopApplicationURL: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ),
            rememberedExecutable: UserDefaults.standard.string(
                forKey: StorageKeys.codexRuntimeExecutable
            ),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    func candidates() -> [CodexRuntimeCandidate] {
        var candidates: [CodexRuntimeCandidate] = []

        if let override = nonempty(environment["CODEX_BIN"]) {
            candidates.append(candidate(path: override, source: .override))
        }
        if let rememberedExecutable = nonempty(rememberedExecutable) {
            candidates.append(candidate(path: rememberedExecutable, source: .remembered))
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                candidate(path: String($0) + "/codex", source: .path)
            })
        }

        candidates.append(contentsOf: [
            candidate(
                path: homeDirectory.appendingPathComponent(".local/bin/codex").path,
                source: .commonLocation
            ),
            candidate(path: "/opt/homebrew/bin/codex", source: .commonLocation),
            candidate(path: "/usr/local/bin/codex", source: .commonLocation),
        ])

        if let desktopApplicationURL {
            let resources = Bundle(url: desktopApplicationURL)?.resourceURL
                ?? desktopApplicationURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            candidates.append(CodexRuntimeCandidate(
                executableURL: resources.appendingPathComponent("codex"),
                source: .desktopApp
            ))
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            let path = candidate.executableURL.path
            let identity = candidate.executableURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return isExecutable(path) && seen.insert(identity).inserted
        }
    }

    private func candidate(path: String, source: CodexRuntimeSource) -> CodexRuntimeCandidate {
        let expanded = NSString(string: path).expandingTildeInPath
        return CodexRuntimeCandidate(
            executableURL: URL(fileURLWithPath: expanded).standardizedFileURL,
            source: source
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
