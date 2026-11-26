import Darwin
import Dispatch
import Foundation
import TidyreelModels

// MARK: - POSIX Permission Helpers

private func applyRestrictedPermissions(_ path: String) {
    _ = path.withCString { cPath in
        Darwin.chmod(cPath, mode_t(0o600))
    }
}

private func atomicRename(_ fromPath: String, to toPath: String) -> Bool {
    fromPath.withCString { srcPtr in
        toPath.withCString { dstPtr in
            Darwin.rename(srcPtr, dstPtr) == 0
        }
    }
}

// MARK: - AppSupportPaths

/// Resolves Tidyreel's Application Support directory and persistence file URLs,
/// matching Flutter `path_provider_foundation` (`getApplicationSupportDirectory()`)
/// for bundle identifier `app.tidyreel.tidyreel`.
public enum AppSupportPaths {
    public static let bundleIdentifier = "app.tidyreel.tidyreel"
    public static let databaseFileName = "tidyreel.sqlite"
    public static let prefsFileName = "prefs.json"
    public static let secretsFileName = "secrets.json"
    public static let legacyTmdbCacheFileName = "tmdb_cache.json"

    public static func directoryURL(
        bundleIdentifier: String = AppSupportPaths.bundleIdentifier,
        createIfMissing: Bool = false
    ) throws -> URL {
        let fm = FileManager.default
        let baseAppSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        let dir: URL
        if baseAppSupport.lastPathComponent == bundleIdentifier {
            dir = baseAppSupport
        } else {
            dir = baseAppSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        }

        if createIfMissing {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func databaseURL(in baseDirectory: URL? = nil, createDirectory: Bool = false) throws -> URL {
        let dir = try resolveDirectory(baseDirectory, createIfMissing: createDirectory)
        return dir.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    public static func prefsURL(in baseDirectory: URL? = nil, createDirectory: Bool = false) throws -> URL {
        let dir = try resolveDirectory(baseDirectory, createIfMissing: createDirectory)
        return dir.appendingPathComponent(prefsFileName, isDirectory: false)
    }

    public static func secretsURL(in baseDirectory: URL? = nil, createDirectory: Bool = false) throws -> URL {
        let dir = try resolveDirectory(baseDirectory, createIfMissing: createDirectory)
        return dir.appendingPathComponent(secretsFileName, isDirectory: false)
    }

    public static func legacyTmdbCacheURL(in baseDirectory: URL? = nil) throws -> URL {
        let dir = try resolveDirectory(baseDirectory, createIfMissing: false)
        return dir.appendingPathComponent(legacyTmdbCacheFileName, isDirectory: false)
    }

    private static func resolveDirectory(_ custom: URL?, createIfMissing: Bool) throws -> URL {
        if let custom {
            if createIfMissing {
                try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            }
            return custom
        }
        return try directoryURL(createIfMissing: createIfMissing)
    }
}

// MARK: - JsonPrefsStore

/// Thread-safe JSON key-value store matching `JsonStore` in `bootstrap.dart` (`prefs.json`).
/// Preserves corrupt-file backup (`.broken`) behavior, supports optional coalesced async debounced
/// background flushing (`flushDebounceMs > 0`) with synchronous `flushSync()`, and uses POSIX
/// `Darwin.chmod(path, 0o600)` directly when `restrictPermissions` is enabled.
public final class JsonPrefsStore: @unchecked Sendable {
    public static let settingsKey = "settings"
    public static let connectionsKey = "connections"
    public static let namingKey = "naming"
    public static let titleRulesKey = "titleRules"

    private let fileURL: URL?
    private let restrictPermissions: Bool
    private let flushDebounceMs: Int
    private let ioQueue: DispatchQueue
    private let lock = NSLock()
    private var data: [String: Any]
    private var dirty: Bool = false
    private var flushToken: UInt64 = 0
    private var pendingFlushWorkItem: DispatchWorkItem?

    public init(fileURL: URL?, restrictPermissions: Bool = false, flushDebounceMs: Int = 0) {
        self.fileURL = fileURL
        self.restrictPermissions = restrictPermissions
        self.flushDebounceMs = max(0, flushDebounceMs)
        self.ioQueue = DispatchQueue(label: "app.tidyreel.persistence.filestore", qos: .utility)

        guard let fileURL else {
            self.data = [:]
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            self.data = [:]
            return
        }

        do {
            let rawData = try Data(contentsOf: fileURL)
            guard let parsed = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            self.data = parsed
        } catch {
            // A corrupt prefs/secrets file must not brick the app; move it aside to .broken.
            let brokenPath = fileURL.path + ".broken"
            if !atomicRename(fileURL.path, to: brokenPath) {
                if fm.fileExists(atPath: brokenPath) {
                    try? fm.removeItem(atPath: brokenPath)
                }
                try? fm.moveItem(atPath: fileURL.path, toPath: brokenPath)
            }
            if restrictPermissions && fm.fileExists(atPath: brokenPath) {
                applyRestrictedPermissions(brokenPath)
            }
            self.data = [:]
        }
    }

    deinit {
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil
        if dirty, let fileURL, let encoded = serializeData(data) {
            Self.writeAtomically(encoded, to: fileURL, restrictPermissions: restrictPermissions)
        }
    }

    public static func memory() -> JsonPrefsStore {
        JsonPrefsStore(fileURL: nil)
    }

    public func read(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        let val = data[key]
        if val is NSNull { return nil }
        return val
    }

    public func readDictionary(_ key: String) -> [String: Any]? {
        read(key) as? [String: Any]
    }

    public func readArray(_ key: String) -> [Any]? {
        read(key) as? [Any]
    }

    public func readString(_ key: String) -> String? {
        read(key) as? String
    }

    public func readBool(_ key: String) -> Bool? {
        read(key) as? Bool
    }

    public func allKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(data.keys)
    }

    public func write(_ key: String, _ value: Any?) {
        lock.lock()
        data[key] = value ?? NSNull()
        persistAfterMutationLocked()
        lock.unlock()
    }

    public func write(_ key: String, value: Any?) {
        write(key, value)
    }

    public func remove(_ key: String) {
        lock.lock()
        if data.removeValue(forKey: key) != nil {
            persistAfterMutationLocked()
        }
        lock.unlock()
    }

    public func writeAll(_ entries: [String: Any]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        for (k, v) in entries {
            data[k] = v
        }
        persistAfterMutationLocked()
        lock.unlock()
    }

    /// Synchronously flushes any pending debounced write (and waits for any in-flight background
    /// write) to disk. Intended for clean shutdown (`applicationWillTerminate`).
    public func flushSync() {
        guard let fileURL else { return }
        ioQueue.sync {
            let encoded: Data?
            lock.lock()
            pendingFlushWorkItem?.cancel()
            pendingFlushWorkItem = nil
            flushToken &+= 1
            if dirty {
                encoded = serializeData(data)
                dirty = false
            } else {
                encoded = nil
            }
            lock.unlock()

            if let encoded {
                Self.writeAtomically(encoded, to: fileURL, restrictPermissions: restrictPermissions)
            }
        }
    }

    func flushIfNeededOnOpen() {
        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            flushImmediateLocked()
        } else if restrictPermissions {
            applyRestrictedPermissions(fileURL.path)
        }
    }

    private func persistAfterMutationLocked() {
        guard fileURL != nil else { return }
        if flushDebounceMs > 0 {
            scheduleFlushLocked()
        } else {
            flushImmediateLocked()
        }
    }

    private func scheduleFlushLocked() {
        dirty = true
        flushToken &+= 1
        let expectedToken = flushToken
        pendingFlushWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performScheduledFlush(expectedToken: expectedToken)
        }
        pendingFlushWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + .milliseconds(flushDebounceMs), execute: workItem)
    }

    private func performScheduledFlush(expectedToken: UInt64) {
        guard let fileURL else { return }
        let encoded: Data?
        lock.lock()
        if flushToken == expectedToken && dirty {
            pendingFlushWorkItem = nil
            encoded = serializeData(data)
            dirty = false
        } else {
            encoded = nil
        }
        lock.unlock()

        if let encoded {
            Self.writeAtomically(encoded, to: fileURL, restrictPermissions: restrictPermissions)
        }
    }

    private func flushImmediateLocked() {
        guard let fileURL else { return }
        dirty = false
        guard let encoded = serializeData(data) else { return }
        Self.writeAtomically(encoded, to: fileURL, restrictPermissions: restrictPermissions)
    }

    private func serializeData(_ snapshot: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(snapshot) else { return nil }
        return try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
    }

    private static func writeAtomically(_ encoded: Data, to fileURL: URL, restrictPermissions: Bool) {
        let fm = FileManager.default
        let parentDir = fileURL.deletingLastPathComponent()
        if !parentDir.path.isEmpty {
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let tmpPath = fileURL.path + ".tmp"
        if writePayload(encoded, toPath: tmpPath, restrictPermissions: restrictPermissions) {
            if atomicRename(tmpPath, to: fileURL.path) {
                if restrictPermissions {
                    applyRestrictedPermissions(fileURL.path)
                }
                return
            }
        }

        // Cleanup tmp and fall back to direct write if atomic rename failed.
        if fm.fileExists(atPath: tmpPath) {
            try? fm.removeItem(atPath: tmpPath)
        }
        _ = writePayload(encoded, toPath: fileURL.path, restrictPermissions: restrictPermissions)
    }

    private static func writePayload(_ bytes: Data, toPath path: String, restrictPermissions: Bool) -> Bool {
        if restrictPermissions {
            let fd = path.withCString { cPath in
                Darwin.open(cPath, O_CREAT | O_WRONLY | O_TRUNC, mode_t(0o600))
            }
            guard fd >= 0 else { return false }
            _ = Darwin.fchmod(fd, mode_t(0o600))
            let writtenOk: Bool = bytes.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return true }
                var remaining = rawBuf.count
                var offset = 0
                while remaining > 0 {
                    let n = Darwin.write(fd, base.advanced(by: offset), remaining)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    remaining -= n
                    offset += n
                }
                return true
            }
            _ = Darwin.fsync(fd)
            _ = Darwin.close(fd)
            applyRestrictedPermissions(path)
            return writtenOk
        } else {
            do {
                try bytes.write(to: URL(fileURLWithPath: path), options: [])
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Typed Domain Helpers (prefs.json compatible)

    public func loadSettings(tmdbApiKey: String = "", defaultTmdbLang: String = "zh-CN") -> AppSettings {
        let dict = readDictionary(Self.settingsKey) ?? [:]
        return TidyreelCodecs.settingsFromDict(dict, tmdbApiKey: tmdbApiKey, defaultTmdbLang: defaultTmdbLang)
    }

    public func saveSettings(_ settings: AppSettings) {
        write(Self.settingsKey, TidyreelCodecs.settingsToDict(settings))
    }

    public func loadConnections() -> [ConnectionConfig] {
        guard let list = readArray(Self.connectionsKey) else { return [] }
        return list.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return TidyreelCodecs.connectionFromDict(dict)
        }
    }

    public func saveConnections(_ connections: [ConnectionConfig]) {
        write(Self.connectionsKey, connections.map(TidyreelCodecs.connectionToDict))
    }

    public func loadNamingProfile(default defaultProfile: NamingProfile = .vidhub) -> NamingProfile {
        guard let dict = readDictionary(Self.namingKey) else { return defaultProfile }
        return TidyreelCodecs.namingProfileFromDict(dict)
    }

    public func saveNamingProfile(_ profile: NamingProfile) {
        write(Self.namingKey, TidyreelCodecs.namingProfileToDict(profile))
    }

    public func loadTitleRules() -> TitleRules {
        guard let dict = readDictionary(Self.titleRulesKey) else { return TitleRules() }
        return TidyreelCodecs.titleRulesFromDict(dict)
    }

    public func saveTitleRules(_ rules: TitleRules) {
        write(Self.titleRulesKey, TidyreelCodecs.titleRulesToDict(rules))
    }
}

// MARK: - FileSecretStore

/// Thread-safe secret store matching `SecretStore` in `bootstrap.dart` (`secrets.json`).
/// Enforces POSIX `0o600` permissions via `Darwin.chmod` / `Darwin.fchmod` directly without
/// spawning external `chmod` subprocesses, supports optional debounced background flushes
/// with `flushSync()`, and preserves `.broken` corrupt-file backups with `0o600`.
public final class FileSecretStore: @unchecked Sendable {
    public static let tmdbApiKeySecret = "tmdb_api_key"
    public static let connectionPasswordPrefix = "conn:"
    public static let connectionDirPasswordsPrefix = "conn_dirs:"

    private let store: JsonPrefsStore

    public init(fileURL: URL?, flushDebounceMs: Int = 0) {
        let backing = JsonPrefsStore(
            fileURL: fileURL,
            restrictPermissions: true,
            flushDebounceMs: flushDebounceMs
        )
        backing.flushIfNeededOnOpen()
        self.store = backing
    }

    public static func memory() -> FileSecretStore {
        FileSecretStore(fileURL: nil)
    }

    public func read(_ key: String) -> String? {
        store.read(key) as? String
    }

    public func write(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else {
            store.remove(key)
            return
        }
        store.write(key, value)
    }

    public func write(_ key: String, value: String?) {
        write(key, value)
    }

    public func remove(_ key: String) {
        store.remove(key)
    }

    public func flushSync() {
        store.flushSync()
    }

    // MARK: - Typed Credential Helpers (secrets.json compatible)

    public func readTmdbApiKey() -> String? {
        read(Self.tmdbApiKeySecret)
    }

    public func writeTmdbApiKey(_ apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        write(Self.tmdbApiKeySecret, trimmed)
    }

    public func readConnectionPassword(_ id: ConnectionId) -> String? {
        read("\(Self.connectionPasswordPrefix)\(id.value)")
    }

    public func writeConnectionPassword(_ id: ConnectionId, password: String?) {
        write("\(Self.connectionPasswordPrefix)\(id.value)", password)
    }

    public func readConnectionDirPasswords(_ id: ConnectionId) -> [String: String] {
        guard let raw = read("\(Self.connectionDirPasswordsPrefix)\(id.value)"),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (rawDir, rawPw) in decoded {
            if let pw = rawPw as? String, !pw.isEmpty {
                out[normalizeDir(rawDir)] = pw
            }
        }
        return out
    }

    public func writeConnectionDirPasswords(_ id: ConnectionId, dirPasswords: [String: String]) {
        var clean: [String: String] = [:]
        for (rawDir, pw) in dirPasswords where !rawDir.trimmingCharacters(in: .whitespaces).isEmpty && !pw.isEmpty {
            clean[normalizeDir(rawDir)] = pw
        }
        let key = "\(Self.connectionDirPasswordsPrefix)\(id.value)"
        if clean.isEmpty {
            remove(key)
        } else if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) {
            write(key, String(decoding: data, as: UTF8.self))
        }
    }

    public func readCredentials(for id: ConnectionId) -> Credentials {
        Credentials(
            password: readConnectionPassword(id),
            dirPasswords: readConnectionDirPasswords(id)
        )
    }
}
