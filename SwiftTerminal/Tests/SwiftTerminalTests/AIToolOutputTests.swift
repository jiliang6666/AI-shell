import Testing
@testable import SwiftTerminal

@Test("Tool output capture caps raw bytes and counts omitted bytes")
func toolOutputCaptureTracksByteLimit() {
    let output = AIToolOutputLimiter.capture(String(repeating: "x", count: 1_048_600))
    #expect(output.text.utf8.count == AIToolOutputLimiter.captureLimitBytes)
    #expect(output.capturedBytes == 1_048_576)
    #expect(output.omittedBytes == 24)
}

@Test("Tool output capture and model projection preserve Unicode scalar boundaries")
func toolOutputLimitsPreserveUnicodeScalars() {
    let capture = AIToolOutputLimiter.capture("a你好b", limitBytes: 4)
    #expect(capture.text == "a你")
    #expect(capture.capturedBytes == 4)
    #expect(capture.omittedBytes == 4)

    let long = String(repeating: "前", count: 12_100) + "middle" + String(repeating: "后", count: 12_100)
    let projection = AIToolOutputLimiter.modelProjection(long)
    #expect(projection.unicodeScalars.count <= AIToolOutputLimiter.modelProjectionLimitScalars)
    #expect(projection.contains("中间输出已省略"))
    #expect(projection.hasPrefix(String(repeating: "前", count: 100)))
    #expect(projection.hasSuffix(String(repeating: "后", count: 100)))
}
