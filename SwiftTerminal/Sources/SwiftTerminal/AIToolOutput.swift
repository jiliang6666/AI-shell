import Foundation

struct AIToolOutputCapture: Equatable, Sendable {
    var text: String
    var capturedBytes: Int64
    var omittedBytes: Int64
}

enum AIToolOutputLimiter {
    static let captureLimitBytes = 1_048_576
    static let modelProjectionLimitScalars = 24_000
    private static let projectionMarker = "\n…（中间输出已省略）…\n"

    /// Counts the full UTF-8 size while retaining only a valid Unicode prefix.
    static func capture(_ text: String, limitBytes: Int = captureLimitBytes) -> AIToolOutputCapture {
        capture(lines: CollectionOfOne(text), limitBytes: limitBytes, separator: "")
    }

    static func capture<S: Sequence>(
        lines: S,
        limitBytes: Int = captureLimitBytes,
        separator: String = "\n"
    ) -> AIToolOutputCapture where S.Element == String {
        var captured = String.UnicodeScalarView()
        var capturedBytes = 0
        var totalBytes = 0
        var full = true
        var isFirst = true

        func consume(_ value: String) {
            for scalar in value.unicodeScalars {
                let size = scalar.utf8.count
                totalBytes += size
                if full, capturedBytes + size <= max(0, limitBytes) {
                    captured.append(scalar)
                    capturedBytes += size
                } else {
                    full = false
                }
            }
        }

        for line in lines {
            if isFirst {
                isFirst = false
            } else {
                consume(separator)
            }
            consume(line)
        }
        return AIToolOutputCapture(
            text: String(captured),
            capturedBytes: Int64(capturedBytes),
            omittedBytes: Int64(totalBytes - capturedBytes)
        )
    }

    /// Keeps the start and end of captured tool output for model context.
    static func modelProjection(_ text: String, limitScalars: Int = modelProjectionLimitScalars) -> String {
        let scalars = Array(text.unicodeScalars)
        let limit = max(0, limitScalars)
        guard scalars.count > limit else { return text }
        guard limit > projectionMarker.unicodeScalars.count else {
            return String(String.UnicodeScalarView(scalars.prefix(limit)))
        }
        let available = limit - projectionMarker.unicodeScalars.count
        let headCount = available / 2
        let tailCount = available - headCount
        let head = String(String.UnicodeScalarView(scalars.prefix(headCount)))
        let tail = String(String.UnicodeScalarView(scalars.suffix(tailCount)))
        return head + projectionMarker + tail
    }
}
