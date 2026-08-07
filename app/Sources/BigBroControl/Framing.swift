import Foundation

/// The wire codec: a 4-byte big-endian length prefix followed by a UTF-8 JSON object.
///
/// Port of `src/bigbro/protocol/framing.py`. The constants are not arbitrary and
/// must not drift from it — a client that disagrees about the prefix width reads a
/// length out of somebody's message body.
public enum Framing {
    public static let lengthPrefixBytes = 4

    /// A frame this large is a desync or a hostile peer, not a real message.
    public static let maxFrameBytes = 32 * 1024 * 1024

    public static func frame(_ body: Data) -> Data {
        var out = Data(capacity: lengthPrefixBytes + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Reads the big-endian length out of a 4-byte prefix, rejecting absurd ones.
    public static func bodyLength(of prefix: Data) throws -> Int {
        guard prefix.count == lengthPrefixBytes else {
            throw ControlError.malformedFrame(
                "length prefix was \(prefix.count) bytes, expected \(lengthPrefixBytes)"
            )
        }
        let length = Int(prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= maxFrameBytes else {
            throw ControlError.malformedFrame(
                "frame of \(length) bytes exceeds the \(maxFrameBytes) byte limit"
            )
        }
        return length
    }
}
