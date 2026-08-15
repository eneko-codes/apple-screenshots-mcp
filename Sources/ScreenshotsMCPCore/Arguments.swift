import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// Small on purpose: this server has three read-only tools, so the only shapes it ever
/// decodes are an optional date, a clamped integer and a list of ids.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Absent, empty and `null` all mean "no bound on this side of the range".
    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "a date string was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try DateParsing.parse(trimmed, argument: name, calendar: calendar)
    }
}
