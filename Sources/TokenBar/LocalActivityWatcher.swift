import CoreServices
import Foundation

final class LocalActivityWatcher {
    private let claudeRoot: String
    private let codexRoot: String
    private let imageRoot: String
    private let claudeBase: String
    private let codexBase: String
    private let onChange: @MainActor (Set<ProviderScope>) -> Void
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @MainActor (Set<ProviderScope>) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:)) ?? home.appendingPathComponent(".codex")
        claudeBase = home.appendingPathComponent(".claude").standardizedFileURL.path
        codexBase = codexHome.standardizedFileURL.path
        claudeRoot = home.appendingPathComponent(".claude/projects").standardizedFileURL.path
        codexRoot = codexHome.appendingPathComponent("sessions").standardizedFileURL.path
        imageRoot = codexHome.appendingPathComponent("generated_images").standardizedFileURL.path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        let roots = [(claudeRoot, claudeBase), (codexRoot, codexBase),
                     (imageRoot, codexBase)]
            .filter { !$0.0.split(separator: "/").contains(where: { $0.lowercased() == "trash" }) }
        let paths = Array(Set(roots.compactMap { nearestExistingDirectory(
            for: $0.0, stoppingAt: $0.1
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
                var providers: Set<ProviderScope> = []
                for index in 0..<count {
                    providers.formUnion(watcher.providers(
                        for: String(cString: names[index]), flags: flags[index]
                    ))
                }
                if !providers.isEmpty {
                    Task { @MainActor in watcher.onChange(providers) }
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

    private func providers(for path: String, flags: FSEventStreamEventFlags) -> Set<ProviderScope> {
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let needsRescan = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        ) != 0
        var result: Set<ProviderScope> = []
        if matches(path, root: claudeRoot),
           isDirectory || needsRescan || path.hasSuffix(".jsonl") {
            result.insert(.claude)
        }
        if matches(path, root: codexRoot),
           isDirectory || needsRescan || path.hasSuffix(".jsonl") {
            result.insert(.codex)
        }
        if matches(path, root: imageRoot),
           isDirectory || needsRescan || path.lowercased().hasSuffix(".png") {
            result.insert(.codex)
        }
        return result
    }

    private func matches(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
    }
}
