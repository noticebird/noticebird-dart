import Flutter
import MetricKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    MXMetricManager.shared.add(RawPayloadRecorder.shared)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CrashLab") {
      CrashLab.register(with: registrar.messenger())
    }
  }
}

/// The crash lab's native triggers. Deliberate, and only in this example app:
/// an uncaught Objective-C exception, and a main thread blocked long enough
/// for a MetricKit hang diagnostic.
enum CrashLab {
  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "noticebird_native_example/lab", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "objcException":
          result(nil)
          DispatchQueue.main.async {
            NSException(
              name: .invalidArgumentException,
              reason: "Deliberate Objective-C exception from the native crash lab",
              userInfo: nil
            ).raise()
          }
        case "blockMainThread":
          result(nil)
          DispatchQueue.main.async { Thread.sleep(forTimeInterval: 5) }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }
}

/// Keeps every MetricKit diagnostic payload this app receives, raw, in
/// `Documents/metrickit/` — shared through Finder's Files tab for this app
/// (`UIFileSharingEnabled`). Only the crash lab does this: it is how a device
/// smoke yields a recorded payload for the normalizer's fixtures. The plugin
/// itself never stores a raw report.
final class RawPayloadRecorder: NSObject, MXMetricManagerSubscriber {
  static let shared = RawPayloadRecorder()

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    let directory = documents.appendingPathComponent("metrickit", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for payload in payloads {
      let name = "diagnostic-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
      try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name))
    }
  }
}

