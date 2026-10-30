import Foundation

/// One diagnostic as the operating system delivered it, before
/// normalization. It lives in memory only: the raw JSON is never persisted.
public struct DiagnosticReport: Sendable {
    public var kind: DiagnosticKind
    /// The delivering payload's `timeStampBegin`.
    public var occurredAtMs: Int64
    /// The diagnostic's `jsonRepresentation()`.
    public var json: Data
    /// A hang's duration, from the typed measurement.
    public var hangDurationMs: Double?
    /// A disk-write exception's bytes, from the typed measurement.
    public var bytesWritten: Double?

    public init(
        kind: DiagnosticKind,
        occurredAtMs: Int64,
        json: Data,
        hangDurationMs: Double? = nil,
        bytesWritten: Double? = nil
    ) {
        self.kind = kind
        self.occurredAtMs = occurredAtMs
        self.json = json
        self.hangDurationMs = hangDurationMs
        self.bytesWritten = bytesWritten
    }
}

/// Where diagnostic reports come from. v1 has one implementation, the
/// plugin's MetricKit source over `MXMetricManager`; the iOS 27
/// `MetricManager` adapter joins it once the minimum Xcode builds the iOS 27
/// SDK (plan decision D10).
public protocol DiagnosticSource: AnyObject {
    /// Starts delivering reports to [handler], on any thread. Called once per
    /// process.
    func start(_ handler: @escaping ([DiagnosticReport]) -> Void)
}

/// Milliseconds since the epoch of [date], or nil when it has none.
public func epochMilliseconds(_ date: Date) -> Int64? {
    let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
    guard milliseconds.isFinite else { return nil }
    return Int64(exactly: milliseconds)
}
