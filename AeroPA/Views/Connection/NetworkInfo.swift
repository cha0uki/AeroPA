import Foundation

/// Reads this device's IPv4 addresses so the user knows what to type into Aerofly's broadcast IP field.
enum NetworkInfo {
    struct Address: Hashable {
        var interface: String
        var ip: String
        var interfaceLabel: String {
            if interface == "en0" { return "Wi-Fi" }
            if interface.hasPrefix("bridge") || interface.hasPrefix("ap") { return "Hotspot" }
            if interface.hasPrefix("en") { return "Ethernet (\(interface))" }
            return interface
        }
    }

    static func localIPv4Addresses() -> [Address] {
        var result: [Address] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(Address(interface: name, ip: String(cString: host)))
            }
        }
        return result.sorted { $0.interface < $1.interface }
    }
}
