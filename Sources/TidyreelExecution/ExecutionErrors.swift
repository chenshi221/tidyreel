import Foundation
import TidyreelModels

public enum TidyreelExecutionError: Error, LocalizedError, Equatable, Sendable {
    case invalidState(String)
    case invalidArgument(String)

    public var message: String {
        switch self {
        case .invalidState(let msg), .invalidArgument(let msg):
            return msg
        }
    }

    public var errorDescription: String? { message }
}

internal func executionErrorMessage(_ error: any Error) -> String {
    if let se = error as? StorageError {
        return se.message.isEmpty ? se.code.rawValue : se.message
    }
    if let te = error as? TidyreelExecutionError {
        return te.message
    }
    if let tmdb = error as? TmdbError, !tmdb.message.isEmpty {
        return tmdb.message
    }
    if let le = error as? any LocalizedError, let desc = le.errorDescription, !desc.isEmpty {
        return desc
    }
    return String(describing: error)
}
