import Foundation

/// A JSON value that keeps object keys in file order and numbers as written.
///
/// `JSONSerialization` reorders keys, so writing `settings.json` back through it would
/// reshuffle the user's file. Parsing into this and printing it the way Claude Code
/// writes the file (two-space indent, like `JSON.stringify(value, null, 2)`) gives back
/// the very same bytes for a file in that format.
public indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number's original text, so `5` never turns into `5.0`.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    // MARK: - Access

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var arrayValue: [OrderedJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [(key: String, value: OrderedJSON)]? {
        if case .object(let members) = self { return members }
        return nil
    }

    // MARK: - Parse

    public struct ParseError: Error, Equatable {}

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.atEnd else { throw ParseError() }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        var atEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while !atEnd, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard !atEnd, scalars[index] == scalar else { throw ParseError() }
            index += 1
        }

        mutating func literal(_ word: String) throws {
            for scalar in word.unicodeScalars { try expect(scalar) }
        }

        mutating func value() throws -> OrderedJSON {
            guard !atEnd else { throw ParseError() }
            switch scalars[index] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func object() throws -> OrderedJSON {
            try expect("{")
            var members: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if !atEnd, scalars[index] == "}" { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                members.append((key, try value()))
                skipWhitespace()
                guard !atEnd else { throw ParseError() }
                if scalars[index] == "," { index += 1; continue }
                try expect("}")
                return .object(members)
            }
        }

        mutating func array() throws -> OrderedJSON {
            try expect("[")
            var items: [OrderedJSON] = []
            skipWhitespace()
            if !atEnd, scalars[index] == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard !atEnd else { throw ParseError() }
                if scalars[index] == "," { index += 1; continue }
                try expect("]")
                return .array(items)
            }
        }

        mutating func string() throws -> String {
            try expect("\"")
            var result = String.UnicodeScalarView()
            while true {
                guard !atEnd else { throw ParseError() }
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    guard !atEnd else { throw ParseError() }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u": result.append(try unicodeEscape())
                    default: throw ParseError()
                    }
                default:
                    guard scalar.value >= 0x20 else { throw ParseError() }
                    result.append(scalar)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count,
                  let value = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16)
            else { throw ParseError() }
            index += 4
            return value
        }

        mutating func unicodeEscape() throws -> Unicode.Scalar {
            let high = try hex4()
            if (0xD800...0xDBFF).contains(high) {
                try literal("\\u")
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
                else { throw ParseError() }
                return scalar
            }
            guard let scalar = Unicode.Scalar(high) else { throw ParseError() }
            return scalar
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            while !atEnd, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            guard !text.isEmpty, Double(text) != nil else { throw ParseError() }
            return .number(text)
        }
    }

    // MARK: - Print

    /// Two-space indented, as `JSON.stringify(value, null, 2)` prints it.
    public func printed() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): Self.writeString(text, into: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                item.write(into: &out, indent: indent + 1)
                out += offset == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                Self.writeString(member.key, into: &out)
                out += ": "
                member.value.write(into: &out, indent: indent + 1)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
