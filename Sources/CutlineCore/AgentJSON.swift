import Foundation

/// A JSON value for the agent protocol, where tool arguments and results have open shapes.
public enum JSON: Codable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Request identifiers and counts stay integers on the wire.
            if value.rounded() == value, abs(value) < 9e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSON? { if case .object(let value) = self { return value[key] }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [JSON]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: JSON]? { if case .object(let value) = self { return value }; return nil }
    public var isNull: Bool { self == .null }

    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
    /// One line, as the stdio transport requires.
    public func encoded() -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
    public var text: String { String(decoding: encoded(), as: UTF8.self) }
    /// Readable JSON for tool results that agents and people both read.
    public var prettyText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
