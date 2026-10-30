import XCTest

@testable import NativeCrashNormalizer

/// FIPS 180-4 / NIST test vectors.
final class SHA256Tests: XCTestCase {
    func testEmptyMessage() {
        XCTAssertEqual(
            SHA256.hexDigest([UInt8]()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testOneBlockMessage() {
        XCTAssertEqual(
            SHA256.hexDigest("abc".utf8),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testTwoBlockMessage() {
        XCTAssertEqual(
            SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testFourBlockMessage() {
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
            + "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        XCTAssertEqual(
            SHA256.hexDigest(message.utf8),
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
    }

    func testPaddingBoundaries() {
        // 55 bytes fit one block with the length; 56 and 64 need a second.
        XCTAssertEqual(
            SHA256.hexDigest([UInt8](repeating: 0x61, count: 55)),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
        )
        XCTAssertEqual(
            SHA256.hexDigest([UInt8](repeating: 0x61, count: 56)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        )
        XCTAssertEqual(
            SHA256.hexDigest([UInt8](repeating: 0x61, count: 64)),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        )
    }

    func testOneMillionTimesA() {
        XCTAssertEqual(
            SHA256.hexDigest([UInt8](repeating: 0x61, count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testDigestIsThirtyTwoBytes() {
        XCTAssertEqual(SHA256.digest("abc".utf8).count, 32)
    }
}
