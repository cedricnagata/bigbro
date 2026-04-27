import Foundation
import Network

protocol PeerServerDelegate: AnyObject, Sendable {
    func peerServer(_ server: PeerServer, didReceive message: [String: Any], connectionId: UUID) async
    func peerServer(_ server: PeerServer, didDisconnectPeer deviceId: String) async
    func peerServer(_ server: PeerServer, didConnectFirstPeer deviceId: String) async
    func peerServer(_ server: PeerServer, didDisconnectLastPeer deviceId: String) async
}

actor PeerServer {
    private var listener: NWListener?
    private var pending: [UUID: NWConnection] = [:]      // before hello
    private var peers: [String: NWConnection] = [:]      // after hello: deviceId → connection
    private var connectionIds: [UUID: String] = [:]      // connectionId → deviceId
    private var lastHeard: [String: Date] = [:]          // deviceId → last message timestamp
    weak var delegate: PeerServerDelegate?

    func setDelegate(_ delegate: PeerServerDelegate) {
        self.delegate = delegate
    }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { state in
            print("[PeerServer] Listener state: \(state)")
        }
        listener?.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener?.start(queue: .global(qos: .userInitiated))
        print("[PeerServer] Started on port \(port)")
    }

    func stop() {
        print("[PeerServer] Stopping")
        listener?.cancel()
        listener = nil
        peers.values.forEach { $0.cancel() }
        pending.values.forEach { $0.cancel() }
        peers.removeAll()
        pending.removeAll()
        connectionIds.removeAll()
    }

    /// Sends bye to all connected peers, then stops. Use for graceful shutdown.
    func shutdown() async {
        print("[PeerServer] Shutdown: sending bye to \(peers.count) peer(s)")
        for deviceId in peers.keys {
            await send(["type": "bye"], to: deviceId)
        }
        stop()
    }

    func register(connectionId: UUID, as deviceId: String) async {
        guard let conn = pending[connectionId] else {
            print("[PeerServer] register: no pending connection for \(connectionId)")
            return
        }
        let wasEmpty = peers.isEmpty
        pending.removeValue(forKey: connectionId)
        peers[deviceId] = conn
        connectionIds[connectionId] = deviceId
        print("[PeerServer] Registered connection \(connectionId) as device \(deviceId.prefix(8))")
        if wasEmpty {
            await delegate?.peerServer(self, didConnectFirstPeer: deviceId)
        }
    }

    func deviceId(for connectionId: UUID) -> String? {
        connectionIds[connectionId]
    }

    func lastHeardDate(for deviceId: String) -> Date? {
        lastHeard[deviceId]
    }

    func send(_ message: [String: Any], to deviceId: String) async {
        guard let conn = peers[deviceId] else {
            print("[PeerServer] send: no peer for deviceId \(deviceId.prefix(8))")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        print("[PeerServer] → \(deviceId.prefix(8)): \(message["type"] ?? "?")")
        let frame = framed(data)
        await withCheckedContinuation { cont in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error { print("[PeerServer] send error: \(error)") }
                cont.resume()
            })
        }
    }

    /// Sends bye then cancels the connection. Leaves connectionIds intact for readLoop cleanup.
    func disconnect(deviceId: String) async {
        print("[PeerServer] Disconnecting device \(deviceId.prefix(8))")
        await send(["type": "bye"], to: deviceId)
        peers[deviceId]?.cancel()
        peers.removeValue(forKey: deviceId)
        lastHeard.removeValue(forKey: deviceId)
        // connectionIds left intact so readLoop can detect closure and call didDisconnectPeer
        if peers.isEmpty {
            await delegate?.peerServer(self, didDisconnectLastPeer: deviceId)
        }
    }

    func send(_ message: [String: Any], toPending connectionId: UUID) async {
        guard let conn = pending[connectionId] else {
            print("[PeerServer] sendToPending: no pending connection for \(connectionId)")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        print("[PeerServer] → pending \(connectionId): \(message["type"] ?? "?")")
        let frame = framed(data)
        await withCheckedContinuation { cont in
            conn.send(content: frame, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    func disconnectPending(connectionId: UUID) {
        print("[PeerServer] Disconnecting pending \(connectionId)")
        pending[connectionId]?.cancel()
        pending.removeValue(forKey: connectionId)
    }

    // MARK: - Private

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        pending[id] = connection
        print("[PeerServer] Accepted new connection, assigned id \(id)")

        connection.stateUpdateHandler = { state in
            print("[PeerServer] Connection \(id) state: \(state)")
        }

        connection.viabilityUpdateHandler = { [weak self] isViable in
            guard !isViable else { return }
            print("[PeerServer] Connection \(id) no longer viable")
            Task { await self?.handleViabilityLost(connectionId: id) }
        }

        connection.start(queue: .global(qos: .userInitiated))
        Task { await readLoop(connection: connection, connectionId: id) }
    }

    private func handleViabilityLost(connectionId: UUID) async {
        print("[PeerServer] Cleaning up connection \(connectionId) due to viability loss")
        let deviceId = connectionIds.removeValue(forKey: connectionId)
        pending.removeValue(forKey: connectionId)
        if let deviceId {
            peers[deviceId]?.cancel()
            peers.removeValue(forKey: deviceId)
            lastHeard.removeValue(forKey: deviceId)
            print("[PeerServer] Device \(deviceId.prefix(8)) disconnected via viability loss")
            await delegate?.peerServer(self, didDisconnectPeer: deviceId)
            if peers.isEmpty {
                await delegate?.peerServer(self, didDisconnectLastPeer: deviceId)
            }
        }
    }

    private func readLoop(connection: NWConnection, connectionId: UUID) async {
        print("[PeerServer] Read loop started for connection \(connectionId)")
        var buffer = Data()
        while true {
            guard let chunk = await receive(from: connection) else {
                print("[PeerServer] Read loop ended for connection \(connectionId)")
                break
            }
            buffer.append(chunk)
            while buffer.count >= 4 {
                let length = buffer.prefix(4).withUnsafeBytes {
                    Int(UInt32(bigEndian: $0.load(as: UInt32.self)))
                }
                guard buffer.count >= 4 + length else { break }
                let msgData = buffer[4..<(4 + length)]
                buffer = Data(buffer[(4 + length)...])
                if let json = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] {
                    print("[PeerServer] ← \(connectionId): type=\(json["type"] ?? "?")")
                    // Update last-heard for any registered device without waiting on the delegate
                    if let deviceId = connectionIds[connectionId] {
                        lastHeard[deviceId] = Date()
                        // Handle ping directly so it's never blocked by an in-flight delegate call
                        if json["type"] as? String == "ping" {
                            await send(["type": "pong"], to: deviceId)
                            continue
                        }
                    }
                    await delegate?.peerServer(self, didReceive: json, connectionId: connectionId)
                } else {
                    print("[PeerServer] Failed to parse message from \(connectionId) (\(length) bytes)")
                }
            }
        }
        let deviceId = connectionIds.removeValue(forKey: connectionId)
        pending.removeValue(forKey: connectionId)
        if let deviceId {
            peers.removeValue(forKey: deviceId)
            lastHeard.removeValue(forKey: deviceId)
            print("[PeerServer] Device \(deviceId.prefix(8)) disconnected")
            await delegate?.peerServer(self, didDisconnectPeer: deviceId)
            if peers.isEmpty {
                await delegate?.peerServer(self, didDisconnectLastPeer: deviceId)
            }
        } else {
            print("[PeerServer] Pending connection \(connectionId) closed before hello")
        }
    }

    private func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { print("[PeerServer] Receive error: \(error)") }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func framed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        return frame
    }
}
