import Foundation

public final class BonjourAdvertiser: NSObject {
    private var service: NetService?

    public func publish(port: Int) {
        let service = NetService(
            domain: "", type: "_phonenotif._tcp.",
            name: "PhoneBridge", port: Int32(port))
        service.publish()
        self.service = service
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}
