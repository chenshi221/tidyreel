import Foundation

public struct ConnectionId: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public var value: String { rawValue }
    public var description: String { rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct TaskId: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public var value: String { rawValue }
    public var description: String { rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct GroupId: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public var value: String { rawValue }
    public var description: String { rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct OpId: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public var value: String { rawValue }
    public var description: String { rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct BatchId: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public var value: String { rawValue }
    public var description: String { rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}
