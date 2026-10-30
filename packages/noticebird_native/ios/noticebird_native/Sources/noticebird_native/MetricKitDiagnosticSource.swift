import Foundation
import MetricKit

#if canImport(NativeCrashNormalizer)
import NativeCrashNormalizer
#endif

/// The `MXMetricManager` subscriber: one per process. MetricKit delivers the
/// diagnostics of earlier runs shortly after launch (iOS 15+), and hangs and
/// disk-write exceptions when it has them.
final class MetricKitDiagnosticSource: NSObject, DiagnosticSource, MXMetricManagerSubscriber {
    private var handler: (([DiagnosticReport]) -> Void)?

    func start(_ handler: @escaping ([DiagnosticReport]) -> Void) {
        self.handler = handler
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [DiagnosticReport] = []
        for payload in payloads {
            guard let occurredAtMs = epochMilliseconds(payload.timeStampBegin) else { continue }
            for diagnostic in payload.crashDiagnostics ?? [] {
                reports.append(DiagnosticReport(kind: .crash, occurredAtMs: occurredAtMs, json: diagnostic.jsonRepresentation()))
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                var report = DiagnosticReport(kind: .hang, occurredAtMs: occurredAtMs, json: diagnostic.jsonRepresentation())
                report.hangDurationMs = diagnostic.hangDuration.converted(to: .milliseconds).value
                reports.append(report)
            }
            for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] {
                var report = DiagnosticReport(
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
