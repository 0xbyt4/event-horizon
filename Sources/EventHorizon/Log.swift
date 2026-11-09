import os

/// Unified logging. Read the logs with:
/// `log show --last 10m --predicate 'subsystem == "local.eventhorizon"'`
enum Log {
    static let sweep = Logger(subsystem: "local.eventhorizon", category: "sweep")
    static let trash = Logger(subsystem: "local.eventhorizon", category: "trash")
}
