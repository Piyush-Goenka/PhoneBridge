import Foundation
import NIOCore

// The bridge only ever talks to a phone on the same LAN or over a private
// VPN. This predicate lets the server drop anything internet-routed before a
// single TLS byte is parsed, so a forwarded port can never expose the
// handshake to the open internet. The ranges match the design: loopback,
// RFC 1918, link-local, and CGNAT (Tailscale and friends hand out 100.64/10).
public enum PrivateAddress {

    public static func isAllowed(_ address: SocketAddress) -> Bool {
        switch address {
        case .v4(let v4):
            var raw = v4.address.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return false
            }
            return isAllowedIPv4(String(cString: buffer))
        case .v6:
            // The listener binds 0.0.0.0 (IPv4 only); the sole IPv6 peer that
            // can appear is a loopback mapping, which is always local.
            return address.ipAddress == "::1"
        case .unixDomainSocket:
            return true
        }
    }

    // Split out so the range logic is unit-testable without a live socket.
    public static func isAllowedIPv4(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let (a, b) = (octets[0], octets[1])
        if a == 127 { return true }                                  // loopback
        if a == 10 { return true }                                   // 10/8
        if a == 172 && (16...31).contains(b) { return true }         // 172.16/12
        if a == 192 && b == 168 { return true }                      // 192.168/16
        if a == 169 && b == 254 { return true }                      // link-local
        if a == 100 && (64...127).contains(b) { return true }        // CGNAT 100.64/10
        return false
    }
}
