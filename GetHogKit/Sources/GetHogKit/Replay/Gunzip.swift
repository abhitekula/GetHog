import Compression
import Foundation

/// Minimal gzip reader.
///
/// Apple's Compression framework speaks raw DEFLATE (`COMPRESSION_ZLIB`) but has
/// no gzip container support, so the header and trailer are parsed here.
public enum Gunzip {

    public static func isGzip(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    public static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18,
              bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08
        else { return nil }

        let flags = bytes[3]
        var offset = 10

        // Optional header fields, in the order RFC 1952 defines them. Assuming a
        // fixed 10-byte header silently corrupts any stream that carries them.
        if flags & 0x04 != 0 {                                  // FEXTRA
            guard offset + 1 < bytes.count else { return nil }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {                                  // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {                                  // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }                    // FHCRC

        let trailerSize = 8
        guard offset < bytes.count - trailerSize else { return nil }

        // ISIZE (mod 2^32) sizes the output buffer; padded generously because a
        // payload larger than 4 GiB would wrap it.
        let isize = bytes[(bytes.count - 4)...].reversed().reduce(0) { ($0 << 8) | Int($1) }
        let capacity = max(isize, (bytes.count - offset) * 8, 64 * 1024)

        let deflated = Data(bytes[offset..<(bytes.count - trailerSize)])
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { dst -> Int in
            deflated.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

extension String {
    /// Reinterprets a string whose scalars are all < 256 as the raw bytes it
    /// stands for.
    ///
    /// PostHog embeds binary snapshot payloads in JSON by treating each byte as a
    /// latin-1 character, so recovering the bytes means undoing exactly that —
    /// UTF-8 encoding the string instead would corrupt every byte above 0x7F.
    var latin1Bytes: Data? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(unicodeScalars.count)
        for scalar in unicodeScalars {
            guard scalar.value < 256 else { return nil }
            bytes.append(UInt8(scalar.value))
        }
        return Data(bytes)
    }
}
