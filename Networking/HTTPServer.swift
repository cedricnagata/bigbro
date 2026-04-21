import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let statusCode: Int
    let body: Data
    let contentType: String

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(statusCode: status, body: data, contentType: "application/json")
    }

    static let notFound = HTTPResponse(statusCode: 404, body: Data("{\"error\":\"not found\"}".utf8), contentType: "application/json")
    static let unauthorized = HTTPResponse(statusCode: 401, body: Data("{\"error\":\"unauthorized\"}".utf8), contentType: "application/json")
    static let badRequest = HTTPResponse(statusCode: 400, body: Data("{\"error\":\"bad request\"}".utf8), contentType: "application/json")
}

protocol HTTPServerDelegate: AnyObject {
    func server(_ server: HTTPServer, didReceive request: HTTPRequest) async -> HTTPResponse
}

actor HTTPServer {
    let port: UInt16
    private var listener: NWListener?
    weak var delegate: HTTPServerDelegate?

    init(port: UInt16 = 8765) {
        self.port = port
    }

    func setDelegate(_ delegate: HTTPServerDelegate) {
        self.delegate = delegate
    }

    func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        listener?.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                print("[HTTPServer] Failed: \(error)")
            case .ready:
                print("[HTTPServer] Listening on port \(self.port)")
            default:
                break
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))

        guard let rawData = await receive(connection: connection),
              let request = parseHTTP(rawData) else {
            connection.cancel()
            return
        }

        let response: HTTPResponse
        if let delegate {
            response = await delegate.server(self, didReceive: request)
        } else {
            response = .notFound
        }

        await send(response, on: connection)
        connection.cancel()
    }

    private func receive(connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            receiveChunk(connection: connection, buffer: Data(), continuation: continuation)
        }
    }

    private nonisolated func receiveChunk(connection: NWConnection, buffer: Data, continuation: CheckedContinuation<Data?, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
            var mutableBuffer = buffer
            if let content { mutableBuffer.append(content) }
            if isComplete || error != nil {
                continuation.resume(returning: mutableBuffer.isEmpty ? nil : mutableBuffer)
                return
            }
            // Check if we have a complete HTTP request (headers + body)
            if let headerEnd = mutableBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = mutableBuffer[mutableBuffer.startIndex..<headerEnd.upperBound]
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = Self.parseContentLength(from: headerString)
                let bodyStart = headerEnd.upperBound
                let bodyReceived = mutableBuffer.count - bodyStart
                if bodyReceived >= contentLength {
                    continuation.resume(returning: mutableBuffer)
                    return
                }
            }
            self.receiveChunk(connection: connection, buffer: mutableBuffer, continuation: continuation)
        }
    }

    private static func parseContentLength(from headers: String) -> Int {
        let lines = headers.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        let bodyData = data[headerEnd.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let rawPath = parts[1]

        var path = rawPath
        var queryItems: [String: String] = [:]
        if let qIdx = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<qIdx])
            let queryString = String(rawPath[rawPath.index(after: qIdx)...])
            for pair in queryString.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    let key = kv[0].removingPercentEncoding ?? kv[0]
                    let value = kv[1].removingPercentEncoding ?? kv[1]
                    queryItems[key] = value
                }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let body: Data? = bodyData.isEmpty ? nil : Data(bodyData)
        return HTTPRequest(method: method, path: path, queryItems: queryItems, headers: headers, body: body)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) async {
        let statusText: String
        switch response.statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }

        var raw = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        raw += "Content-Type: \(response.contentType)\r\n"
        raw += "Content-Length: \(response.body.count)\r\n"
        raw += "Connection: close\r\n"
        raw += "\r\n"

        var responseData = Data(raw.utf8)
        responseData.append(response.body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: responseData, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
