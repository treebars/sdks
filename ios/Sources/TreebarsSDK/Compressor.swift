import Foundation
import Compression

/// Body compression for uploads.
///
/// Apple's `COMPRESSION_ZLIB` is misleadingly named: it emits a *raw* DEFLATE stream with
/// no container at all, neither the zlib header this constant's name suggests nor the
/// gzip one. HTTP's `deflate` content coding means RFC 1950 zlib framing and `gzip`
/// means RFC 1952, so a bare DEFLATE payload is correct under neither name.
///
/// Getting this wrong loses events rather than delaying them: a body the server cannot
/// decode is refused as malformed, and the uploader drops a batch the server calls
/// malformed rather than retrying it, because it would never succeed.
///
/// So the raw output is wrapped in the two-byte zlib header and four-byte Adler-32
/// trailer that RFC 1950 requires, and declared as `deflate`. zlib rather than gzip
/// because its checksum is four lines of arithmetic where gzip's CRC-32 needs a table.
enum Compressor {
    /// The value to send in `Content-Encoding` for anything `compress` returns.
    static let contentEncoding = "deflate"

    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        let deflated: Data? = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }

            // Incompressible input can expand slightly, so the destination has headroom
            // rather than being sized exactly to the source.
            let capacity = data.count + 512
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dstBuffer.deallocate() }

            let size = compression_encode_buffer(
                dstBuffer, capacity,
                srcBase, data.count,
                nil, COMPRESSION_ZLIB
            )
            guard size > 0 else { return nil }
            return Data(bytes: dstBuffer, count: size)
        }

        guard let deflated else { return nil }

        // 0x78 0x9C: 32K window, deflate method, default compression, no preset dictionary.
        var out = Data([0x78, 0x9C])
        out.append(deflated)

        let checksum = adler32(data)
        out.append(contentsOf: [
            UInt8((checksum >> 24) & 0xFF),
            UInt8((checksum >> 16) & 0xFF),
            UInt8((checksum >> 8) & 0xFF),
            UInt8(checksum & 0xFF),
        ])
        return out
    }

    /// Adler-32 over the *uncompressed* bytes, as RFC 1950 requires.
    private static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0

        for byte in data {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}
