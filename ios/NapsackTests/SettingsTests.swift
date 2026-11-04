import Foundation
import Testing
@testable import Napsack

/// Profile › Settings' own rules.
@Suite struct SettingsTests {
    /// The privacy policy and support pages are on the site the server names,
    /// and there are none where it names none (a local server).
    @Test func privacyAndSupportAreOnTheServersSite() throws {
        let links = try #require(SiteLinks(siteUrl: "https://napsack.io"))
        #expect(links.privacy.absoluteString == "https://napsack.io/privacy" && links.support.absoluteString == "https://napsack.io/support")
        #expect(SiteLinks(siteUrl: "https://staging.napsack.io/")?.privacy.absoluteString == "https://staging.napsack.io/privacy")
        #expect(SiteLinks(siteUrl: nil) == nil)
        #expect(SiteLinks(siteUrl: "") == nil)
        #expect(SiteLinks(siteUrl: "http://127.0.0.1:8080") == nil)  // only a real site, over https
    }

    @Test func signingOutSaysWhatItMeans() {
        // Short, and names every way back in.
        #expect(["password", "passkey", "recovery key"].allSatisfy(SettingsScreen.signOutWords.contains))
    }
}
