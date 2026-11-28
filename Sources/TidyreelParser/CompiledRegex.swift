import Foundation

/// Match wrapper exposing UTF-16 code-unit offsets (`start`, `end`) and capture groups,
/// matching Dart `RegExpMatch` indexing semantics.
struct RegexMatch {
    let source: String
    let result: NSTextCheckingResult

    @inline(__always)
    var start: Int { result.range.location }

    @inline(__always)
    var end: Int { result.range.location + result.range.length }

    subscript(_ index: Int) -> String? {
        guard index >= 0, index < result.numberOfRanges else { return nil }
        let r = result.range(at: index)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: source) else { return nil }
        return String(source[swiftRange])
    }

    var groupCount: Int {
        max(0, result.numberOfRanges - 1)
    }

    func named(_ name: String) -> String? {
        let r = result.range(withName: name)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: source) else { return nil }
        return String(source[swiftRange])
    }
}

/// Thread-safe, pre-compiled wrapper around `NSRegularExpression`.
struct CompiledRegex: @unchecked Sendable {
    let nsRegex: NSRegularExpression

    init(_ pattern: String, caseSensitive: Bool = true) {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        // Static patterns are known-valid constants verified at startup/tests.
        self.nsRegex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    init?(dynamic pattern: String, caseSensitive: Bool = true) {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        self.nsRegex = compiled
    }

    @inline(__always)
    func hasMatch(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return nsRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    @inline(__always)
    func firstMatch(_ s: String) -> RegexMatch? {
        let range = NSRange(location: 0, length: s.utf16.count)
        guard let res = nsRegex.firstMatch(in: s, options: [], range: range) else { return nil }
        return RegexMatch(source: s, result: res)
    }

    func allMatches(_ s: String) -> [RegexMatch] {
        let range = NSRange(location: 0, length: s.utf16.count)
        return nsRegex.matches(in: s, options: [], range: range).map {
            RegexMatch(source: s, result: $0)
        }
    }

    /// Matches anchored at `utf16Pos` (equivalent to Dart `RegExp.matchAsPrefix(s, pos)`).
    @inline(__always)
    func matchAtPrefix(_ s: String, utf16Pos: Int, totalUtf16Len: Int) -> RegexMatch? {
        guard utf16Pos >= 0, utf16Pos <= totalUtf16Len else { return nil }
        let range = NSRange(location: utf16Pos, length: totalUtf16Len - utf16Pos)
        guard let res = nsRegex.firstMatch(in: s, options: [.anchored], range: range) else { return nil }
        return RegexMatch(source: s, result: res)
    }

    /// Fast zero-allocation prefix range check returning the match's UTF-16 end offset.
    @inline(__always)
    func matchEndAtPrefix(_ s: String, utf16Pos: Int, totalUtf16Len: Int) -> Int? {
        guard utf16Pos >= 0, utf16Pos <= totalUtf16Len else { return nil }
        let range = NSRange(location: utf16Pos, length: totalUtf16Len - utf16Pos)
        let matched = nsRegex.rangeOfFirstMatch(in: s, options: [.anchored], range: range)
        guard matched.location != NSNotFound else { return nil }
        return matched.location + matched.length
    }

    /// Replaces every match with a literal string (no `$1` / `\` template escaping pitfalls).
    func replaceAll(_ s: String, with literal: String) -> String {
        let total = s.utf16.count
        guard total > 0 else {
            return hasMatch(s) ? literal : s
        }
        let matches = nsRegex.matches(in: s, options: [], range: NSRange(location: 0, length: total))
        if matches.isEmpty { return s }

        var out = ""
        out.reserveCapacity(s.count)
        var cursor = 0
        for m in matches {
            let r = m.range
            if r.location > cursor {
                out += utf16Sub(s, cursor, r.location)
            }
            out += literal
            cursor = r.location + r.length
        }
        if cursor < total {
            out += utf16Sub(s, cursor, total)
        }
        return out
    }

    /// Replaces only the first match with a literal string.
    func replaceFirst(_ s: String, with literal: String) -> String {
        let total = s.utf16.count
        guard let m = nsRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: total)) else {
            return s
        }
        let r = m.range
        return utf16Sub(s, 0, r.location) + literal + utf16Sub(s, r.location + r.length, total)
    }

    /// Replaces only the first match using a closure over `RegexMatch`.
    func replaceFirstMapped(_ s: String, _ transform: (RegexMatch) -> String) -> String {
        let total = s.utf16.count
        guard let res = nsRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: total)) else {
            return s
        }
        let match = RegexMatch(source: s, result: res)
        return utf16Sub(s, 0, match.start) + transform(match) + utf16Sub(s, match.end, total)
    }

    /// Replaces every match using a closure over `RegexMatch`.
    func replaceAllMapped(_ s: String, _ transform: (RegexMatch) -> String) -> String {
        let total = s.utf16.count
        let matches = nsRegex.matches(in: s, options: [], range: NSRange(location: 0, length: total))
        if matches.isEmpty { return s }

        var out = ""
        out.reserveCapacity(s.count)
        var cursor = 0
        for res in matches {
            let match = RegexMatch(source: s, result: res)
            if match.start > cursor {
                out += utf16Sub(s, cursor, match.start)
            }
            out += transform(match)
            cursor = match.end
        }
        if cursor < total {
            out += utf16Sub(s, cursor, total)
        }
        return out
    }
}

// MARK: - UTF-16 String Slicing Helpers

@inline(__always)
func utf16Count(_ s: String) -> Int {
    s.utf16.count
}

@inline(__always)
func utf16Sub(_ s: String, _ start: Int, _ end: Int) -> String {
    guard start < end else { return "" }
    let nsRange = NSRange(location: start, length: end - start)
    if let range = Range(nsRange, in: s) {
        return String(s[range])
    }
    let u = s.utf16
    let lo = u.index(u.startIndex, offsetBy: max(0, start))
    let hi = u.index(u.startIndex, offsetBy: min(u.count, end))
    return String(decoding: u[lo..<hi], as: UTF16.self)
}

@inline(__always)
func utf16ReplaceRange(_ s: String, _ start: Int, _ end: Int, with replacement: String) -> String {
    let total = s.utf16.count
    return utf16Sub(s, 0, start) + replacement + utf16Sub(s, end, total)
}

@inline(__always)
func utf16IndexOf(_ s: String, _ codeUnit: UInt16) -> Int? {
    var idx = 0
    for u in s.utf16 {
        if u == codeUnit { return idx }
        idx += 1
    }
    return nil
}
