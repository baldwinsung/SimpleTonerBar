
import Foundation
import SwiftSnmpKit

struct TonerSupply {
    let name: String
    let percent: Int?
    let level: Int?
    let maxCapacity: Int?

    var shortCode: String {
        let lower = name.lowercased()
        if lower.contains("black") { return "B" }
        if lower.contains("cyan") { return "C" }
        if lower.contains("magenta") { return "M" }
        if lower.contains("yellow") { return "Y" }
        return String(name.prefix(1)).uppercased()
    }
}

struct PaperTray {
    let name: String
    let level: Int?
    let maxCapacity: Int?

    var percent: Int? {
        guard let max = maxCapacity, let lvl = level, max > 0, lvl >= 0 else { return nil }
        return min(100, Swift.max(0, (lvl * 100) / max))
    }
}

struct PrinterStatus {
    let supplies: [TonerSupply]
    let paperTrays: [PaperTray]
    let pageCount: Int?
    let isOnline: Bool
}

class TonerMonitor {

    private let community = "public"

    // RFC 3805 Printer MIB OIDs
    private let supplyDescriptionOID = "1.3.6.1.2.1.43.11.1.1.6.1"
    private let supplyMaxCapacityOID = "1.3.6.1.2.1.43.11.1.1.8.1"
    private let supplyLevelOID       = "1.3.6.1.2.1.43.11.1.1.9.1"
    private let pageCountOID         = "1.3.6.1.2.1.43.10.2.1.4.1.1"
    private let printerStatusOID     = "1.3.6.1.2.1.25.3.2.1.5.1"

    // RFC 3805 Input (paper tray) OIDs
    private let inputDescriptionOID  = "1.3.6.1.2.1.43.8.2.1.18.1"
    private let inputMaxCapacityOID  = "1.3.6.1.2.1.43.8.2.1.9.1"
    private let inputCurrentLevelOID = "1.3.6.1.2.1.43.8.2.1.10.1"
    private let inputMediaNameOID    = "1.3.6.1.2.1.43.8.2.1.12.1"

    private func snmpGet(host: String, oid: String) async -> Result<SnmpVariableBinding, Error> {
        guard let sender = SnmpSender.shared else {
            return .failure(SnmpError.noResponse)
        }
        return await sender.send(host: host, command: .getRequest, community: community, oid: oid)
    }

    private func snmpGetNext(host: String, oid: String) async -> Result<SnmpVariableBinding, Error> {
        guard let sender = SnmpSender.shared else {
            return .failure(SnmpError.noResponse)
        }
        return await sender.send(host: host, command: .getNextRequest, community: community, oid: oid)
    }

    func fetch(host: String, completion: @escaping (PrinterStatus) -> Void) {
        Task {
            let status = await fetchAsync(host: host)
            completion(status)
        }
    }

    private func fetchAsync(host: String) async -> PrinterStatus {
        guard !host.isEmpty else {
            return PrinterStatus(supplies: [], paperTrays: [], pageCount: nil, isOnline: false)
        }

        guard await checkOnline(host: host) else {
            return PrinterStatus(supplies: [], paperTrays: [], pageCount: nil, isOnline: false)
        }

        async let suppliesResult = fetchAllSupplies(host: host)
        async let pageCountResult = fetchPageCount(host: host)
        async let traysResult = fetchAllPaperTrays(host: host)

        let supplies = await suppliesResult
        let pageCount = await pageCountResult
        let trays = await traysResult

        return PrinterStatus(supplies: supplies, paperTrays: trays, pageCount: pageCount, isOnline: true)
    }

    private func checkOnline(host: String) async -> Bool {
        let result = await snmpGet(host: host, oid: printerStatusOID)
        switch result {
        case .success: return true
        case .failure: return false
        }
    }

    private func fetchAllSupplies(host: String) async -> [TonerSupply] {
        let entries = await walkSupplyDescriptions(host: host)
        return await fetchSupplyLevels(host: host, entries: entries)
    }

    /// Walk the supply description subtree to discover all supply entries.
    private func walkSupplyDescriptions(host: String) async -> [(index: Int, name: String)] {
        var results: [(index: Int, name: String)] = []
        var currentOID = supplyDescriptionOID

        while true {
            let result = await snmpGetNext(host: host, oid: currentOID)

            guard case .success(let binding) = result else { break }

            let returnedOID = binding.oid.description
            // Check we're still under the supply description subtree
            guard returnedOID.hasPrefix(supplyDescriptionOID + ".") else { break }
            // endOfMibView means no more entries
            if case .endOfMibView = binding.value { break }

            let components = returnedOID.split(separator: ".")
            guard let indexStr = components.last, let index = Int(indexStr) else { break }

            let name: String
            switch binding.value {
            case .octetString(let data):
                name = String(data: data, encoding: .utf8) ?? "Supply \(index)"
            default:
                name = "Supply \(index)"
            }

            results.append((index: index, name: name))
            currentOID = returnedOID
        }

        return results
    }

    private func fetchSupplyLevels(host: String, entries: [(index: Int, name: String)]) async -> [TonerSupply] {
        var supplies: [TonerSupply] = []

        for (index, name) in entries {
            let maxOID = "\(supplyMaxCapacityOID).\(index)"
            let levelOID = "\(supplyLevelOID).\(index)"

            async let maxResult = snmpGet(host: host, oid: maxOID)
            async let levelResult = snmpGet(host: host, oid: levelOID)

            let maxBinding = await maxResult
            let levelBinding = await levelResult

            let maxCapacity = extractInt(from: maxBinding)
            let level = extractInt(from: levelBinding)

            let percent: Int?
            if let max = maxCapacity, let lvl = level, max > 0, lvl >= 0 {
                percent = min(100, Swift.max(0, (lvl * 100) / max))
            } else {
                // Negative values (-1, -2, -3) per RFC 3805 = indeterminate
                percent = nil
            }

            supplies.append(TonerSupply(name: name, percent: percent, level: level, maxCapacity: maxCapacity))
        }

        return supplies
    }

    private func fetchAllPaperTrays(host: String) async -> [PaperTray] {
        let entries = await walkPaperTrayDescriptions(host: host)
        var trays: [PaperTray] = []

        for (index, name) in entries {
            let maxOID = "\(inputMaxCapacityOID).\(index)"
            let levelOID = "\(inputCurrentLevelOID).\(index)"

            async let maxResult = snmpGet(host: host, oid: maxOID)
            async let levelResult = snmpGet(host: host, oid: levelOID)

            let maxCapacity = extractInt(from: await maxResult)
            let level = extractInt(from: await levelResult)

            trays.append(PaperTray(name: name, level: level, maxCapacity: maxCapacity))
        }

        return trays
    }

    private func walkPaperTrayDescriptions(host: String) async -> [(index: Int, name: String)] {
        var results: [(index: Int, name: String)] = []
        var currentOID = inputDescriptionOID

        while true {
            let result = await snmpGetNext(host: host, oid: currentOID)

            guard case .success(let binding) = result else { break }

            let returnedOID = binding.oid.description
            guard returnedOID.hasPrefix(inputDescriptionOID + ".") else { break }
            if case .endOfMibView = binding.value { break }

            let components = returnedOID.split(separator: ".")
            guard let indexStr = components.last, let index = Int(indexStr) else { break }

            let name: String
            switch binding.value {
            case .octetString(let data):
                name = String(data: data, encoding: .utf8) ?? "Tray \(index)"
            default:
                name = "Tray \(index)"
            }

            results.append((index: index, name: name))
            currentOID = returnedOID
        }

        return results
    }

    private func fetchPageCount(host: String) async -> Int? {
        let result = await snmpGet(host: host, oid: pageCountOID)
        return extractInt(from: result)
    }

    private func extractInt(from result: Result<SnmpVariableBinding, Error>) -> Int? {
        guard case .success(let binding) = result else { return nil }
        switch binding.value {
        case .integer(let value):
            return Int(value)
        case .counter32(let value):
            return Int(value)
        case .gauge32(let value):
            return Int(value)
        case .counter64(let value):
            return Int(value)
        default:
            return nil
        }
    }
}
