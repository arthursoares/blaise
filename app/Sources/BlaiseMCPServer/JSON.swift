import Foundation

/// A JSON value with ordered object keys. `.text` marks content strings the
/// size budget may cut; `.str` strings (ids, dates, statuses, cursors) are
/// never cut.
indirect enum JSON: Sendable {
    case str(String)
    case text(String)
    case int(Int)
    case bool(Bool)
    case null
    case arr([JSON])
    case obj([(String, JSON)])

    /// Compact serialization; the same value always serializes to the same
    /// text, so lengths of parts add up to the length of the whole.
    var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .str(let s), .text(let s): JSON.writeString(s, to: &out)
        case .int(let n): out += String(n)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .arr(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .obj(let fields):
            out += "{"
            for (i, (key, value)) in fields.enumerated() {
                if i > 0 { out += "," }
                JSON.writeString(key, to: &out)
                out += ":"
                value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

/// An integer from `JSONSerialization` output: not a boolean, not a fraction,
/// and within `Int`'s range (an unsigned value above `Int.max` is refused).
func jsonInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
        CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
    else { return nil }
    let type = String(cString: number.objCType)
    guard "qlisQLIS".contains(type), type != "Q" || number.uint64Value <= UInt64(Int.max) else { return nil }
    return number.intValue
}
