import Foundation

/// Failures talking to the daemon over its control socket.
///
/// The wording of `noDaemon` and `pathTooLong` is copied from `control.py` rather
/// than reinvented: both are messages a user reads, both already say the useful
/// thing, and two clients giving different advice for the same condition is worse
/// than either wording.
public enum ControlError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening — either the socket is absent or the daemon died holding it.
    case noDaemon(path: String)

    /// `sun_path` is 104 bytes on Darwin. Only reachable via a deep `BIGBRO_HOME`,
    /// which is exactly when the cause is least obvious.
    case pathTooLong(bytes: Int, path: String)

    /// The daemon answered, and said no.
    case daemon(String)

    case closedWithoutReplying
    case malformedFrame(String)
    case posix(code: Int32, operation: String)

    public var description: String {
        switch self {
        case .noDaemon(let path):
            return "No running daemon found at \(path). Start one with: bigbro serve"
        case .pathTooLong(let bytes, let path):
            return """
                Control socket path is \(bytes) bytes, over the \
                \(ControlSocket.maxPathBytes)-byte limit for Unix sockets: \(path). \
                Set BIGBRO_HOME to a shorter directory.
                """
        case .daemon(let message):
            return message
        case .closedWithoutReplying:
            return "The daemon closed the connection without replying."
        case .malformedFrame(let detail):
            return "Malformed frame: \(detail)"
        case .posix(let code, let operation):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}
