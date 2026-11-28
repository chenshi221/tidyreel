import CoreFoundation
import Foundation

// MARK: - HTTPTransport

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    public let session: URLSession
    private let ownsSession: Bool

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}

// MARK: - Sendable JSON Representation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any value: Any) {
        if value is NSNull {
            self = .null
        } else if let str = value as? String {
            self = .string(str)
        } else if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                self = .bool(num.boolValue)
            } else {
                let objCType = String(cString: num.objCType)
                switch objCType {
                case "f", "d":
                    self = .double(num.doubleValue)
                default:
                    self = .int(num.intValue)
                }
            }
        } else if let arr = value as? [Any] {
            self = .array(arr.map(JSONValue.init(any:)))
        } else if let dict = value as? [String: Any] {
            var mapped: [String: JSONValue] = [:]
            mapped.reserveCapacity(dict.count)
            for (k, v) in dict {
                mapped[k] = JSONValue(any: v)
            }
            self = .object(mapped)
        } else if let dict = value as? NSDictionary {
            var mapped: [String: JSONValue] = [:]
            for (k, v) in dict {
                if let ks = k as? String {
                    mapped[ks] = JSONValue(any: v)
                }
            }
            self = .object(mapped)
        } else {
            self = .null
        }
    }

    public static func parse(from data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(any: raw)
    }

    public static func parseObject(from data: Data) -> [String: JSONValue]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any] else {
            return nil
        }
        return JSONValue(any: dict).objectValue
    }

    public static func parseObject(from string: String) -> [String: JSONValue]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return parseObject(from: data)
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let d) = self { return d }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectArray: [[String: JSONValue]] {
        guard case .array(let a) = self else { return [] }
        return a.compactMap(\.objectValue)
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var nonEmptyString: String? {
        if case .string(let s) = self, !s.isEmpty { return s }
        return nil
    }

    public var trimmedString: String? {
        guard case .string(let s) = self else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public var intValue: Int? {
        switch self {
        case .int(let i):
            return i
        case .double(let d):
            guard d.isFinite else { return nil }
            return Int(d)
        default:
            return nil
        }
    }

    public var intOrParsed: Int? {
        if let i = intValue { return i }
        if let t = trimmedString { return Int(t) }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i):
            return Double(i)
        case .double(let d):
            return d
        default:
            return nil
        }
    }

    public var lossyString: String? {
        switch self {
        case .string(let s):
            return s
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return String(b)
        default:
            return nil
        }
    }
}

// MARK: - Internal LRU Cache & URL Encoding Helpers

struct LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Node: Sendable {
        let key: Key
        var value: Value
        var prev: Int? // toward MRU (head)
        var next: Int? // toward LRU (tail)
    }

    let capacity: Int
    private var nodes: [Node?] = []
    private var freeIndices: [Int] = []
    private var indexByKey: [Key: Int] = [:]
    private var head: Int?
    private var tail: Int?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        indexByKey.count
    }

    var isEmpty: Bool {
        indexByKey.isEmpty
    }

    var values: [Value] {
        var out: [Value] = []
        out.reserveCapacity(indexByKey.count)
        var current = head
        while let idx = current, let node = nodes[idx] {
            out.append(node.value)
            current = node.next
        }
        return out
    }

    mutating func get(_ key: Key) -> Value? {
        guard let idx = indexByKey[key], let node = nodes[idx] else {
            return nil
        }
        moveToHead(idx)
        return node.value
    }

    func peek(_ key: Key) -> Value? {
        guard let idx = indexByKey[key] else { return nil }
        return nodes[idx]?.value
    }

    mutating func put(_ key: Key, _ value: Value) {
        if let existingIdx = indexByKey[key] {
            nodes[existingIdx]?.value = value
            moveToHead(existingIdx)
            return
        }
        while indexByKey.count >= capacity {
            if removeOldest() == nil {
                break
            }
        }
        let idx: Int
        if let reused = freeIndices.popLast() {
            nodes[reused] = Node(key: key, value: value, prev: nil, next: nil)
            idx = reused
        } else {
            idx = nodes.count
            nodes.append(Node(key: key, value: value, prev: nil, next: nil))
        }
        indexByKey[key] = idx
        attachAtHead(idx)
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let idx = indexByKey.removeValue(forKey: key), let node = nodes[idx] else {
            return nil
        }
        unlink(idx)
        nodes[idx] = nil
        freeIndices.append(idx)
        return node.value
    }

    mutating func remove(_ key: Key) {
        _ = removeValue(forKey: key)
    }

    @discardableResult
    mutating func removeOldest() -> (key: Key, value: Value)? {
        guard let idx = tail, let node = nodes[idx] else {
            return nil
        }
        indexByKey.removeValue(forKey: node.key)
        unlink(idx)
        nodes[idx] = nil
        freeIndices.append(idx)
        return (node.key, node.value)
    }

    mutating func removeAll() {
        nodes.removeAll()
        freeIndices.removeAll()
        indexByKey.removeAll()
        head = nil
        tail = nil
    }

    private mutating func unlink(_ idx: Int) {
        guard let node = nodes[idx] else { return }
        let prevIdx = node.prev
        let nextIdx = node.next
        if let p = prevIdx {
            nodes[p]?.next = nextIdx
        } else {
            head = nextIdx
        }
        if let n = nextIdx {
            nodes[n]?.prev = prevIdx
        } else {
            tail = prevIdx
        }
        nodes[idx]?.prev = nil
        nodes[idx]?.next = nil
    }

    private mutating func attachAtHead(_ idx: Int) {
        let oldHead = head
        nodes[idx]?.prev = nil
        nodes[idx]?.next = oldHead
        if let h = oldHead {
            nodes[h]?.prev = idx
        } else {
            tail = idx
        }
        head = idx
    }

    private mutating func moveToHead(_ idx: Int) {
        guard head != idx else { return }
        unlink(idx)
        attachAtHead(idx)
    }
}

public enum MetadataURLHelpers {
    private static let uriComponentAllowed: CharacterSet = {
        var cs = CharacterSet()
        cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return cs
    }()

    private static let rfc3986Unreserved: CharacterSet = {
        var cs = CharacterSet()
        cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return cs
    }()

    private static let queryKeyValueAllowed: CharacterSet = {
        var cs = CharacterSet()
        cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")
        return cs
    }()

    static func encodeURIComponent(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? string
    }

    static func encodeRFC3986Component(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? string
    }

    static func buildURL(baseUrl: String, percentEncodedPath: String, query: [String: String]) -> URL? {
        var cleanBase = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleanBase.hasSuffix("/") {
            cleanBase.removeLast()
        }
        guard var components = URLComponents(string: cleanBase) else {
            return nil
        }
        let relPath = percentEncodedPath.hasPrefix("/") ? percentEncodedPath : "/" + percentEncodedPath
        let basePath = components.percentEncodedPath
        if basePath.isEmpty || basePath == "/" {
            components.percentEncodedPath = relPath
        } else {
            let trimmedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            components.percentEncodedPath = trimmedBasePath + relPath
        }
        if !query.isEmpty {
            let encodedPairs = query
                .sorted { $0.key < $1.key }
                .map { pair -> String in
                    let k = pair.key.addingPercentEncoding(withAllowedCharacters: queryKeyValueAllowed) ?? pair.key
                    let v = pair.value.addingPercentEncoding(withAllowedCharacters: queryKeyValueAllowed) ?? pair.value
                    return "\(k)=\(v)"
                }
            components.percentEncodedQuery = encodedPairs.joined(separator: "&")
        } else {
            components.percentEncodedQuery = nil
        }
        return components.url
    }

    public static func sleepSeconds(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanos = UInt64((seconds * 1_000_000_000).rounded())
        if nanos > 0 {
            try await Task.sleep(nanoseconds: nanos)
        }
    }
}
