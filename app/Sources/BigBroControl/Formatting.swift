import Foundation

public enum Formatting {
    /// Bytes as a short human figure. `nil` becomes "?" rather than "0 B".
    ///
    /// A deliberate port of `human()` in `src/bigbro/macos/memory.py`, not a call
    /// to `ByteCountFormatter`. The system formatter defaults to decimal units, so
    /// it would render the same integer differently from `bigbro status` — and the
    /// app and the CLI disagreeing about how much memory a model is holding is
    /// exactly the drift that keeping formatting in one place is meant to prevent.
    /// `tests/test_memory.py::test_human` and `FormattingTests` assert the same
    /// table on both sides.
    public static func human(_ size: Int?) -> String {
        guard let size else { return "?" }
        var value = Double(size)
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if value < 1024 || unit == "TB" {
                // "0 B" and "512 B" read better whole; anything larger has been
                // divided down and wants the decimal place back.
                let places = (unit == "B" || unit == "KB") ? 0 : 1
                return String(format: "%.\(places)f", value) + " " + unit
            }
            value /= 1024
        }
        return String(format: "%.1f TB", value)
    }
}
