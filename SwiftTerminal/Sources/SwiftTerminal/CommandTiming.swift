import Foundation

enum CommandTimingFormatter {
    /// Formats an elapsed command duration for compact UI labels.
    /// Nil and non-finite values are treated as unavailable instead of zero.
    static func elapsed(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 59.95 {
            return String(
                format: "%.1f 秒",
                locale: Locale(identifier: "en_US_POSIX"),
                seconds
            )
        }

        guard let total = Int(exactly: seconds.rounded()) else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d 小时 %02d 分 %02d 秒", hours, minutes, remainingSeconds)
        }
        return String(format: "%d 分 %02d 秒", minutes, remainingSeconds)
    }
}
