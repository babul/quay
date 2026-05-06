import Foundation

/// Heap-allocated byte buffer that zeros itself on `dealloc`.
///
/// `Data` doesn't guarantee zeroing on free, and Swift's `Array` may copy
/// on assignment. This wrapper owns its own buffer and exposes
/// `withUnsafeBytes` for callers that want to consume plaintext.
final class SensitiveBytes: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer

    var count: Int { buffer.count }

    init(count: Int) {
        self.buffer = .allocate(byteCount: count, alignment: 1)
    }

    init(_ data: Data) {
        self.buffer = .allocate(byteCount: data.count, alignment: 1)
        _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
    }

    deinit {
        // memset_s is the POSIX-blessed "compiler may not optimize away"
        // zeroing primitive on Darwin.
        if buffer.count > 0, let base = buffer.baseAddress {
            memset_s(base, buffer.count, 0, buffer.count)
        }
        buffer.deallocate()
    }

    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try body(UnsafeRawBufferPointer(buffer))
    }

    /// Convenience: the bytes as a `Data` snapshot. Caller is responsible
    /// for not retaining the resulting `Data` longer than needed.
    func unsafeData() -> Data {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return Data() }
        return Data(bytes: base, count: buffer.count)
    }

    /// Convenience: UTF-8 decode. Returns `nil` if the bytes aren't valid
    /// UTF-8. The caller still owns the returned `String` lifetime.
    func unsafeUTF8String() -> String? {
        String(data: unsafeData(), encoding: .utf8)
    }
}
