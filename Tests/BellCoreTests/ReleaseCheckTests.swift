import Foundation
import Testing
@testable import BellCore

struct ReleaseCheckTests {
    @Test func readsTagAndPageFromGitHub() throws {
        let json = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/lance2016/AgentBell/releases/tag/v0.2.0",
         "name": "0.2.0", "draft": false, "prerelease": false}
        """
        let release = try #require(ReleaseCheck.decode(Data(json.utf8)))
        #expect(release.version == "0.2.0")
        #expect(release.page.absoluteString == "https://github.com/lance2016/AgentBell/releases/tag/v0.2.0")
    }

    @Test func tagWithoutPrefixIsKept() throws {
        let json = #"{"tag_name": "1.0", "html_url": "https://example.com/r"}"#
        #expect(try #require(ReleaseCheck.decode(Data(json.utf8))).version == "1.0")
    }

    @Test func brokenResponseGivesNothing() {
        #expect(ReleaseCheck.decode(Data("not json".utf8)) == nil)
        #expect(ReleaseCheck.decode(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
    }

    @Test func findsTheSignedArchiveAmongAssets() throws {
        let json = """
        {"tag_name": "v1.2.1", "html_url": "https://github.com/lance2016/AgentBell/releases/tag/v1.2.1",
         "assets": [
           {"name": "AgentBell-1.2.1-macOS-AppleSilicon.dmg", "browser_download_url": "https://example.com/a.dmg"},
           {"name": "AgentBell-1.2.1-macOS-AppleSilicon.zip.sig", "browser_download_url": "https://example.com/a.zip.sig"},
           {"name": "AgentBell-1.2.1-macOS-AppleSilicon.zip", "browser_download_url": "https://example.com/a.zip"}
         ]}
        """
        let release = try #require(ReleaseCheck.decode(Data(json.utf8)))
        #expect(release.archive?.absoluteString == "https://example.com/a.zip")
        #expect(release.signature?.absoluteString == "https://example.com/a.zip.sig")
    }

    @Test func archiveWithoutSignatureCannotBeInstalled() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://example.com/r",
         "assets": [{"name": "AgentBell-1.2.0-macOS-AppleSilicon.dmg", "browser_download_url": "https://example.com/a.dmg"},
                    {"name": "AgentBell-1.2.0-macOS-AppleSilicon.zip", "browser_download_url": "https://example.com/a.zip"}]}
        """
        let release = try #require(ReleaseCheck.decode(Data(json.utf8)))
        #expect(release.archive == nil)
        #expect(release.signature == nil)
    }

    @Test func comparesVersionsByNumber() {
        #expect(ReleaseCheck.isNewer("0.2.0", than: "0.1.0"))
        #expect(ReleaseCheck.isNewer("0.10.0", than: "0.9.3"))
        #expect(ReleaseCheck.isNewer("1.0.1", than: "1.0"))
        #expect(!ReleaseCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!ReleaseCheck.isNewer("1.0", than: "1.0.0"))
        #expect(!ReleaseCheck.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func ignoresPrefixAndSuffix() {
        #expect(ReleaseCheck.isNewer("v0.2.0", than: "0.1.0"))
        #expect(!ReleaseCheck.isNewer("0.1.0-beta", than: "0.1.0"))
    }
}
