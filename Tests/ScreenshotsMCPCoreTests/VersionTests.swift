import Foundation
import Testing

@testable import ScreenshotsMCPCore

/// The installer keys on the manifest version alone, so a build whose version strings
/// disagree describes a build nobody has. Reads this repository's own files only.
@Suite("Release metadata")
struct VersionTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        #expect(try manifest()["version"] as? String == ScreenshotsMCPServer.version)
        #expect(try plist()["CFBundleShortVersionString"] as? String == ScreenshotsMCPServer.version)
    }

    /// A tool missing from the manifest has no permission switch at all.
    @Test("The manifest lists exactly the tools the server offers")
    func manifestListsEveryTool() throws {
        let listed = try #require(try manifest()["tools"] as? [[String: Any]])
        let names = listed.compactMap { $0["name"] as? String }
        #expect(Set(names) == Set(ToolCatalog.all().map(\.name)))
        #expect(names.count == Set(names).count)
    }

    /// The manifest and the README are plain text and cannot take a figure from a
    /// constant, so this holds the figures they state to the ones the code enforces, and
    /// the names of the arguments to the schema.
    @Test("The manifest and the README state the figures and argument names the code enforces")
    func prosePointsAtTheCode() throws {
        let description = try #require(try manifest()["long_description"] as? String)
        #expect(description.contains("after \(Configuration.timeout.components.seconds) seconds"))
        #expect(description.contains("\(Configuration.maximumExtractIDs) screenshots"))
        let readme = try String(
            contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("\(Configuration.timeout.components.seconds) seconds"))
        let text = description + readme
        for tool in ToolCatalog.all() {
            for name in ToolCatalog.argumentNames(of: tool.name) {
                #expect(readme.contains("`\(name)`"), "\(tool.name).\(name) is not in the README")
            }
        }
        for old in ["`from`", "`to`"] { #expect(!text.contains(old), "\(old) is the old name") }
    }
}
