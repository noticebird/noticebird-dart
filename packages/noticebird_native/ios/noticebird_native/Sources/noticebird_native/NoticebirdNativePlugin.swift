import Flutter
import Foundation

#if canImport(NativeCrashNormalizer)
import NativeCrashNormalizer
#endif

/// The Flutter side of the collector: one method channel and one event
/// channel per engine, all backed by the one process-wide
/// `NativeCrashCollector` (the native contract), which runs on its own queue.
/// Replies and arrivals are handed back on the main thread here.
///
/// Registration runs from `GeneratedPluginRegistrant` — before any Dart code —
/// so the collector records the run and subscribes to MetricKit at launch,
/// and a diagnostic delivered early is persisted even if Dart starts late.
public final class NoticebirdNativePlugin: NSObject, FlutterPlugin {
    static let methodChannelName = "noticebird_native"
    static let eventChannelName = "noticebird_native/arrivals"

    /// One per process, whichever engine registers first (Workmanager
    /// registers every plugin again in each headless engine).
    static let collector = NativeCrashCollector(source: MetricKitDiagnosticSource()) { count in
        DispatchQueue.main.async { ArrivalBroadcaster.shared.emit(count) }
    }

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let arrivals = ArrivalsStreamHandler()

    private init(methodChannel: FlutterMethodChannel, eventChannel: FlutterEventChannel) {
        self.methodChannel = methodChannel
        self.eventChannel = eventChannel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let plugin = NoticebirdNativePlugin(
            methodChannel: FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger),
            eventChannel: FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
        )
        registrar.addMethodCallDelegate(plugin, channel: plugin.methodChannel)
        plugin.eventChannel.setStreamHandler(plugin.arrivals)
        collector.activate()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        methodChannel.setMethodCallHandler(nil)
        eventChannel.setStreamHandler(nil)
        arrivals.detach()
    }

    /// Every method replies, on the main thread; a failure replies with an
    /// empty result.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
        let collector = Self.collector
        switch call.method {
        case "start":
            let options = CaptureOptions(
                // Unreadable means strict: privacy fails closed.
                strict: arguments["strict"] as? Bool ?? true,
                hangs: arguments["hangs"] as? Bool ?? false,
                diskWrites: arguments["diskWrites"] as? Bool ?? false
            )
            collector.start(options) { reply($0) }
        case "claim":
            collector.claim(max: arguments["max"] as? Int ?? 0) { reply($0) }
        case "settle":
            guard let recordId = arguments["recordId"] as? String,
                  let delivered = arguments["delivered"] as? Bool
            else {
                result(nil)
                return
            }
            collector.settle(recordId: recordId, delivered: delivered) { reply(nil) }
        case "disable":
            collector.disable { reply(nil) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// The arrivals event channel of one engine: emits the number of new inbox
/// records while its Dart side listens. Flutter calls it on the main thread.
final class ArrivalsStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        ArrivalBroadcaster.shared.add(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        detach()
        return nil
    }

    func emit(_ count: Int) {
        sink?(count)
    }

    func detach() {
        sink = nil
        ArrivalBroadcaster.shared.remove(self)
    }
}

/// Hands arrivals to every engine whose Dart side listens. Main thread only.
final class ArrivalBroadcaster {
    static let shared = ArrivalBroadcaster()

    private struct WeakHandler {
        weak var value: ArrivalsStreamHandler?
    }

    private var handlers: [WeakHandler] = []

    func add(_ handler: ArrivalsStreamHandler) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
        handlers.append(WeakHandler(value: handler))
    }

    func remove(_ handler: ArrivalsStreamHandler) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
    }

    func emit(_ count: Int) {
        handlers.removeAll { $0.value == nil }
        for handler in handlers {
            handler.value?.emit(count)
        }
    }
}
