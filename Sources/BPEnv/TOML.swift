import Foundation

/// Values of the small TOML subset `.bullpen.toml` uses.
public enum TOMLValue: Equatable, Sendable {
    case string(String), int(Int), bool(Bool), array([TOMLValue]), table([String: TOMLValue])

    public var string: String? { if case let .string(s) = self { s } else { nil } }
    public var strings: [String]? {
        guard case let .array(items) = self else { return string.map { [$0] } }
        return items.compactMap(\.string)
    }
    public var table: [String: TOMLValue]? { if case let .table(t) = self { t } else { nil } }
    public subscript(_ key: String) -> TOMLValue? { table?[key] }
}

public struct TOMLError: Error, LocalizedError, Equatable {
    public var line: Int
    public var message: String
    public var errorDescription: String? { "Línea \(line): \(message)" }

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// Parses the TOML subset needed for Bullpen's config: `[tables]` and `[a.b]` headers,
/// `key = value` with basic/literal strings, multi-line `"""` / `'''` strings, integers,
/// booleans, single- or multi-line arrays, and `#` comments. No dates, inline tables or
/// arrays of tables: those are reported as errors instead of being misread.
public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var path: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let lineNumber = i + 1
            var line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[[") {
                throw TOMLError(line: lineNumber, message: "las listas de tablas ([[…]]) no están soportadas")
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw TOMLError(line: lineNumber, message: "cabecera de tabla sin cerrar") }
                path = line.dropFirst().dropLast().split(separator: ".").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                try ensureTable(&root, path, line: lineNumber)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw TOMLError(line: lineNumber, message: "se esperaba clave = valor") }
            let key = unquote(line[..<eq].trimmingCharacters(in: .whitespaces))
            var raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            // Multi-line strings and arrays may continue on the following lines.
            for delimiter in ["\"\"\"", "'''"] where raw.hasPrefix(delimiter) {
                var body = String(raw.dropFirst(3))
                while !body.contains(delimiter) {
                    guard i < lines.count else { throw TOMLError(line: lineNumber, message: "cadena multilínea sin cerrar") }
                    body += "\n" + lines[i]
                    i += 1
                }
                raw = delimiter + body
            }
            if raw.hasPrefix("[") {
                while !balanced(raw) {
                    guard i < lines.count else { throw TOMLError(line: lineNumber, message: "lista sin cerrar") }
                    raw += " " + stripComment(lines[i])
                    i += 1
                }
            }
            line = raw
            let value = try parseValue(raw, line: lineNumber)
            try set(&root, path + key.split(separator: ".").map(String.init), value, line: lineNumber)
        }
        return root
    }

    static func parseValue(_ raw: String, line: Int) throws -> TOMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"\"\"") || s.hasPrefix("'''") {
            let d = String(s.prefix(3))
            guard let end = s.dropFirst(3).range(of: d) else { throw TOMLError(line: line, message: "cadena multilínea sin cerrar") }
            var body = String(s[s.index(s.startIndex, offsetBy: 3)..<end.lowerBound])
            if body.hasPrefix("\n") { body.removeFirst() }   // a newline right after the opening is trimmed
            return .string(d == "\"\"\"" ? unescape(body) : body)
        }
        if s.hasPrefix("\"") {
            guard s.count >= 2, s.hasSuffix("\"") else { throw TOMLError(line: line, message: "cadena sin cerrar") }
            return .string(unescape(String(s.dropFirst().dropLast())))
        }
        if s.hasPrefix("'") {
            guard s.count >= 2, s.hasSuffix("'") else { throw TOMLError(line: line, message: "cadena sin cerrar") }
            return .string(String(s.dropFirst().dropLast()))
        }
        if s.hasPrefix("[") {
            return .array(try splitArray(String(s.dropFirst().dropLast()), line: line).map { try parseValue($0, line: line) })
        }
        if s.hasPrefix("{") { throw TOMLError(line: line, message: "las tablas en línea ({…}) no están soportadas") }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let n = Int(s.replacingOccurrences(of: "_", with: "")) { return .int(n) }
        throw TOMLError(line: line, message: "valor no válido: \(s)")
    }

    /// Splits array items on top-level commas (ignoring commas inside strings or nested arrays).
    static func splitArray(_ body: String, line: Int) throws -> [String] {
        var items: [String] = [], current = "", depth = 0
        var quote: Character?
        var escaped = false
        for ch in body {
            if let q = quote {
                current.append(ch)
                if escaped { escaped = false } else if ch == "\\" && q == "\"" { escaped = true } else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; current.append(ch)
            case "[": depth += 1; current.append(ch)
            case "]": depth -= 1; current.append(ch)
            case "," where depth == 0:
                items.append(current); current = ""
            default: current.append(ch)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func balanced(_ s: String) -> Bool {
        var depth = 0
        var quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch } else if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 }
        }
        return depth == 0
    }

    static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (offset, ch) in line.enumerated() {
            if let q = quote { if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch } else if ch == "#" { return String(line.prefix(offset)) }
        }
        return line
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    static func unescape(_ s: String) -> String {
        var out = "", escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func ensureTable(_ root: inout [String: TOMLValue], _ path: [String], line: Int) throws {
        guard let first = path.first else { return }
        var child = root[first]?.table ?? [:]
        if root[first] != nil, root[first]?.table == nil { throw TOMLError(line: line, message: "\(first) ya es un valor, no una tabla") }
        try ensureTable(&child, Array(path.dropFirst()), line: line)
        root[first] = .table(child)
    }

    static func set(_ root: inout [String: TOMLValue], _ path: [String], _ value: TOMLValue, line: Int) throws {
        guard let first = path.first else { return }
        if path.count == 1 {
            if root[first] != nil { throw TOMLError(line: line, message: "clave repetida: \(first)") }
            root[first] = value
            return
        }
        var child = root[first]?.table ?? [:]
        try set(&child, Array(path.dropFirst()), value, line: line)
        root[first] = .table(child)
    }
}
