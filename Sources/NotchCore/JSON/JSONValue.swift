import Foundation

/// A JSON value that keeps object key order and number spelling exactly as
/// read, so editing a user's config file changes only what we touch.
public enum JSONValue: Equatable, Sendable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)          // raw literal, e.g. "30", "1.5e3"
    case bool(Bool)
    case null

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(a), .array(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.last { $0.key == key }?.value
    }

    public var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// Whole part of the number, or nil when it doesn't fit in an Int.
    public var int: Int? {
        guard case let .number(n) = self else { return nil }
        if let exact = Int(n) { return exact }
        guard let d = Double(n), d.isFinite, d > -9.2e18, d < 9.2e18 else { return nil }
        return Int(d)
    }

    public var array: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var objectPairs: [(key: String, value: JSONValue)]? {
        if case let .object(p) = self { return p }
        return nil
    }

    /// Returns a copy with `key` set (replacing in place to keep order, or appended).
    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case var .object(pairs) = self else { return self }
        if let i = pairs.lastIndex(where: { $0.key == key }) {
            pairs[i].value = value
        } else {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    public func removing(_ key: String) -> JSONValue {
        guard case let .object(pairs) = self else { return self }
        return .object(pairs.filter { $0.key != key })
    }
}

// MARK: - Parsing

public enum JSONParseError: Error, Equatable {
    case unexpectedEnd
    case unexpected(Character, offset: Int)
    case invalidEscape(offset: Int)
    case trailingContent(offset: Int)
    case tooDeep
}

extension JSONValue {
    public static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        var parser = Parser(Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw .trailingContent(offset: parser.index) }
        return value
    }

    public static func parse(_ data: Data) throws(JSONParseError) -> JSONValue {
        try parse(String(decoding: data, as: UTF8.self))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func peek() throws(JSONParseError) -> UInt8 {
            guard index < bytes.count else { throw .unexpectedEnd }
            return bytes[index]
        }

        mutating func expect(_ byte: UInt8) throws(JSONParseError) {
            let b = try peek()
            guard b == byte else { throw .unexpected(Character(UnicodeScalar(b)), offset: index) }
            index += 1
        }

        mutating func literal(_ word: String, _ value: JSONValue) throws(JSONParseError) -> JSONValue {
            for b in word.utf8 { try expect(b) }
            return value
        }

        mutating func value(depth: Int) throws(JSONParseError) -> JSONValue {
            guard depth < 128 else { throw .tooDeep }
            switch try peek() {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
            case let b: throw .unexpected(Character(UnicodeScalar(b)), offset: index)
            }
        }

        mutating func object(depth: Int) throws(JSONParseError) -> JSONValue {
            try expect(UInt8(ascii: "{"))
            var pairs: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if try peek() == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                pairs.append((key, try value(depth: depth + 1)))
                skipWhitespace()
                if try peek() == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "}"))
                return .object(pairs)
            }
        }

        mutating func array(depth: Int) throws(JSONParseError) -> JSONValue {
            try expect(UInt8(ascii: "["))
            var items: [JSONValue] = []
            skipWhitespace()
            if try peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                if try peek() == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        mutating func number() throws(JSONParseError) -> JSONValue {
            let start = index
            while index < bytes.count,
                  "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            guard Double(raw) != nil else {
                throw .unexpected(Character(UnicodeScalar(bytes[start])), offset: start)
            }
            return .number(raw)
        }

        mutating func hex4() throws(JSONParseError) -> UInt32 {
            guard index + 4 <= bytes.count,
                  let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw .invalidEscape(offset: index) }
            index += 4
            return v
        }

        mutating func string() throws(JSONParseError) -> String {
            try expect(UInt8(ascii: "\""))
            var out = [UInt8]()
            while true {
                guard index < bytes.count else { throw .unexpectedEnd }
                let b = bytes[index]
                index += 1
                switch b {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw .unexpectedEnd }
                    let e = bytes[index]
                    index += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        // Join a surrogate pair only when the next escape really is
                        // a low surrogate; otherwise leave it to be read on its own.
                        if (0xD800...0xDBFF).contains(scalar),
                           index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                           bytes[index + 1] == UInt8(ascii: "u") {
                            let resume = index
                            index += 2
                            let low = try hex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                index = resume
                            }
                        }
                        let s = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(s)).utf8))
                    default:
                        throw .invalidEscape(offset: index - 1)
                    }
                default:
                    out.append(b)
                }
            }
        }
    }
}

// MARK: - Serialising

extension JSONValue {
    /// Pretty-prints with two-space indentation, the style Claude Code and Codex write.
    public func serialized(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, level: 0, indent: indent)
        return out + "\n"
    }

    private func write(into out: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let closePad = String(repeating: " ", count: level * indent)
        switch self {
        case let .object(pairs):
            guard !pairs.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, pair) in pairs.enumerated() {
                out += pad + Self.quote(pair.key) + ": "
                pair.value.write(into: &out, level: level + 1, indent: indent)
                out += i < pairs.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "}"
        case let .array(items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, level: level + 1, indent: indent)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "]"
        case let .string(s): out += Self.quote(s)
        case let .number(n): out += n
        case let .bool(b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
