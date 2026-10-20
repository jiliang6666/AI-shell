import Foundation
import XCTest
@testable import SwiftTerminal

final class AppPreferencesTests: XCTestCase {
    func testLegacyPreferencesGetHistoryRetentionDefault() throws {
        let legacy = Data(#"{"appearance":"dark","terminalFontSize":16,"assistantFontSize":15,"defaultPermissionMode":"修改前确认","language":"简体中文","workingDirectory":"/tmp"}"#.utf8)

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: legacy)

        XCTAssertEqual(preferences.appearance, "dark")
        XCTAssertEqual(preferences.terminalFontSize, 16)
        XCTAssertEqual(preferences.workingDirectory, "/tmp")
        XCTAssertEqual(preferences.historyRetentionDays, 90)
    }

    func testHistoryRetentionPreferenceRoundTrips() throws {
        var preferences = AppPreferences()
        preferences.historyRetentionDays = 30

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))

        XCTAssertEqual(decoded.historyRetentionDays, 30)
        XCTAssertEqual(decoded.assistantFontSize, preferences.assistantFontSize)
    }

    func testAIReadinessTimeoutDefaultsForLegacyPreferences() throws {
        let legacy = Data(#"{"appearance":"dark","historyRetentionDays":30}"#.utf8)

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: legacy)

        XCTAssertEqual(preferences.aiReadinessTimeoutSeconds, AIReadinessTimeout.defaultSeconds)
    }

    func testAIReadinessTimeoutRoundTripsAndClampsOutOfRangeValues() throws {
        var preferences = AppPreferences()
        preferences.aiReadinessTimeoutSeconds = 120

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))

        XCTAssertEqual(decoded.aiReadinessTimeoutSeconds, 120)

        let tooSmall = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"aiReadinessTimeoutSeconds":0}"#.utf8))
        XCTAssertEqual(tooSmall.aiReadinessTimeoutSeconds, AIReadinessTimeout.range.lowerBound)

        let tooLarge = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"aiReadinessTimeoutSeconds":100000}"#.utf8))
        XCTAssertEqual(tooLarge.aiReadinessTimeoutSeconds, AIReadinessTimeout.range.upperBound)
    }

    func testHistoryRetentionExpiresOldEntriesAndKeepsNewestFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dates = [
            now.addingTimeInterval(-10 * 86_400),
            now.addingTimeInterval(-2 * 86_400),
            now.addingTimeInterval(-86_400)
        ]

        let retained = HistoryRetentionPolicy.apply(to: dates, days: 7, now: now, date: \.self)

        XCTAssertEqual(retained, Array(dates.suffix(2).reversed()))
    }

    func testHistoryRetentionCanKeepAllAgesButStillCapsRecordCount() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dates = (0..<305).map { now.addingTimeInterval(-Double($0) * 86_400) }

        let retained = HistoryRetentionPolicy.apply(to: dates, days: 0, now: now, date: \.self)

        XCTAssertEqual(retained.count, 300)
        XCTAssertEqual(retained.first, dates.first)
        XCTAssertEqual(retained.last, dates[299])
    }
}
