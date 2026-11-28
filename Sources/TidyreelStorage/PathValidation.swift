import Foundation
import TidyreelModels

func validateChildName(_ name: String) throws {
    if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\\") {
        throw StorageError(.other, "无效的文件名：\(name)")
    }
}

func validatedPathSegments(_ path: String) throws -> [String] {
    if path.contains("\\") {
        throw StorageError(.other, "路径包含非法字符：\(path)")
    }
    var segs: [String] = []
    for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
        let s = String(raw)
        if s == "." || s == ".." {
            throw StorageError(.other, "路径超出根目录范围：\(path)")
        }
        segs.append(s)
    }
    return segs
}

func posixTrimDir(_ path: String) -> String {
    var s = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "/" }
    while s.count > 1 && s.hasSuffix("/") {
        s.removeLast()
    }
    return s.hasPrefix("/") ? s : "/" + s
}

func posixJoin(_ dir: String, _ name: String) -> String {
    let cleanDir = posixTrimDir(dir)
    if cleanDir == "/" {
        return "/\(name)"
    }
    return "\(cleanDir)/\(name)"
}

func posixDirname(_ path: String) -> String {
    var p = path
    while p.count > 1 && p.hasSuffix("/") {
        p.removeLast()
    }
    guard let idx = p.lastIndex(of: "/") else { return "/" }
    if idx == p.startIndex { return "/" }
    return String(p[..<idx])
}

func posixBasename(_ path: String) -> String {
    var p = path
    while p.count > 1 && p.hasSuffix("/") {
        p.removeLast()
    }
    guard let idx = p.lastIndex(of: "/") else { return p }
    return String(p[p.index(after: idx)...])
}

private let uriComponentAllowed: CharacterSet = {
    var cs = CharacterSet()
    cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return cs
}()

private let pathSegmentAllowed: CharacterSet = {
    var cs = CharacterSet()
    cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")
    return cs
}()

func encodeURIComponent(_ string: String) -> String {
    string.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? string
}

func encodePathSegment(_ segment: String) -> String {
    segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? segment
}

func effectivePort(of url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    case "smb": return 445
    default: return nil
    }
}

func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased()
        && a.host?.lowercased() == b.host?.lowercased()
        && effectivePort(of: a) == effectivePort(of: b)
}

private func isAsciiHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39)
        || (byte >= 0x41 && byte <= 0x46)
        || (byte >= 0x61 && byte <= 0x66)
}

private let looseURLAllowedBytes: Set<UInt8> = {
    let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;="
    return Set(chars.utf8)
}()

/// Encodes spaces, non-ASCII bytes, and unescaped specials in a raw URL/href string
/// without double-encoding existing `%XX` sequences or hiding malformed `[::bad-uri` hosts.
func percentEncodeLooseURL(_ raw: String, escapeHash: Bool = false) -> String {
    let bytes = Array(raw.utf8)
    var out = String()
    out.reserveCapacity(bytes.count + 16)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if escapeHash && b == 0x23 { // '#'
            out.append("%23")
            i += 1
            continue
        }
        if b == 0x25 { // '%'
            if i + 2 < bytes.count && isAsciiHex(bytes[i + 1]) && isAsciiHex(bytes[i + 2]) {
                out.append(Character(UnicodeScalar(b)))
                out.append(Character(UnicodeScalar(bytes[i + 1])))
                out.append(Character(UnicodeScalar(bytes[i + 2])))
                i += 3
                continue
            } else {
                out.append("%25")
                i += 1
                continue
            }
        }
        if looseURLAllowedBytes.contains(b) {
            out.append(Character(UnicodeScalar(b)))
        } else {
            out.append(String(format: "%%%02X", b))
        }
        i += 1
    }
    return out
}

/// Validates and resolves `raw` against `base`, returning `nil` for malformed URLs (e.g. `http://[::bad-uri`).
func resolveValidURL(_ raw: String, relativeTo base: URL, escapeHash: Bool = false) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let encoded = percentEncodeLooseURL(trimmed, escapeHash: escapeHash)
    guard let comps = URLComponents(string: encoded) else { return nil }
    guard let url = comps.url(relativeTo: base)?.absoluteURL,
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else { return nil }
    return url
}

func parseRangeHeader(_ value: String?) -> (start: Int64, length: Int)? {
    guard let value else { return nil }
    let prefix = "bytes="
    guard value.lowercased().hasPrefix(prefix) else { return nil }
    let spec = value.dropFirst(prefix.count)
    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          let start = Int64(parts[0]),
          let end = Int64(parts[1]),
          start >= 0,
          end >= start else {
        return nil
    }
    let count64 = end - start + 1
    let length = count64 > Int64(Int.max) ? Int.max : Int(count64)
    return (start, length)
}

func describeTransportError(_ error: Error) -> String {
    if let sErr = error as? StorageError {
        return sErr.message
    }
    if let urlErr = error as? URLError {
        switch urlErr.code {
        case .timedOut:
            return "连接超时"
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed:
            return "HTTPS 证书校验失败"
        case .cancelled:
            return "请求已取消"
        case .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed:
            let detail = urlErr.localizedDescription
            return detail.isEmpty ? "无法连接服务器" : "无法连接服务器（\(detail)）"
        default:
            return urlErr.localizedDescription
        }
    }
    return error.localizedDescription
}
