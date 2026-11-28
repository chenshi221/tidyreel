import Foundation
import TidyreelModels

public enum TidyreelStorageModule {}

/// Builds the appropriate `StorageBackend` for a saved `ConnectionConfig`.
public func createStorageBackend(
    config: ConnectionConfig,
    credentials: Credentials
) -> any StorageBackend {
    switch config.type {
    case .alist:
        return AlistBackend(config: config, credentials: credentials)
    case .webdav:
        return WebDAVBackend(config: config, credentials: credentials)
    case .smb:
        return SMBBackend(config: config, credentials: credentials)
    case .local:
        return LocalBackend(rootPath: config.endpoint)
    }
}
