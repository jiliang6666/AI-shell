import Foundation
import Testing
@testable import SwiftTerminal

struct UpdateReleasePolicyTests {
    @Test("Update feed accepts only the public GitHub latest-release appcast path")
    func updateFeedAllowlist() {
        let expected = URL(string: "https://github.com/jiliang6666/AI-shell/releases/latest/download/appcast.xml")
        #expect(UpdateReleasePolicy.publicGitHubFeedURL(expected!.absoluteString) == expected)

        let rejected = [
            "http://github.com/jiliang6666/AI-shell/releases/latest/download/appcast.xml",
            "https://github.com.evil.example/jiliang6666/AI-shell/releases/latest/download/appcast.xml",
            "https://user@github.com/jiliang6666/AI-shell/releases/latest/download/appcast.xml",
            "https://github.com:8443/jiliang6666/AI-shell/releases/latest/download/appcast.xml",
            "https://github.com/jiliang6666/AI-shell/releases/latest/download/appcast.xml?next=example",
            "https://github.com/jiliang6666/AI-shell/releases/latest/download/appcast.xml#fragment",
            "https://github.com/jiliang6666/AI-shell/releases/download/v1.0.0/appcast.xml",
            "https://github.com/jiliang6666/../AI-shell/releases/latest/download/appcast.xml",
            "not a URL"
        ]
        for value in rejected {
            #expect(UpdateReleasePolicy.publicGitHubFeedURL(value) == nil, "Unexpectedly allowed \(value)")
        }
    }

    @Test("Update comparison uses the greatest numeric revision newer than this build")
    func newestNumericRevision() {
        #expect(UpdateReleasePolicy.newestVersionIndex(["99", "100", "112", "111"], newerThan: 100) == 2)
        #expect(UpdateReleasePolicy.newestVersionIndex(["100", "1.0.1", "bad"], newerThan: 100) == nil)
        #expect(UpdateReleasePolicy.newestVersionIndex([], newerThan: 100) == nil)
    }

    @MainActor
    @Test("Updater requires an HTTPS GitHub feed, a 32-byte key, and a positive revision")
    func updaterConfigurationValidation() {
        let validFeed = "https://github.com/jiliang6666/AI-shell/releases/latest/download/appcast.xml"
        let publicKey = "Fd2DQDZ/nrE3xmzNRzxaITrFvy4L4cfnFf5Y/pCTY44="
        func configured(_ feed: String, key: String, revision: String) -> Bool {
            UpdateController(
                info: [
                    "SUFeedURL": feed,
                    "SUPublicEDKey": key,
                    "ZhanqiaoUpdateRevision": revision
                ],
                startingUpdater: false
            ).isConfigured
        }

        #expect(configured(validFeed, key: publicKey, revision: "100"))
        #expect(!configured("", key: publicKey, revision: "100"))
        #expect(!configured(validFeed, key: "invalid", revision: "100"))
        #expect(!configured(validFeed, key: publicKey, revision: "0"))
        #expect(!configured(validFeed, key: publicKey, revision: "1.0.0"))
    }
}
