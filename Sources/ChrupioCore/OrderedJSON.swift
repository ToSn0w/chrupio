import Foundation

/// JSON that keeps the order of object keys and the spelling of numbers, so editing a user's Claude Code settings
/// changes only what Chrupio changes.
public indirect enum JSONValue: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
    }
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The number as written in the file.
    case number(String)
    case bool(Bool)
    case null
}

public enum OrderedJSON {
    public struct ParseError: Error {}

    /// Deeper nesting is refused, so a hostile file can't overflow the stack of the recursive parser.
    public static let maxDepth = 512

    // MARK: Parse

    /// Strict JSON in UTF-8 without a byte order mark. A key repeated in one object is refused: JSONSerialization
    /// keeps its first value and Claude Code its last, so no edit could be sure which one the user meant. Keys are
    /// compared by Unicode scalars, not with `String ==`: Claude Code keys `.claude.json`'s `projects` by folder path,
    /// and a composed and a decomposed spelling of the same name are two different keys to it.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError() }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func enter() throws {
            depth += 1
            guard depth <= OrderedJSON.maxDepth else { throw ParseError() }
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> JSONValue {
            skipSpace()
            guard index < bytes.count else { throw ParseError() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw ParseError() }
            index += expected.count
        }

        mutating func number() throws -> JSONValue {
            let start = index
            while index < bytes.count, "-+0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start else { throw ParseError() }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            // Validated by Foundation, so "1-2" or "." are rejected.
            guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) is NSNumber else { throw ParseError() }
            return .number(text)
        }

        /// A string token, decoded by Foundation (escapes, surrogate pairs).
        mutating func string() throws -> String {
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw ParseError() }
            index += 1
            guard let decoded = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String
            else { throw ParseError() }
            return decoded
        }

        mutating func object() throws -> JSONValue {
            try enter()
            defer { depth -= 1 }
            index += 1
            var members: [JSONValue.Member] = []
            var keys = Set<[Unicode.Scalar]>()
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError() }
                let key = try string()
                guard keys.insert(Array(key.unicodeScalars)).inserted else { throw ParseError() }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError() }
                index += 1
                members.append(.init(key: key, value: try value()))
                skipSpace()
                guard index < bytes.count else { throw ParseError() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw ParseError()
            }
        }

        mutating func array() throws -> JSONValue {
            try enter()
            defer { depth -= 1 }
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try value())
                skipSpace()
                guard index < bytes.count else { throw ParseError() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError()
            }
        }
    }

    // MARK: Merge

    /// `value` (from JSONSerialization or `foundationObject`) laid over `original`: keys keep their original place,
    /// new keys follow sorted, removed keys go, a number equal to the original keeps its spelling. Objects are read as
    /// NSDictionary, never bridged to `[String: Any]`, which would keep only one of two keys that differ only in
    /// Unicode normalization; keys are matched by Unicode scalars.
    public static func merge(_ value: Any, into original: JSONValue?) -> JSONValue {
        switch value {
        case let dictionary as NSDictionary:
            let old: [JSONValue.Member] = if case .object(let members) = original { members } else { [] }
            // `parse` refuses repeated keys; a value built by hand with one is written once, where it first appeared.
            var known = Set<[Unicode.Scalar]>()
            var members: [JSONValue.Member] = old.compactMap { member in
                guard known.insert(Array(member.key.unicodeScalars)).inserted else { return nil }
                return dictionary.object(forKey: member.key).map { .init(key: member.key, value: merge($0, into: member.value)) }
            }
            let added = dictionary.allKeys.compactMap { $0 as? String }.filter { !known.contains(Array($0.unicodeScalars)) }
            for key in added.sorted() {
                members.append(.init(key: key, value: merge(dictionary.object(forKey: key) ?? NSNull(), into: nil)))
            }
            return .object(members)
        case let array as [Any]:
            let old: [JSONValue] = if case .array(let items) = original { items } else { [] }
            return .array(array.enumerated().map { merge($1, into: $0 < old.count ? old[$0] : nil) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if case .number(let text) = original,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? NSNumber,
               parsed == number { return .number(text) }
            return .number(number.stringValue)
        default:
            return .null
        }
    }

    // MARK: Foundation

    /// The value as JSONSerialization would return it: NSDictionary, NSArray, String, NSNumber (booleans as CFBoolean),
    /// NSNull. Dictionaries keep every key exactly as parsed.
    public static func foundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .object(let members):
            let dictionary = NSMutableDictionary(capacity: members.count)
            for member in members { dictionary[member.key] = foundationObject(member.value) }
            return dictionary
        case .array(let items): return NSArray(array: items.map(foundationObject))
        case .string(let string): return string
        case .number(let text):
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? NSNumber ?? NSNumber(value: 0)
        case .bool(let bool): return NSNumber(value: bool)
        case .null: return NSNull()
        }
    }

    /// True when some object in `value` has two keys that are different strings to JSON but equal to Swift's `String ==`
    /// (the same text composed and decomposed). A `[String: Any]` made from that object keeps only one of them.
    public static func hasLookalikeKeys(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let members):
            return Set(members.map(\.key)).count != members.count || members.contains { hasLookalikeKeys($0.value) }
        case .array(let items):
            return items.contains(where: hasLookalikeKeys)
        default:
            return false
        }
    }

    // MARK: Serialize

    /// Two-space indents, `"key": value`, `{}` and `[]` when empty, a newline at the end.
    public static func serialize(_ value: JSONValue) -> String {
        var out = ""
        write(value, indent: 0, to: &out)
        return out + "\n"
    }

    private static func write(_ value: JSONValue, indent: Int, to out: inout String) {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch value {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += pad + quoted(member.key) + ": "
                write(member.value, indent: indent + 1, to: &out)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += pad
                write(item, indent: indent + 1, to: &out)
                out += offset == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .string(let string): out += quoted(string)
        case .number(let text): out += text
        case .bool(let bool): out += bool ? "true" : "false"
        case .null: out += "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
