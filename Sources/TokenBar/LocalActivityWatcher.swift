import CoreServices
import Foundation

final class LocalActivityWatcher {
    // A watched transcript or image root, reported as the configuration directory that owns it.
    private struct Root {
        let path: String
        let owner: String
        let suffix: String
    }

    private var roots: [Root] = []
    private let onChange: @MainActor (Set<String>) -> Void
    private var stream: FSEventStreamRef?

    var watchedAccounts: Set<String> { Set(roots.map(\.owner)) }

    init(onChange: @escaping @MainActor (Set<String>) -> Void) {
        self.onChange = onChange
    }

    /// Watches the primary directories plus each additional account, restarting any earlier stream.
    func start(accounts: [AccountSource]) {
        stop()
        let codexHome = AccountSource.primaryDirectory(for: .codex)
        let sources = [ProviderScope.claude, .codex].map {
            AccountSource(provider: $0, directory: AccountSource.primaryDirectory(for: $0).path)
        } + accounts
        roots = sources.flatMap { source in
            let names = source.provider == .claude ? ["projects"] : ["sessions", "archived_sessions"]
            return names.map { name in
                // Events carry real paths, so a linked, shared folder reports to every account using it.
                Root(path: source.url.appendingPathComponent(name).resolvingSymlinksInPath().path,
                     owner: source.directory, suffix: ".jsonl")
            }
        } + [Root(path: codexHome.appendingPathComponent("generated_images").path,
                  owner: codexHome.path, suffix: ".png")]
        roots.removeAll { AccountSource.isExcluded(URL(fileURLWithPath: $0.path)) }
        let paths = Array(Set(roots.compactMap { nearestExistingDirectory(
            for: $0.path, stoppingAt: $0.owner
        ) }))
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<LocalActivityWatcher>.fromOpaque(info).takeUnretainedValue()
                let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var owners: Set<String> = []
                for index in 0..<count {
                    owners.formUnion(watcher.owners(
                        for: String(cString: names[index]), flags: flags[index]
                    ))
                }
                if !owners.isEmpty {
                    Task { @MainActor in watcher.onChange(owners) }
                }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func nearestExistingDirectory(for path: String, stoppingAt base: String) -> String? {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard url.path != base else { return nil }
            url.deleteLastPathComponent()
        }
        return url.path
    }

    private func owners(for path: String, flags: FSEventStreamEventFlags) -> Set<String> {
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let needsRescan = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        ) != 0
        let relevant = { (root: Root) in
            isDirectory || needsRescan || path.lowercased().hasSuffix(root.suffix)
        }
        return Set(roots.filter { matches(path, root: $0.path) && relevant($0) }.map(\.owner))
    }

    private func matches(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
    }
}
