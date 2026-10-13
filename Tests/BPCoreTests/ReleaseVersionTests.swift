import BPCore
import Testing

@Suite struct ReleaseVersionTests {
    @Test func comparesNumberByNumber() throws {
        let v016 = try #require(ReleaseVersion("v0.1.6"))
        #expect(try #require(ReleaseVersion("0.1.7")) > v016)
        #expect(try #require(ReleaseVersion("0.1.10")) > (try #require(ReleaseVersion("0.1.9"))))
        #expect(try #require(ReleaseVersion("0.2")) > v016)
        #expect(try #require(ReleaseVersion("0.1.6")) == v016)
        #expect(ReleaseVersion("latest") == nil)
        #expect(v016.description == "0.1.6")
    }

    @Test func findsTheHashOfAFile() {
        let sums = "abc123  Bullpen-0.1.7-universal.zip\nffff  other.zip\n"
        #expect(ReleaseVersion.sha256(for: "Bullpen-0.1.7-universal.zip", in: sums) == "abc123")
        #expect(ReleaseVersion.sha256(for: "missing.zip", in: sums) == nil)
    }
}
