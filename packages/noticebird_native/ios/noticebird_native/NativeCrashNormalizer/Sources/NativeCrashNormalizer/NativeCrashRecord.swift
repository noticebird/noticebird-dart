import Foundation

/// One inbox record of the native contract (record version 1): the allowlisted,
/// bounded description of one operating-system report, identified by the
/// SHA-256 of its canonical JSON when it is created. The id is fixed then: a
/// record whose message is stripped later (strict switched on) keeps it.
///
/// A record can only be constructed valid: both initializers check every
/// rule of the contract (which are the protocol's schema-4 rules), so what
/// the collector writes and what crosses the channel always decodes on the
/// Dart side.
public struct NativeCrashRecord: Equatable, Sendable {
    public static let recordVersion: Int64 = 1

    public enum Kind: String, CaseIterable, Sendable {
        case crash, watchdogKill, anr, memoryKill, hang, diskWriteException
    }

    public enum Source: String, CaseIterable, Sendable {
        case metricKit, exitInfo, jvm
    }

    public enum Arch: String, CaseIterable, Sendable {
        case arm64, arm64e, armv7
        case x86_64 = "x86_64"
        case x86
    }

    public struct Image: Hashable, Sendable {
        public var name: String
        public var debugId: String?
        public var arch: Arch?
        public var inApp: Bool

        public init(name: String, debugId: String? = nil, arch: Arch? = nil, inApp: Bool) {
            self.name = name
            self.debugId = debugId
            self.arch = arch
            self.inApp = inApp
        }
    }

    /// `{image, offset, symbol?}`, `{symbol, line?}` or `{}`.
    public struct Frame: Hashable, Sendable {
        public var image: Int?
        public var offset: Int64?
        public var symbol: String?
        public var line: Int64?

        public init(image: Int? = nil, offset: Int64? = nil, symbol: String? = nil, line: Int64? = nil) {
            self.image = image
            self.offset = offset
            self.symbol = symbol
            self.line = line
        }

        /// A frame in no known image (JIT code).
        public static let unknown = Frame()

        public static func inImage(_ image: Int, offset: Int64) -> Frame {
            Frame(image: image, offset: offset)
        }
    }

    /// Everything a record holds except its id.
    public struct Fields: Equatable, Sendable {
        public var kind: Kind
        public var source: Source
        public var occurredAtMs: Int64
        public var machException: String?
        public var signal: String?
        public var code: String?
        public var terminationCode: String?
        public var exceptionClass: String?
        public var exceptionMessage: String?
        public var durationMs: Int64?
        public var bytesWritten: Int64?
        public var images: [Image] = []
        public var frames: [Frame] = []
        public var runId: String?
        public var pid: Int64?
        public var appVersion: String?
        public var appBuild: String?
        public var foreground: Bool?

        public init(kind: Kind, source: Source, occurredAtMs: Int64) {
            self.kind = kind
            self.source = source
            self.occurredAtMs = occurredAtMs
        }
    }

    public let fields: Fields

    /// SHA-256 (lowercase hex) of the canonical JSON of the fields the record
    /// was created with.
    public let recordId: String

    public var kind: Kind { fields.kind }
    public var occurredAtMs: Int64 { fields.occurredAtMs }

    /// A new record of [fields], identified by their digest, or nil when any
    /// field breaks the contract.
    public init?(fields: Fields) {
        guard NativeCrashRecord.isValid(fields) else { return nil }
        let digest = SHA256.hexDigest(NativeCrashRecord.encode(fields, recordId: nil).canonicalJSON.utf8)
        self.init(fields: fields, recordId: digest)
    }

    /// Decodes a stored record exactly as the contract describes it, or
    /// returns nil: an unknown key, a wrong type, a value outside its rule, or
    /// a `recordId` that is not 64 lowercase hex digits rejects it. The id is
    /// kept as stored, not recomputed: it was fixed when the record was
    /// created, and stripping the message later does not change it.
    public init?(json: JSONValue) {
        guard let object = json.objectValue,
              object.keys.allSatisfy(NativeCrashRecord.keys.contains),
              object["recordVersion"] == .integer(NativeCrashRecord.recordVersion),
              let recordId = object["recordId"]?.stringValue,
              NativeCrashRecord.isRecordId(recordId),
              let fields = NativeCrashRecord.decodeFields(object),
              NativeCrashRecord.isValid(fields)
        else { return nil }
        self.init(fields: fields, recordId: recordId)
    }

    private init(fields: Fields, recordId: String) {
        self.fields = fields
        self.recordId = recordId
    }

    /// This record without its `exceptionMessage`, under the same id. Still
    /// valid: the message is optional.
    public func withoutExceptionMessage() -> NativeCrashRecord {
        guard fields.exceptionMessage != nil else { return self }
        var stripped = fields
        stripped.exceptionMessage = nil
        return NativeCrashRecord(fields: stripped, recordId: recordId)
    }

    /// The record as the contract's JSON, `recordId` included.
    public var json: JSONValue { NativeCrashRecord.encode(fields, recordId: recordId) }

    /// The record as a platform-channel map.
    public var channelValue: [String: Any] {
        (json.foundationObject as? [String: Any]) ?? [:]
    }

    /// Whether [value] has the shape of a record id (64 lowercase hex digits),
    /// so it can safely name a file.
    public static func isRecordId(_ value: String) -> Bool {
        Pattern.recordId(value)
    }

    // MARK: - Encoding

    static let keys: Set<String> = [
        "recordVersion", "recordId", "kind", "source", "occurredAtMs", "machException", "signal",
        "code", "terminationCode", "exceptionClass", "exceptionMessage", "durationMs",
        "bytesWritten", "images", "frames", "runId", "pid", "appVersion", "appBuild", "foreground",
    ]

    private static func encode(_ fields: Fields, recordId: String?) -> JSONValue {
        var object: [String: JSONValue] = [
            "recordVersion": .integer(recordVersion),
            "kind": .string(fields.kind.rawValue),
            "source": .string(fields.source.rawValue),
            "occurredAtMs": .integer(fields.occurredAtMs),
        ]
        if let recordId { object["recordId"] = .string(recordId) }
        object["machException"] = fields.machException.map(JSONValue.string)
        object["signal"] = fields.signal.map(JSONValue.string)
        object["code"] = fields.code.map(JSONValue.string)
        object["terminationCode"] = fields.terminationCode.map(JSONValue.string)
        object["exceptionClass"] = fields.exceptionClass.map(JSONValue.string)
        object["exceptionMessage"] = fields.exceptionMessage.map(JSONValue.string)
        object["durationMs"] = fields.durationMs.map(JSONValue.integer)
        object["bytesWritten"] = fields.bytesWritten.map(JSONValue.integer)
        if !fields.images.isEmpty {
            object["images"] = .array(fields.images.map { image in
                var entry: [String: JSONValue] = ["name": .string(image.name), "inApp": .bool(image.inApp)]
                entry["debugId"] = image.debugId.map(JSONValue.string)
                entry["arch"] = image.arch.map { .string($0.rawValue) }
                return .object(entry)
            })
        }
        if !fields.frames.isEmpty {
            object["frames"] = .array(fields.frames.map { frame in
                var entry: [String: JSONValue] = [:]
                entry["image"] = frame.image.map { .integer(Int64($0)) }
                entry["offset"] = frame.offset.map(JSONValue.integer)
                entry["symbol"] = frame.symbol.map(JSONValue.string)
                entry["line"] = frame.line.map(JSONValue.integer)
                return .object(entry)
            })
        }
        object["runId"] = fields.runId.map(JSONValue.string)
        object["pid"] = fields.pid.map(JSONValue.integer)
        object["appVersion"] = fields.appVersion.map(JSONValue.string)
        object["appBuild"] = fields.appBuild.map(JSONValue.string)
        object["foreground"] = fields.foreground.map(JSONValue.bool)
        return .object(object)
    }

    // MARK: - Decoding

    private static func decodeFields(_ object: [String: JSONValue]) -> Fields? {
        guard let kind = object["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let source = object["source"]?.stringValue.flatMap(Source.init(rawValue:)),
              let occurredAtMs = object["occurredAtMs"]?.integerValue
        else { return nil }
        var fields = Fields(kind: kind, source: source, occurredAtMs: occurredAtMs)
        do {
            fields.machException = try optionalString(object, "machException")
            fields.signal = try optionalString(object, "signal")
            fields.code = try optionalString(object, "code")
            fields.terminationCode = try optionalString(object, "terminationCode")
            fields.exceptionClass = try optionalString(object, "exceptionClass")
            fields.exceptionMessage = try optionalString(object, "exceptionMessage")
            fields.durationMs = try optionalInteger(object, "durationMs")
            fields.bytesWritten = try optionalInteger(object, "bytesWritten")
            fields.runId = try optionalString(object, "runId")
            fields.pid = try optionalInteger(object, "pid")
            fields.appVersion = try optionalString(object, "appVersion")
            fields.appBuild = try optionalString(object, "appBuild")
            if let foreground = object["foreground"] {
                guard let value = foreground.boolValue else { return nil }
                fields.foreground = value
            }
        } catch {
            return nil
        }
        if let images = object["images"] {
            guard let list = images.arrayValue, list.count <= maxImages else { return nil }
            var decoded: [Image] = []
            for entry in list {
                guard let image = decodeImage(entry) else { return nil }
                decoded.append(image)
            }
            fields.images = decoded
        }
        if let frames = object["frames"] {
            guard let list = frames.arrayValue, list.count <= maxFrames else { return nil }
            var decoded: [Frame] = []
            for entry in list {
                guard let frame = decodeFrame(entry) else { return nil }
                decoded.append(frame)
            }
            fields.frames = decoded
        }
        return fields
    }

    private static func decodeImage(_ value: JSONValue) -> Image? {
        guard let object = value.objectValue,
              object.keys.allSatisfy(["name", "debugId", "arch", "inApp"].contains),
              let name = object["name"]?.stringValue,
              let inApp = object["inApp"]?.boolValue
        else { return nil }
        var image = Image(name: name, inApp: inApp)
        if let debugId = object["debugId"] {
            guard let value = debugId.stringValue else { return nil }
            image.debugId = value
        }
        if let arch = object["arch"] {
            guard let value = arch.stringValue.flatMap(Arch.init(rawValue:)) else { return nil }
            image.arch = value
        }
        return image
    }

    private static func decodeFrame(_ value: JSONValue) -> Frame? {
        guard let object = value.objectValue,
              object.keys.allSatisfy(["image", "offset", "symbol", "line"].contains)
        else { return nil }
        var frame = Frame()
        if let image = object["image"] {
            guard let index = image.integerValue, let exact = Int(exactly: index) else { return nil }
            frame.image = exact
        }
        if let offset = object["offset"] {
            guard let value = offset.integerValue else { return nil }
            frame.offset = value
        }
        if let symbol = object["symbol"] {
            guard let value = symbol.stringValue else { return nil }
            frame.symbol = value
        }
        if let line = object["line"] {
            guard let value = line.integerValue else { return nil }
            frame.line = value
        }
        return frame
    }

    private struct WrongType: Error {}

    private static func optionalString(_ object: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let string = value.stringValue else { throw WrongType() }
        return string
    }

    private static func optionalInteger(_ object: [String: JSONValue], _ key: String) throws -> Int64? {
        guard let value = object[key] else { return nil }
        guard let integer = value.integerValue else { throw WrongType() }
        return integer
    }

    // MARK: - Rules (the contract's table, which is the protocol's schema 4)

    public static let maxImages = 32
    public static let maxFrames = 64
    public static let maxHangDurationMs: Int64 = 600_000
    /// 2^53.
    public static let maxBytesWritten: Int64 = 9_007_199_254_740_992
    /// 2^48.
    public static let maxOffset: Int64 = 281_474_976_710_656
    public static let maxLine: Int64 = 1_000_000
    public static let maxExceptionMessageUTF16 = 1024
    /// The range Dart's `DateTime.fromMillisecondsSinceEpoch` accepts.
    static let maxOccurredAtMs: Int64 = 8_640_000_000_000_000

    static func isValid(_ fields: Fields) -> Bool {
        guard fields.occurredAtMs >= 0, fields.occurredAtMs <= maxOccurredAtMs else { return false }
        if let value = fields.machException, !Pattern.machException(value) { return false }
        if let value = fields.signal, !Pattern.signal(value) { return false }
        if let value = fields.code, !Pattern.hexCode(value) { return false }
        if let value = fields.terminationCode, !Pattern.hexCode(value) { return false }
        if let value = fields.exceptionClass, !Pattern.exceptionClass(value) { return false }
        if let value = fields.exceptionMessage {
            guard !value.isEmpty, value.utf16.count <= maxExceptionMessageUTF16 else { return false }
        }
        if let value = fields.durationMs {
            guard fields.kind == .hang, value >= 0, value <= maxHangDurationMs else { return false }
        }
        if let value = fields.bytesWritten {
            guard fields.kind == .diskWriteException, value >= 0, value <= maxBytesWritten else { return false }
        }
        guard fields.images.count <= maxImages, fields.frames.count <= maxFrames else { return false }
        for image in fields.images {
            guard Pattern.imageName(image.name) else { return false }
            if let debugId = image.debugId, !Pattern.debugId(debugId) { return false }
        }
        var referenced = Set<Int>()
        for frame in fields.frames {
            guard (frame.image == nil) == (frame.offset == nil) else { return false }
            if let symbol = frame.symbol, !Pattern.symbol(symbol) { return false }
            if let line = frame.line {
                guard line >= 1, line <= maxLine, frame.symbol != nil, frame.image == nil else { return false }
            }
            if let image = frame.image, let offset = frame.offset {
                guard image >= 0, image < fields.images.count, offset >= 0, offset <= maxOffset else {
                    return false
                }
                referenced.insert(image)
            }
        }
        guard referenced.count == fields.images.count else { return false }
        if let value = fields.runId, !Pattern.runId(value) { return false }
        if let value = fields.pid, value < 0 { return false }
        if let value = fields.appVersion, value.isEmpty { return false }
        if let value = fields.appBuild, value.isEmpty { return false }
        return true
    }
}

/// The contract's value patterns, checked on ASCII without regular
/// expressions.
enum Pattern {
    static func machException(_ value: String) -> Bool {
        guard value.hasPrefix("EXC_") else { return false }
        let rest = value.utf8.dropFirst(4)
        return (1...30).contains(rest.count) && rest.allSatisfy { isUpper($0) || $0 == underscore }
    }

    static func signal(_ value: String) -> Bool {
        guard value.hasPrefix("SIG") else { return false }
        let rest = value.utf8.dropFirst(3)
        return (2...8).contains(rest.count) && rest.allSatisfy { isUpper($0) || isDigit($0) }
    }

    static func hexCode(_ value: String) -> Bool {
        guard value.hasPrefix("0x") else { return false }
        let rest = value.utf8.dropFirst(2)
        return (1...16).contains(rest.count) && rest.allSatisfy(isLowerHex)
    }

    static func exceptionClass(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...160).contains(bytes.count) && bytes.allSatisfy(isExceptionClassByte)
    }

    static func imageName(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...100).contains(bytes.count) && bytes.allSatisfy(isImageNameByte)
    }

    static func debugId(_ value: String) -> Bool {
        let bytes = value.utf8
        return (32...40).contains(bytes.count) && bytes.allSatisfy(isLowerHex)
    }

    static func symbol(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1...200).contains(bytes.count) && bytes.allSatisfy(isSymbolByte)
    }

    static func runId(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 32 && bytes.allSatisfy(isLowerHex)
    }

    static func recordId(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy(isLowerHex)
    }

    // MARK: Byte classes

    static let underscore = UInt8(ascii: "_")

    static func isUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
    static func isLower(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }
    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    static func isAlphanumeric(_ byte: UInt8) -> Bool { isUpper(byte) || isLower(byte) || isDigit(byte) }
    static func isLowerHex(_ byte: UInt8) -> Bool { isDigit(byte) || (byte >= 0x61 && byte <= 0x66) }

    /// `[A-Za-z0-9_.+-]`
    static func isImageNameByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == underscore || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
    }

    /// `[A-Za-z0-9_$.]`
    static func isExceptionClassByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == underscore || byte == UInt8(ascii: "$") || byte == UInt8(ascii: ".")
    }

    /// `[A-Za-z0-9_$.<>:~]`
    static func isSymbolByte(_ byte: UInt8) -> Bool {
        isExceptionClassByte(byte) || byte == UInt8(ascii: "<") || byte == UInt8(ascii: ">")
            || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "~")
    }
}
