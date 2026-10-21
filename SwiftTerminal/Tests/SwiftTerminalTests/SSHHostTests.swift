import Foundation
import XCTest
@testable import SwiftTerminal

final class SSHHostTests: XCTestCase {
    func testLegacyHostFileWithoutGroupStillDecodes() throws {
        let legacy = Data(#"""
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"旧主机","address":"10.0.0.1","username":"root","port":2222,"authentication":"密码","password":"","privateKeyPath":"","savePassword":true}]
        """#.utf8)

        let hosts = try JSONDecoder().decode([SSHHost].self, from: legacy)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].displayName, "旧主机")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].authentication, .password)
        XCTAssertEqual(hosts[0].group, "")
    }

    func testHostRoundTripKeepsGroupAndEndpoint() throws {
        let host = SSHHost(name: "生产", address: "prod.example.com", username: "deploy", port: 2200, group: "生产环境")

        let decoded = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(host))

        XCTAssertEqual(decoded.group, "生产环境")
        XCTAssertEqual(decoded.endpoint, "deploy@prod.example.com:2200")
    }

    func testHostEditorPresentationRefreshesIdentityAndKeepsExistingHostData() {
        let host = SSHHost(
            name: "生产网关",
            address: "prod.example.com",
            username: "deploy",
            port: 2200,
            authentication: .privateKey,
            privateKeyPath: "~/.ssh/prod_ed25519",
            savePassword: false,
            group: "生产环境",
            remoteShell: "zsh"
        )

        let first = SSHHostEditorPresentation(host: host, isNewHost: false)
        let next = SSHHostEditorPresentation(host: host, isNewHost: false)

        XCTAssertNotEqual(first.id, next.id)
        XCTAssertEqual(first.host, host)
        XCTAssertFalse(first.isNewHost)
    }

    func testFilterMatchesNameAddressUserAndGroup() {
        let hosts = [
            SSHHost(name: "生产网关", address: "10.0.0.2", username: "deploy", group: "生产"),
            SSHHost(name: "测试机", address: "192.168.1.9", username: "tester", group: "测试")
        ]

        XCTAssertEqual(SSHHostGrouping.filter(hosts, query: "生产").map(\.name), ["生产网关"])
        XCTAssertEqual(SSHHostGrouping.filter(hosts, query: "tester").map(\.name), ["测试机"])
        XCTAssertEqual(SSHHostGrouping.filter(hosts, query: "192.168").map(\.name), ["测试机"])
        XCTAssertEqual(SSHHostGrouping.filter(hosts, query: "   ").count, 2)
        XCTAssertTrue(SSHHostGrouping.filter(hosts, query: "不存在").isEmpty)
    }

    func testGroupingListsNamedGroupsFirstAndUngroupedLast() {
        let hosts = [
            SSHHost(name: "b", address: "b", username: "u", group: "test"),
            SSHHost(name: "a", address: "a", username: "u", group: "prod"),
            SSHHost(name: "c", address: "c", username: "u"),
            SSHHost(name: "d", address: "d", username: "u", group: "   "),
            SSHHost(name: "b2", address: "b2", username: "u", group: "prod")
        ]

        let grouped = SSHHostGrouping.grouped(hosts)

        XCTAssertEqual(grouped.map(\.title), ["prod", "test", SSHHostGrouping.ungroupedTitle])
        XCTAssertEqual(grouped[0].hosts.map(\.name), ["a", "b2"])
        XCTAssertEqual(grouped[1].hosts.map(\.name), ["b"])
        XCTAssertEqual(grouped[2].hosts.map(\.name), ["c", "d"])
        XCTAssertEqual(SSHHostGrouping.knownGroups(hosts), ["prod", "test"])
    }
}
