import CoreServices
import Foundation

final class LocalActivityWatcher {
    // A watched transcript or image root, reported as the quota row folder that owns it.
    private struct Root {
        let path: String
        let folder: String
        let owner: String
        let provider: ProviderScope
        let suffix: String
    }

    private var roots: [Root] = []
    private let onChange: @MainActor (Set<String>) -> Void
    /// The owner that wrote a file in a folder several owners share, when the file tells.
    private let claimant: @MainActor (String, ProviderScope) -> String?
    private var stream: FSEventStreamRef?

    var watchedAccounts: Set<String> { Set(roots.map(\.owner)) }

    init(
        onChange: @escaping @MainActor (Set<String>) -> Void,
        claimant: @escaping @MainActor (String, ProviderScope) -> String?
    ) {
        self.onChange = onChange
        self.claimant = claimant
    }

    /// Watches each account folder for the quota row folder it maps to, restarting any earlier stream.
    func start(sources: [AccountSource: String]) {
        stop()
        roots = sources.flatMap { source, owner in
            let names = source.provider == .claude
                ? [("projects", ".jsonl")]
                : [("sessions", ".jsonl"), ("archived_sessions", ".jsonl"), ("generated_images", ".png")]
            return names.map { name, suffix in
                // Events carry real paths, so a linked, shared folder reports to every account using it.
                Root(path: source.url.appendingPathComponent(name).resolvingSymlinksInPath().path,
                     folder: source.directory, owner: owner, provider: source.provider, suffix: suffix)
            }
        }
        // A missing images folder would mean watching its whole Codex folder, which logs and databases write
        // constantly; new images also write the session file, whose scan finds them.
        roots.removeAll {
            AccountSource.isExcluded(URL(fileURLWithPath: $0.path))
                || ($0.suffix == ".png" && !FileManager.default.fileExists(atPath: $0.path))
        }
        let paths = Array(Set(roots.compactMap { nearestExistingDirectory(
            for: $0.path, stoppingAt: $0.folder
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
                var events: [String: (owners: Set<String>, provider: ProviderScope)] = [:]
                for index in 0..<count {
                    let path = String(cString: names[index])
                    let matched = watcher.roots(for: path, flags: flags[index])
                    guard let provider = matched.first?.provider else { continue }
                    events[path, default: ([], provider)].owners.formUnion(matched.map(\.owner))
                }
                if !events.isEmpty {
                    Task { @MainActor in watcher.onChange(watcher.claimedOwners(events)) }
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

    private func roots(for path: String, flags: FSEventStreamEventFlags) -> [Root] {
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let needsRescan = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        ) != 0
        let relevant = { (root: Root) in
            isDirectory || needsRescan || path.lowercased().hasSuffix(root.suffix)
        }
        return roots.filter { matches(path, root: $0.path) && relevant($0) }
    }

    // Activity in a shared folder refreshes only the owner that wrote it, when the file tells.
    @MainActor private func claimedOwners(
        _ events: [String: (owners: Set<String>, provider: ProviderScope)]
    ) -> Set<String> {
        events.reduce(into: []) { result, event in
            let (owners, provider) = event.value
            if owners.count > 1, let owner = claimant(event.key, provider), owners.contains(owner) {
                result.insert(owner)
            } else {
                result.formUnion(owners)
            }
        }
    }

    private func matches(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
    }
}
