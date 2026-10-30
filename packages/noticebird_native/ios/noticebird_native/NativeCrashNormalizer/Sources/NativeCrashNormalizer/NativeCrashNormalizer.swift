import Foundation

/// Which MetricKit diagnostic a JSON representation came from.
public enum DiagnosticKind: String, CaseIterable, Sendable {
    /// `MXCrashDiagnostic`
    case crash
    /// `MXHangDiagnostic`
    case hang
    /// `MXDiskWriteExceptionDiagnostic`
    case diskWriteException
}

/// What the normalizer needs besides the diagnostic's JSON. The typed values
/// come from the MetricKit objects: the JSON spells durations and byte
/// counts as locale-formatted text ("3,2 sec", "4,33 GB").
public struct NormalizationContext: Sendable {
    public var kind: DiagnosticKind
    /// The payload's `timeStampBegin`, in milliseconds since the epoch.
    public var occurredAtMs: Int64
    /// The file names of the binaries that ship in the app bundle: the main
    /// executable and every binary in its `Frameworks/` directory.
    public var inAppBinaryNames: Set<String>
    /// The privacy profile is `regulatedStrict`: no exception message.
    public var strict: Bool
    /// `MXHangDiagnostic.hangDuration` in milliseconds.
    public var hangDurationMs: Double?
    /// `MXDiskWriteExceptionDiagnostic.totalWritesCaused` in bytes.
    public var bytesWritten: Double?

    public init(
        kind: DiagnosticKind,
        occurredAtMs: Int64,
        inAppBinaryNames: Set<String>,
        strict: Bool,
        hangDurationMs: Double? = nil,
        bytesWritten: Double? = nil
    ) {
        self.kind = kind
        self.occurredAtMs = occurredAtMs
        self.inAppBinaryNames = inAppBinaryNames
        self.strict = strict
        self.hangDurationMs = hangDurationMs
        self.bytesWritten = bytesWritten
    }
}

/// Turns one MetricKit diagnostic's `jsonRepresentation()` into a contract
/// record, keeping only the allowlisted fields (the native contract, "iOS").
///
/// It trusts nothing in the input: every value is type-checked, every walk is
/// iterative and bounded, and whatever does not fit the contract is dropped.
/// Frame addresses are never read.
public enum NativeCrashNormalizer {
    /// The record for [diagnosticJSON], or nil when the input is not a JSON
    /// object or the context cannot make a valid record.
    public static func normalize(_ diagnosticJSON: Data, context: NormalizationContext) -> NativeCrashRecord? {
        guard let document = JSONDocument.parse(diagnosticJSON, limits: .diagnostic),
              let root = document.object(document.root)
        else { return nil }
        let metaData = document.object(root["diagnosticMetaData"]) ?? [:]

        var fields = NativeCrashRecord.Fields(kind: .crash, source: .metricKit, occurredAtMs: context.occurredAtMs)
        switch context.kind {
        case .crash:
            readCrash(document, root: root, metaData: metaData, strict: context.strict, into: &fields)
        case .hang:
            fields.kind = .hang
            fields.durationMs = boundedInteger(context.hangDurationMs, max: NativeCrashRecord.maxHangDurationMs)
        case .diskWriteException:
            fields.kind = .diskWriteException
            fields.bytesWritten = boundedInteger(context.bytesWritten, max: NativeCrashRecord.maxBytesWritten)
        }

        fields.appVersion = document.string(metaData["appVersion"]).flatMap(Sanitize.metadataValue)
        fields.appBuild = document.string(metaData["appBuildVersion"]).flatMap(Sanitize.metadataValue)
        if let pid = document.integer(metaData["pid"]), pid > 0, pid <= Int64(Int32.max) {
            fields.pid = pid
        }

        let reader = CallStackTreeReader(
            document: document,
            inAppNames: Set(context.inAppBinaryNames.compactMap(Sanitize.imageName)),
            deviceArch: document.string(metaData["platformArchitecture"])
                .flatMap(NativeCrashRecord.Arch.init(rawValue:))
        )
        (fields.images, fields.frames) = reader.attributedFrames(root["callStackTree"])
        return NativeCrashRecord(fields: fields)
    }

    private static func readCrash(
        _ document: JSONDocument,
        root: [String: Int],
        metaData: [String: Int],
        strict: Bool,
        into fields: inout NativeCrashRecord.Fields
    ) {
        if let type = document.integer(metaData["exceptionType"]) {
            fields.machException = DarwinTables.machExceptions[type]
        }
        if let signal = document.integer(metaData["signal"]) {
            fields.signal = DarwinTables.signals[signal]
        }
        if let code = document.unsignedBitPattern(metaData["exceptionCode"]) {
            fields.code = "0x" + String(code, radix: 16)
        }
        fields.terminationCode = document.string(metaData["terminationReason"]).flatMap(Sanitize.terminationCode)
        if fields.terminationCode == DarwinTables.watchdogTerminationCode {
            fields.kind = .watchdogKill
        }
        // iOS 17+. Read where the metadata keeps it, and beside it.
        let reason = document.object(metaData["objectiveCexceptionReason"])
            ?? document.object(root["objectiveCexceptionReason"])
        if let reason {
            fields.exceptionClass = document.string(reason["exceptionName"]).flatMap(Sanitize.exceptionClass)
                ?? document.string(reason["exceptionType"]).flatMap(Sanitize.exceptionClass)
            if !strict {
                fields.exceptionMessage = document.string(reason["composedMessage"]).flatMap(Sanitize.exceptionMessage)
            }
        }
    }

    /// A non-negative, finite measurement rounded to an integer and capped at
    /// [max] (a hang longer than the cap lasted at least the cap).
    static func boundedInteger(_ value: Double?, max: Int64) -> Int64? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return Int64(Swift.min(value.rounded(), Double(max)))
    }
}

/// Reads the attributed thread's frames out of an `MXCallStackTree`.
///
/// - A per-thread tree (`callStackPerThread: true`, crashes) holds one chain
///   per thread: the root frame is the top of the stack and `subFrames[0]` its
///   caller.
/// - An aggregated tree (`callStackPerThread: false`) merges samples: the
///   roots are the outermost frames and `subFrames` their callees, each with
///   a `sampleCount`. The heaviest path from the heaviest root down to a leaf
///   is the stack most samples saw; it is reversed so the top comes first.
struct CallStackTreeReader {
    let document: JSONDocument
    let inAppNames: Set<String>
    let deviceArch: NativeCrashRecord.Arch?

    /// The longest path followed down an aggregated tree.
    static let maxAggregatedDepth = 4096

    private struct ImageKey: Hashable {
        let name: String
        let debugId: String?
    }

    func attributedFrames(_ treeIndex: Int?) -> ([NativeCrashRecord.Image], [NativeCrashRecord.Frame]) {
        guard let tree = document.object(treeIndex),
              let perThread = document.bool(tree["callStackPerThread"]),
              let stacks = document.array(tree["callStacks"])
        else { return ([], []) }
        // The attributed thread only. An aggregated tree of a single call
        // stack need not mark it: that one stack is the diagnosed one.
        let attributed = stacks.first { document.bool(document.object($0)?["threadAttributed"]) == true }
            ?? (!perThread && stacks.count == 1 ? stacks.first : nil)
        guard let stack = document.object(attributed),
              let roots = document.array(stack["callStackRootFrames"]),
              let firstRoot = roots.first
        else { return ([], []) }
        return build(perThread ? chain(from: firstRoot) : heaviestPath(roots))
    }

    /// The per-thread chain, top first, at most a record's worth of frames.
    private func chain(from start: Int) -> [Int] {
        var path: [Int] = []
        var current: Int? = start
        while let index = current, path.count < NativeCrashRecord.maxFrames, let frame = document.object(index) {
            path.append(index)
            current = document.array(frame["subFrames"])?.first
        }
        return path
    }

    private enum Step {
        case frame(Int)
        case leaf
        /// Part of the tree lies beyond what the parser kept: the leaf, and
        /// so the top of the stack, is unknown.
        case unknown
    }

    /// The heaviest path, top first; empty when its leaf cannot be reached.
    private func heaviestPath(_ roots: [Int]) -> [Int] {
        var path: [Int] = []
        var candidates = roots
        while true {
            switch heaviest(candidates) {
            case .unknown:
                return []
            case .leaf:
                return Array(path.reversed().prefix(NativeCrashRecord.maxFrames))
            case .frame(let index):
                guard path.count < Self.maxAggregatedDepth else { return [] }
                path.append(index)
                let subFrames = document.object(index)?["subFrames"]
                if document.isTruncated(subFrames) { return [] }
                candidates = document.array(subFrames) ?? []
            }
        }
    }

    private func heaviest(_ candidates: [Int]) -> Step {
        var best: Int?
        var bestCount: Int64 = -1
        for candidate in candidates {
            if document.isTruncated(candidate) { return .unknown }
            guard let frame = document.object(candidate) else { continue }
            let count = document.integer(frame["sampleCount"]) ?? 0
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        return best.map(Step.frame) ?? .leaf
    }

    /// Frames and the images they reference, deduplicated and indexed in the
    /// order frames first reference them.
    private func build(_ path: [Int]) -> ([NativeCrashRecord.Image], [NativeCrashRecord.Frame]) {
        var images: [NativeCrashRecord.Image] = []
        var positions: [ImageKey: Int] = [:]
        var frames: [NativeCrashRecord.Frame] = []
        for index in path {
            guard frames.count < NativeCrashRecord.maxFrames else { break }
            guard let frame = document.object(index),
                  let name = document.string(frame["binaryName"]).flatMap(Sanitize.imageName),
                  let uuid = document.string(frame["binaryUUID"]), !Sanitize.isNullUUID(uuid),
                  let offset = document.integer(frame["offsetIntoBinaryTextSegment"]),
                  offset >= 0, offset <= NativeCrashRecord.maxOffset
            else {
                frames.append(.unknown)
                continue
            }
            let debugId = Sanitize.debugId(uuid)
            let key = ImageKey(name: name, debugId: debugId)
            let position: Int
            if let known = positions[key] {
                position = known
            } else {
                // A frame whose image no longer fits ends the stack: the
                // frames kept stay a true prefix of it.
                guard images.count < NativeCrashRecord.maxImages else { break }
                let inApp = inAppNames.contains(name)
                images.append(NativeCrashRecord.Image(name: name, debugId: debugId, arch: arch(inApp: inApp), inApp: inApp))
                position = images.count - 1
                positions[key] = position
            }
            frames.append(.inImage(position, offset: offset))
        }
        return (images, frames)
    }

    /// MetricKit names one architecture for the whole diagnostic: the
    /// device's. On an arm64e device the system's own binaries are arm64e, but
    /// the app's binaries may be arm64 or arm64e, so theirs is unknown there.
    private func arch(inApp: Bool) -> NativeCrashRecord.Arch? {
        deviceArch == .arm64e && inApp ? nil : deviceArch
    }
}

/// Fitting report values to the contract's patterns.
enum Sanitize {
    /// The basename of [raw] (after the last `/`, and after the last `!` of an
    /// `apk!lib.so` path), other characters replaced by `_`, cut to 100.
    static func imageName(_ raw: String) -> String? {
        var base = Substring(raw)
        if let slash = base.lastIndex(of: "/") { base = base[base.index(after: slash)...] }
        if let bang = base.lastIndex(of: "!") { base = base[base.index(after: bang)...] }
        return replacingDisallowed(base, limit: 100, allowed: Pattern.isImageNameByte)
    }

    /// An exception name fitted to `[A-Za-z0-9_$.]{1,160}`.
    static func exceptionClass(_ raw: String) -> String? {
        replacingDisallowed(Substring(raw), limit: 160, allowed: Pattern.isExceptionClassByte)
    }

    private static func replacingDisallowed(
        _ raw: Substring,
        limit: Int,
        allowed: (UInt8) -> Bool
    ) -> String? {
        var result = ""
        var count = 0
        for character in raw {
            guard count < limit else { break }
            if character.unicodeScalars.count == 1, let byte = character.asciiValue, allowed(byte) {
                result.append(character)
            } else {
                result.append("_")
            }
            count += 1
        }
        return result.isEmpty ? nil : result
    }

    /// At most 1024 UTF-16 code units (Dart's `String.length`), cut between
    /// characters.
    static func exceptionMessage(_ raw: String) -> String? {
        var result = ""
        var units = 0
        for character in raw {
            let size = character.utf16.count
            guard units + size <= NativeCrashRecord.maxExceptionMessageUTF16 else { break }
            result.append(character)
            units += size
        }
        return result.isEmpty ? nil : result
    }

    /// A version or build string as the report names it, when it is sane.
    static func metadataValue(_ raw: String) -> String? {
        raw.isEmpty || raw.utf16.count > 128 ? nil : raw
    }

    /// `binaryUUID` as a debug id: lowercase, no dashes, 32 to 40 hex digits.
    static func debugId(_ uuid: String) -> String? {
        let hex = uuid.lowercased().filter { $0 != "-" }
        return Pattern.debugId(hex) ? hex : nil
    }

    /// An empty or all-zero UUID names no binary.
    static func isNullUUID(_ uuid: String) -> Bool {
        let hex = uuid.filter { $0 != "-" }
        return hex.allSatisfy { $0 == "0" }
    }

    /// The code of a termination reason (`Namespace FRONTBOARD, Code
    /// 0x8badf00d`, or the same code in decimal) as lowercase hex.
    static func terminationCode(_ reason: String) -> String? {
        let bytes = Array(reason.utf8.prefix(4096))
        let marker = Array("Code ".utf8)
        guard bytes.count >= marker.count else { return nil }
        var start: Int?
        for position in 0...(bytes.count - marker.count) where bytes[position..<(position + marker.count)].elementsEqual(marker) {
            start = position + marker.count
            break
        }
        guard var index = start else { return nil }
        let hex = index + 1 < bytes.count && bytes[index] == UInt8(ascii: "0")
            && (bytes[index + 1] == UInt8(ascii: "x") || bytes[index + 1] == UInt8(ascii: "X"))
        if hex { index += 2 }
        let digitsStart = index
        while index < bytes.count, hex ? isHexDigit(bytes[index]) : Pattern.isDigit(bytes[index]) {
            index += 1
        }
        // The number must end where the word ends.
        if index < bytes.count, Pattern.isAlphanumeric(bytes[index]) || bytes[index] == Pattern.underscore {
            return nil
        }
        let digits = String(decoding: bytes[digitsStart..<index], as: UTF8.self)
        guard !digits.isEmpty, digits.count <= (hex ? 16 : 20),
              let value = UInt64(digits, radix: hex ? 16 : 10)
        else { return nil }
        return "0x" + String(value, radix: 16)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        Pattern.isDigit(byte) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
    }
}
