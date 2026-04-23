import Foundation

final class BonjourAdvertiser: NSObject {
    private var netService: NetService?

    func start(port: Int) {
        let name = Host.current().localizedName ?? "BigBro Mac"
        let service = NetService(domain: "local.", type: "_bigbro._tcp.", name: name, port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "version": Data("1.0".utf8),
            "port": Data(String(port).utf8)
        ]))
        service.delegate = self
        service.publish()
        self.netService = service
    }

    func stop() {
        netService?.stop()
        netService = nil
    }
}

extension BonjourAdvertiser: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        print("[Bonjour] Published \(sender.name) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[Bonjour] Failed to publish: \(errorDict)")
    }
}
