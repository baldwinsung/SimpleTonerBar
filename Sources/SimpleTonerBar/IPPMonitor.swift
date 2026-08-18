
import Foundation

/// Reads supply levels over IPP for printers that don't answer SNMP.
///
/// Many current consumer/SMB printers (HP Pro series, for one) ship with SNMPv1/v2
/// disabled but always answer IPP, because that is what AirPrint runs on. The IPP
/// response carries the same marker levels, input trays and page counts the Printer
/// MIB would have given us.
enum IPPMonitor {

    private static let ipptoolPath = "/usr/bin/ipptool"

    /// Seconds ipptool waits for the printer before giving up on a candidate URI.
    private static let requestTimeout = 5

    private static let requestedAttributes = [
        "marker-names",
        "marker-levels",
        "marker-high-levels",
        "marker-colors",
        "printer-state",
        "printer-input-tray",
        "printer-impressions-completed-col",
        "printer-impressions-completed",
        "printer-make-and-model"
    ]

    /// Blocking; call from a background queue.
    static func fetch(host: String, uri: String?) -> PrinterStatus? {
        guard !host.isEmpty, FileManager.default.isExecutableFile(atPath: ipptoolPath) else { return nil }
        guard let testFile = writeTestFile() else { return nil }
        defer { try? FileManager.default.removeItem(at: testFile) }

        for candidate in candidateURIs(host: host, knownURI: uri) {
            guard let attributes = run(uri: candidate, testFile: testFile) else { continue }
            if let status = makeStatus(from: attributes) { return status }
        }
        return nil
    }

    /// The URI CUPS already prints to first, then the standard AirPrint resource paths.
    static func candidateURIs(host: String, knownURI: String?) -> [String] {
        var uris: [String] = []
        if let knownURI, knownURI.hasPrefix("ipp://") || knownURI.hasPrefix("ipps://") {
            uris.append(knownURI)
        }
        for path in ["/ipp/print", "/ipp/printer", "/"] {
            let candidate = "ipp://\(host):631\(path)"
            if !uris.contains(candidate) { uris.append(candidate) }
        }
        return uris
    }

    /// ipptool drives a request from a test file, so write the one we need.
    private static func writeTestFile() -> URL? {
        let contents = """
        {
            OPERATION Get-Printer-Attributes
            GROUP operation-attributes-tag
            ATTR charset attributes-charset utf-8
            ATTR language attributes-natural-language en
            ATTR uri printer-uri $uri
            ATTR keyword requested-attributes \(requestedAttributes.joined(separator: ","))
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleTonerBar-supplies-\(UUID().uuidString).test")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Run ipptool in plist mode and return the printer attribute group.
    private static func run(uri: String, testFile: URL) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ipptoolPath)
        process.arguments = ["-X", "-T", "\(requestTimeout)", uri, testFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let tests = root["Tests"] as? [[String: Any]],
              let test = tests.first,
              test["Successful"] as? Bool == true,
              let groups = test["ResponseAttributes"] as? [[String: Any]] else { return nil }

        // The first group is the operation attributes; the printer attributes follow.
        return groups.dropFirst().last ?? groups.first
    }

    private static func makeStatus(from attributes: [String: Any]) -> PrinterStatus? {
        let supplies = parseSupplies(attributes)
        // A response with no marker data tells us nothing the menu bar can show.
        guard !supplies.isEmpty else { return nil }

        return PrinterStatus(
            supplies: supplies,
            paperTrays: parseTrays(attributes),
            pageCount: parsePageCount(attributes),
            isOnline: true,
            source: .ipp
        )
    }

    private static func parseSupplies(_ attributes: [String: Any]) -> [TonerSupply] {
        guard let levels = attributes["marker-levels"] as? [Int] else { return [] }
        let names = attributes["marker-names"] as? [String] ?? []
        let highs = attributes["marker-high-levels"] as? [Int] ?? []

        return levels.enumerated().map { index, level in
            let name = index < names.count ? names[index] : "Supply \(index + 1)"
            // marker-high-levels is the 100% mark; printers that omit it report percentages.
            let maxCapacity = index < highs.count && highs[index] > 0 ? highs[index] : 100
            // Negative levels mean unknown or "almost empty" — same convention as RFC 3805.
            let percent = level >= 0 ? min(100, (level * 100) / maxCapacity) : nil
            return TonerSupply(
                name: name,
                percent: percent,
                level: level >= 0 ? level : nil,
                maxCapacity: maxCapacity
            )
        }
    }

    /// printer-input-tray entries are octet strings like
    /// `type=...;maxcapacity=250;level=-2;unit=percent;name=Tray\ 2;`
    private static func parseTrays(_ attributes: [String: Any]) -> [PaperTray] {
        guard let raw = attributes["printer-input-tray"] as? [Any] else { return [] }

        return raw.enumerated().compactMap { index, entry in
            let text: String
            if let data = entry as? Data {
                text = String(data: data, encoding: .utf8) ?? ""
            } else if let string = entry as? String {
                text = string
            } else {
                return nil
            }

            let fields = parseKeyValues(text)
            let name = fields["name"]?.replacingOccurrences(of: "\\ ", with: " ") ?? "Tray \(index + 1)"
            let level = fields["level"].flatMap(Int.init)
            let maxCapacity = fields["maxcapacity"].flatMap(Int.init)

            return PaperTray(
                name: name,
                level: (level ?? -1) >= 0 ? level : nil,
                maxCapacity: maxCapacity
            )
        }
    }

    private static func parseKeyValues(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in text.components(separatedBy: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            fields[key] = String(pair[pair.index(after: equals)...])
        }
        return fields
    }

    private static func parsePageCount(_ attributes: [String: Any]) -> Int? {
        // Color printers report the breakdown by colorant; mono printers report a single total.
        if let breakdown = attributes["printer-impressions-completed-col"] as? [String: Any] {
            let total = breakdown.values.compactMap { $0 as? Int }.reduce(0, +)
            if total > 0 { return total }
        }
        return attributes["printer-impressions-completed"] as? Int
    }
}
