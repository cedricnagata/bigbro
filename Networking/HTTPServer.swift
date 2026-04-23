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
    let sseStream: AsyncThrowingStream<String, Error>?
    let onStreamOpened: (@Sendable () -> Void)?
    let onStreamClosed: (@Sendable () -> Void)?

    nonisolated init(statusCode: Int, body: Data, contentType: String) {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
        self.sseStream = nil
        self.onStreamOpened = nil
        self.onStreamClosed = nil
    }

    private init(sseStream: AsyncThrowingStream<String, Error>,
                 onOpen: (@Sendable () -> Void)? = nil,
                 onClose: (@Sendable () -> Void)? = nil) {
        self.statusCode = 200
        self.body = Data()
        self.contentType = "text/event-stream"
        self.sseStream = sseStream
        self.onStreamOpened = onOpen
        self.onStreamClosed = onClose
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(statusCode: status, body: data, contentType: "application/json")
    }

    static func sse(_ stream: AsyncThrowingStream<String, Error>) -> HTTPResponse {
        HTTPResponse(sseStream: stream)
    }

    /// Long-lived SSE stream used for client presence detection. Sends a keepalive
    /// every 30s; exits only when the client disconnects (or server cancels).
    /// `onOpen` fires once the HTTP headers are sent; `onClose` fires when the
    /// stream ends for any reason.
    /// Returns the response plus two closures:
    /// - `cancel` ends the stream immediately (for explicit disconnect/remove).
    /// - `poke` yields an immediate ping. If the underlying TCP write fails,
    ///   `sendSSE` tears down the stream and fires `onClose`; if it succeeds,
    ///   the client is verified alive and nothing changes. Used by Refresh.
    static func presence(onOpen: @escaping @Sendable () -> Void,
                         onClose: @escaping @Sendable () -> Void)
    -> (HTTPResponse, cancel: @Sendable () -> Void, poke: @Sendable () -> Void) {
        let holder = ContinuationHolder()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            holder.continuation = continuation
            let task = Task {
                // Flush an immediate event so URLSession.bytes() returns the
                // 200 response to the client without waiting for the first ping.
                continuation.yield("hello")
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if Task.isCancelled { break }
                    continuation.yield("ping")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        let response = HTTPResponse(sseStream: stream, onOpen: onOpen, onClose: onClose)
        let cancel: @Sendable () -> Void = { holder.continuation?.finish() }
        let poke: @Sendable () -> Void = { holder.continuation?.yield("ping") }
        return (response, cancel, poke)
    }

    nonisolated static var notFound: HTTPResponse { HTTPResponse(statusCode: 404, body: Data("{\"error\":\"not found\"}".utf8), contentType: "application/json") }
    nonisolated static var unauthorized: HTTPResponse { HTTPResponse(statusCode: 401, body: Data("{\"error\":\"unauthorized\"}".utf8), contentType: "application/json") }
    nonisolated static var badRequest: HTTPResponse { HTTPResponse(statusCode: 400, body: Data("{\"error\":\"bad request\"}".utf8), contentType: "application/json") }
}

private final class ContinuationHolder: @unchecked Sendable {
    nonisolated(unsafe) var continuation: AsyncThrowingStream<String, Error>.Continuation?
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
        print("[HTTPServer] New connection from \(connection.endpoint)")

        guard let rawData = await receive(connection: connection) else {
            print("[HTTPServer] Receive returned nil data")
            connection.cancel()
            return
        }
        guard let request = parseHTTP(rawData) else {
            print("[HTTPServer] Failed to parse HTTP from \(rawData.count) bytes: \(String(data: rawData.prefix(200), encoding: .utf8) ?? "<binary>")")
            connection.cancel()
            return
        }

        print("[HTTPServer] \(request.method) \(request.path) body=\(request.body?.count ?? 0)b")

        let response: HTTPResponse
        if let delegate {
            response = await delegate.server(self, didReceive: request)
        } else {
            response = .notFound
        }

        if response.sseStream != nil {
            print("[HTTPServer] -> SSE stream")
            await sendSSE(response, on: connection)
        } else {
            print("[HTTPServer] -> \(response.statusCode) body=\(String(data: response.body, encoding: .utf8) ?? "<binary>")")
            await send(response, on: connection)
        }
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

    private func sendSSE(_ response: HTTPResponse, on connection: NWConnection) async {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        if await sendRaw(Data(headers.utf8), on: connection) != nil { return }
        response.onStreamOpened?()
        defer { response.onStreamClosed?() }
        guard let stream = response.sseStream else { return }
        do {
            for try await delta in stream {
                let wireData: Data?
                if delta.hasPrefix("\u{0001}TOOL_CALLS:") {
                    // Tool calls: emit {"tool_calls":[...]} so the iOS client can
                    // run the handlers and send a follow-up request.
                    let jsonStr = String(delta.dropFirst(12)) // "\u{0001}TOOL_CALLS:" = 12 chars
                    wireData = "data: {\"tool_calls\":\(jsonStr)}\n\n".data(using: .utf8)
                } else {
                    if let payload = try? JSONSerialization.data(withJSONObject: ["delta": delta]),
                       let payloadStr = String(data: payload, encoding: .utf8) {
                        wireData = "data: \(payloadStr)\n\n".data(using: .utf8)
                    } else {
                        wireData = nil
                    }
                }
                if let wd = wireData {
                    if let err = await sendRaw(wd, on: connection) {
                        print("[HTTPServer] SSE client disconnect: \(err)")
                        return
                    }
                }
            }
        } catch {
            print("[HTTPServer] SSE stream error: \(error)")
        }
        _ = await sendRaw(Data("data: [DONE]\n\n".utf8), on: connection)
    }

    private func sendRaw(_ data: Data, on connection: NWConnection) async -> NWError? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NWError?, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error)
            })
        }
    }
}
