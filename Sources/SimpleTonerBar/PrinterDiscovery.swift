
import Foundation
import Network

struct DiscoveredPrinter: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let host: String
    let model: String
    let location: String
}

class PrinterDiscovery: ObservableObject {

    @Published var printers: [DiscoveredPrinter] = []

    /// Called on the main queue each time a new printer is discovered.
    var onPrinterFound: ((DiscoveredPrinter) -> Void)?

    private var browsers: [NWBrowser] = []
    private var resolvers: [String: NetService] = [:]
    private var activeResolvers: [String: ServiceResolver] = [:]

    func startDiscovery() {
        printers = []
        resolvers.removeAll()
        activeResolvers.removeAll()

        // Also try system printers from CUPS as a fast path
        loadSystemPrinters()

        // Browse both IPP and IPPS (AirPrint uses _ipps._tcp)
        for serviceType in ["_ipp._tcp", "_ipps._tcp"] {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: "local."), using: params)

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                self.handleBrowseResults(results)
            }

            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    browser.cancel()
                }
            }

            browser.start(queue: .global(qos: .userInitiated))
            browsers.append(browser)
        }
    }

    func stopDiscovery() {
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
        for service in resolvers.values {
            service.stop()
        }
        resolvers.removeAll()
        activeResolvers.removeAll()
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata else { continue }
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }

            let dict = Self.parseTXT(txt)
            let model = dict["ty"] ?? ""
            let location = dict["note"] ?? ""

            let service = NetService(domain: domain, type: type, name: name)
            let key = "\(name).\(type).\(domain)"

            if self.resolvers[key] != nil { continue }

            let resolver = ServiceResolver(service: service, model: model, location: location) { [weak self] printer in
                guard let self, let printer else { return }
                DispatchQueue.main.async {
                    if !self.printers.contains(where: { $0.host == printer.host }) {
                        self.printers.append(printer)
                        self.onPrinterFound?(printer)
                    }
                }
            }
            self.resolvers[key] = service
            self.activeResolvers[key] = resolver
            DispatchQueue.main.async {
                resolver.resolve()
            }
        }
    }

    /// Load printers already configured in macOS System Settings via CUPS.
    private func loadSystemPrinters() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let printers = Self.querySystemPrinters()
            DispatchQueue.main.async {
                for printer in printers {
                    if !self.printers.contains(where: { $0.host == printer.host }) {
                        self.printers.append(printer)
                        self.onPrinterFound?(printer)
                    }
                }
            }
        }
    }

    /// Parse `lpstat -v` output and resolve any .local hostnames to IPv4.
    private static func querySystemPrinters() -> [DiscoveredPrinter] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        process.arguments = ["-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [DiscoveredPrinter] = []

        // Lines look like: "device for PrinterName: ipp://host:port/path"
        // or: "device for PrinterName: dnssd://Service%20Name._ipps._tcp.local./?uuid=..."
        for line in output.components(separatedBy: "\n") {
            guard let colonRange = line.range(of: ": ") else { continue }
            let prefix = line[line.startIndex..<colonRange.lowerBound]
            let uri = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Extract printer name from "device for PrinterName"
            let displayName = prefix.replacingOccurrences(of: "device for ", with: "")
                .replacingOccurrences(of: "_", with: " ")

            guard let ip = resolveIPFromURI(uri) else { continue }
            results.append(DiscoveredPrinter(name: displayName, host: ip, model: "", location: "System Printer"))
        }

        return results
    }

    /// Extract and resolve the host from a CUPS device URI to an IPv4 address.
    private static func resolveIPFromURI(_ uri: String) -> String? {
        // Handle dnssd:// URIs by extracting the Bonjour service name and resolving
        if uri.hasPrefix("dnssd://") {
            return resolveFromDnssdURI(uri)
        }

        // Handle ipp://, ipps://, http://, https:// URIs
        guard let url = URL(string: uri), let host = url.host, !host.isEmpty else { return nil }

        // If it's already an IP address, return it
        if isIPv4(host) { return host }

        // Resolve .local hostname
        if host.hasSuffix(".local") || host.hasSuffix(".local.") {
            return resolveLocalHostname(host)
        }

        return nil
    }

    /// Resolve a dnssd:// URI by extracting the .local hostname from the service.
    private static func resolveFromDnssdURI(_ uri: String) -> String? {
        // dnssd URI contains the service name. We need to find the .local hostname.
        // Use lpstat -l or dns-sd, but simplest: extract any .local. host from the URI path
        // Actually, the best approach: use the percent-decoded service name to look up via dns-sd

        // Parse the Bonjour service type from the URI
        // e.g., dnssd://HP%20...._ipps._tcp.local./?uuid=...
        guard let url = URL(string: uri.replacingOccurrences(of: "dnssd://", with: "http://")) else { return nil }
        guard let host = url.host, host.hasSuffix(".local.") || host.hasSuffix(".local") else { return nil }

        // The host in a dnssd URI is the service instance name, not a resolvable hostname.
        // We need to get the actual hostname. Use getaddrinfo on the Bonjour hostname instead.
        // The actual hostname comes from the SRV record. Let's try resolving via Process.
        return resolveBonjourHostname(fromDnssdURI: uri)
    }

    /// Use dns-sd -L to look up the SRV record, then resolve the .local hostname.
    private static func resolveBonjourHostname(fromDnssdURI uri: String) -> String? {
        // Extract service name and type from dnssd:// URI
        // Format: dnssd://Service%20Name._type._tcp.local./?params
        let decoded = uri.removingPercentEncoding ?? uri
        let stripped = decoded.replacingOccurrences(of: "dnssd://", with: "")

        // Find the service type pattern (_type._tcp)
        guard let typeRange = stripped.range(of: #"\._ipp[s]?\._tcp"#, options: .regularExpression) else { return nil }

        let serviceName = String(stripped[stripped.startIndex..<typeRange.lowerBound])
        let afterName = stripped[typeRange.lowerBound...]
        // Extract type: _ipp._tcp or _ipps._tcp
        let typeEndPatterns = [".local.", ".local"]
        var serviceType = ""
        for pattern in typeEndPatterns {
            if let r = afterName.range(of: pattern) {
                serviceType = String(afterName[afterName.index(after: afterName.startIndex)..<r.lowerBound])
                break
            }
        }
        if serviceType.isEmpty { return nil }

        // Run dns-sd -L to get the hostname
        let lookupProcess = Process()
        lookupProcess.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        lookupProcess.arguments = ["-L", serviceName, serviceType, "local."]
        let lookupPipe = Pipe()
        lookupProcess.standardOutput = lookupPipe
        lookupProcess.standardError = lookupPipe

        do {
            try lookupProcess.run()
        } catch {
            return nil
        }

        // dns-sd runs indefinitely, so kill after a short wait
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            lookupProcess.terminate()
        }
        let lookupData = lookupPipe.fileHandleForReading.readDataToEndOfFile()
        let lookupOutput = String(data: lookupData, encoding: .utf8) ?? ""

        // Parse "can be reached at HOSTNAME.local.:PORT"
        guard let reachRange = lookupOutput.range(of: "can be reached at ") else { return nil }
        let afterReach = lookupOutput[reachRange.upperBound...]
        guard let colonRange = afterReach.range(of: ":") else { return nil }
        let hostname = String(afterReach[afterReach.startIndex..<colonRange.lowerBound])

        return resolveLocalHostname(hostname)
    }

    /// Resolve a .local hostname to an IPv4 address using getaddrinfo.
    private static func resolveLocalHostname(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?

        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer { freeaddrinfo(result) }

        guard status == 0, let info = result else { return nil }
        let addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return String(cString: inet_ntoa(addr.sin_addr))
    }

    private static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    private static func parseTXT(_ record: NWTXTRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for (key, value) in record.dictionary {
            dict[key] = value
        }
        return dict
    }
}

private class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let model: String
    private let location: String
    private let completion: (DiscoveredPrinter?) -> Void
    private var resolved = false

    init(service: NetService, model: String, location: String, completion: @escaping (DiscoveredPrinter?) -> Void) {
        self.service = service
        self.model = model
        self.location = location
        self.completion = completion
        super.init()
        service.delegate = self
    }

    func resolve() {
        service.resolve(withTimeout: 5.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !resolved else { return }
        resolved = true
        if let ip = ipv4Address(from: sender.addresses ?? []) {
            completion(DiscoveredPrinter(name: sender.name, host: ip, model: model, location: location))
        } else {
            completion(nil)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard !resolved else { return }
        resolved = true
        completion(nil)
    }

    private func ipv4Address(from addresses: [Data]) -> String? {
        for data in addresses {
            if data.count >= MemoryLayout<sockaddr_in>.size {
                let family = data.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
                if family == sa_family_t(AF_INET) {
                    let addr = data.withUnsafeBytes { $0.load(as: sockaddr_in.self) }
                    let ip = String(cString: inet_ntoa(addr.sin_addr))
                    return ip
                }
            }
        }
        return nil
    }
}
