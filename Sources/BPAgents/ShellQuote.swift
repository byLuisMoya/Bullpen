/// POSIX single-quoting: `it's` → `'it'\''s'`. Safe for any string, including newlines.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
