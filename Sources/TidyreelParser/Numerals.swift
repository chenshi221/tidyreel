import Foundation

private let cnDigitMap: [Character: Int] = [
    "零": 0,
    "〇": 0,
    "一": 1,
    "二": 2,
    "两": 2,
    "兩": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
]

private let cnUnitMap: [Character: Int] = [
    "十": 10,
    "百": 100,
    "千": 1000,
]

/// Converts a Chinese or ASCII numeral string into an `Int`
/// (e.g. `"十二"` -> `12`, `"二十"` -> `20`, `"一百零五"` -> `105`, `"二〇"` -> `20`, `"两"`/`"兩"` -> `2`, `"05"` -> `5`).
public func parseChineseInt(_ text: String) -> Int? {
    guard !text.isEmpty else { return nil }
    if let asInt = Int(text) {
        // Reject explicit leading '+' if any, though Int("05") == 5 matches Dart int.tryParse.
        return asInt
    }

    let chars = Array(text)
    if !chars.contains(where: { cnUnitMap[$0] != nil }) {
        // Positional digits: 二〇 -> 20
        var n = 0
        for c in chars {
            guard let d = cnDigitMap[c] else { return nil }
            n = n * 10 + d
        }
        return n
    }

    var total = 0
    var cur: Int? = nil // nil = no pending digit; 0 = explicit 零; 1..9 = pending digit
    var lastUnit = 10000
    for c in chars {
        if let d = cnDigitMap[c] {
            if let existing = cur {
                // Only an explicit 零 followed by a non-zero digit is valid ("一百零五").
                if existing == 0 && d != 0 {
                    cur = d
                } else {
                    return nil
                }
            } else {
                cur = d
            }
        } else if let u = cnUnitMap[c] {
            // Units must strictly decrease (千 > 百 > 十), and explicit 零 cannot precede a unit ("零十").
            if u >= lastUnit || cur == 0 { return nil }
            if cur == nil && u != 10 { return nil }
            total += (cur ?? 1) * u
            cur = nil
            lastUnit = u
        } else {
            return nil
        }
    }
    return total + (cur ?? 0)
}
