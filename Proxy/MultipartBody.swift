import Foundation

/// Minimal `multipart/form-data` writer.
///
/// `/v1/audio/transcriptions` is the only endpoint in the OpenAI surface that takes a
/// multipart body rather than JSON, so this exists instead of a dependency for one request
/// shape. Parts are written in the order they are added.
struct MultipartBody {
    let boundary = "bigbro-\(UUID().uuidString)"
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, fileData: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        data.append(fileData)
        append("\r\n")
    }

    /// Writes the closing boundary and returns the body. Add no further parts afterwards.
    mutating func finalize() -> Data {
        append("--\(boundary)--\r\n")
        return data
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }

    /// Best-effort MIME type for an audio container, for the `file` part's Content-Type.
    /// Servers key off the filename extension too, so an unknown format still works.
    static func audioContentType(for format: String) -> String {
        switch format.lowercased() {
        case "wav":         return "audio/wav"
        case "mp3":         return "audio/mpeg"
        case "m4a", "mp4":  return "audio/mp4"
        case "flac":        return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm":        return "audio/webm"
        default:            return "application/octet-stream"
        }
    }
}
