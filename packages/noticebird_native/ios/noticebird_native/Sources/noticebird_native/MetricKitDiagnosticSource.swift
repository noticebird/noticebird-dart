import Foundation
import MetricKit

#if canImport(NativeCrashNormalizer)
import NativeCrashNormalizer
#endif

/// The `MXMetricManager` subscriber: one per process. MetricKit delivers the
/// diagnostics of earlier runs shortly after launch (iOS 15+), and hangs and
/// disk-write exceptions when it has them.
final class MetricKitDiagnosticSource: NSObject, DiagnosticSource, MXMetricManagerSubscriber {
    private var handler: (([NativeDiagnosticReport]) -> Void)?

    func start(_ handler: @escaping ([NativeDiagnosticReport]) -> Void) {
        self.handler = handler
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [NativeDiagnosticReport] = []
        for payload in payloads {
            guard let occurredAtMs = epochMilliseconds(payload.timeStampBegin) else { continue }
            for diagnostic in payload.crashDiagnostics ?? [] {
                reports.append(NativeDiagnosticReport(kind: .crash, occurredAtMs: occurredAtMs, json: diagnostic.jsonRepresentation()))
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                var report = NativeDiagnosticReport(kind: .hang, occurredAtMs: occurredAtMs, json: diagnostic.jsonRepresentation())
                report.hangDurationMs = diagnostic.hangDuration.converted(to: .milliseconds).value
                reports.append(report)
            }
            for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] {
                var report = NativeDiagnosticReport(
                    kind: .diskWriteException,
                    occurredAtMs: occurredAtMs,
                    json: diagnostic.jsonRepresentation()
                )
                report.bytesWritten = diagnostic.totalWritesCaused.converted(to: .bytes).value
                reports.append(report)
            }
        }
        guard !reports.isEmpty else { return }
        handler?(reports)
    }
}
