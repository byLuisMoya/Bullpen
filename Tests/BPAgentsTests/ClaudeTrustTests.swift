import BPAgents
import Foundation
import Testing

@Suite struct ClaudeTrustTests {
    func makeConfig(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func trustsAndForgetsWithoutTouchingOtherData() throws {
        let url = try makeConfig("""
        {"numStartups": 42, "userID": "abc", "projects": {"/other": {"hasTrustDialogAccepted": true, "lastCost": 1.5}}}
        """)
        let trust = ClaudeTrust(configURL: url)
        #expect(try trust.trust("/tmp/wt/a") == .updated)
        #expect(trust.isTrusted("/tmp/wt/a"))
        #expect(try trust.trust("/tmp/wt/a") == .alreadyDone)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["numStartups"] as? Int == 42)
        #expect(root["userID"] as? String == "abc")
        #expect(((root["projects"] as? [String: Any])?["/other"] as? [String: Any])?["lastCost"] as? Double == 1.5)

        #expect(try trust.forget("/tmp/wt/a") == .updated)
        #expect(!trust.isTrusted("/tmp/wt/a"))
        #expect(try trust.forget("/tmp/wt/a") == .alreadyDone)
    }

    @Test func keepsExistingProjectEntryFields() throws {
        let url = try makeConfig(#"{"projects": {"/tmp/wt/b": {"allowedTools": ["Bash"], "hasTrustDialogAccepted": false}}}"#)
        try ClaudeTrust(configURL: url).trust("/tmp/wt/b")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try #require((root["projects"] as? [String: Any])?["/tmp/wt/b"] as? [String: Any])
        #expect(entry["allowedTools"] as? [String] == ["Bash"])
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test func missingConfigMeansClaudeNeverRan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        #expect(try ClaudeTrust(configURL: url).trust("/x") == .noClaudeConfig)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
