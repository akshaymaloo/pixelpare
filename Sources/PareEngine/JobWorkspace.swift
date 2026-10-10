import CryptoKit
import Foundation
import PareCore

/// Per-job scratch space under Application Support (not tmp: it must survive relaunch).
/// `Jobs/<hash of id>/source.<ext>`, `encoded.mov`, and `*.partial` files that only ever become final by rename.
public struct JobWorkspace: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> JobWorkspace {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JobWorkspace(root: base.appendingPathComponent("PixelPare/Jobs", isDirectory: true))
    }

    public static let encodedName = "encoded.mov"
    public static let partialSuffix = ".partial"

    public func directory(for id: MediaID) -> URL {
        let digest = SHA256.hash(data: Data(id.raw.utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Creates the job directory (and the root, excluded from backups).
    @discardableResult
    public func prepare(for id: MediaID) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            var r = root
            try? r.setResourceValues(v)
        }
        let dir = directory(for: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func stagingDirectory(for id: MediaID) -> URL {
        directory(for: id).appendingPathComponent("download\(Self.partialSuffix)", isDirectory: true)
    }

    public func encodedURL(for id: MediaID) -> URL { directory(for: id).appendingPathComponent(Self.encodedName) }

    public func encodedPartialURL(for id: MediaID) -> URL {
        directory(for: id).appendingPathComponent(Self.encodedName + Self.partialSuffix)
    }

    /// The completed (renamed) source file, if any.
    public func sourceURL(for id: MediaID) -> URL? {
        let dir = directory(for: id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().first { $0.hasPrefix("source.") && !$0.hasSuffix(Self.partialSuffix) }
            .map { dir.appendingPathComponent($0) }
    }

    public func finalSourceURL(for id: MediaID, ext: String) -> URL {
        directory(for: id).appendingPathComponent("source." + (ext.isEmpty ? "mov" : ext))
    }

    public func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
    }

    public func removePartials(for id: MediaID) {
        let dir = directory(for: id)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasSuffix(Self.partialSuffix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    public func cleanup(for id: MediaID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Deletes every job directory that doesn't belong to one of `keeping`, and stray files at the root.
    /// Returns what was removed.
    @discardableResult
    public func collectGarbage(keeping: Set<MediaID>) -> [URL] {
        let fm = FileManager.default
        let keep = Set(keeping.map { directory(for: $0).lastPathComponent })
        var removed: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != Self.lockName {
            if keep.contains(name) { continue }
            let url = root.appendingPathComponent(name)
            try? fm.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }

    public var isEmptyOfJobs: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != Self.lockName }.isEmpty
    }

    // MARK: Inter-process lock

    static let lockName = ".lock"

    /// Takes the exclusive `Jobs/.lock`; throws `PipelineError.workspaceLocked` if another holder has it.
    public func acquireLock() throws -> WorkspaceLock {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(Self.lockName).path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw PipelineError.workspaceUnavailable(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw PipelineError.workspaceLocked
        }
        return WorkspaceLock(fd: fd)
    }
}

/// Holds the `flock`; released on `release()` or deinit (and by the OS if the process dies).
public final class WorkspaceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
