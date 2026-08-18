
import Foundation
import SwiftSnmpKit

/// Serializes every request through `SnmpSender.shared`.
///
/// SwiftSnmpKit tracks in-flight requests in a plain unsynchronized dictionary
/// (`SnmpSender.snmpRequests`), so two overlapping sends corrupt it and the process
/// aborts inside `SnmpSender.sent(message:continuation:)`. Routing all SNMP through
/// this gate keeps exactly one exchange in flight — including when a scheduled poll
/// overlaps a manual "Refresh Now".
actor SnmpGate {

    static let shared = SnmpGate()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func send(host: String, command: SnmpPduType, community: String, oid: String) async -> Result<SnmpVariableBinding, Error> {
        await acquire()
        defer { release() }

        guard let sender = SnmpSender.shared else {
            return .failure(SnmpError.noResponse)
        }
        return await sender.send(host: host, command: command, community: community, oid: oid)
    }

    /// Being an actor is not enough on its own: actors are reentrant, so a task
    /// suspended on the network call would let the next one straight in. Hence an
    /// explicit async lock.
    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
