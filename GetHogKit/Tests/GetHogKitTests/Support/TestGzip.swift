import Compression
import Foundation

/// Builds real gzip streams so the decompressor is tested against the format
/// rather than against its own assumptions.
enum TestGzip {
    static func compress(_ data: Data, fileName: String? = nil) -> Data? {
        let deflated = rawDeflate(data)
        guard !deflated.isEmpty else { return nil }

        var out = Data([0x1f, 0x8b, 0x08])
        out.append(fileName == nil ? 0x00 : 0x08)          // FLG: FNAME
        out.append(contentsOf: [0, 0, 0, 0])               // MTIME
        out.append(contentsOf: [0x00, 0x03])               // XFL, OS

        if let fileName {
            out.append(contentsOf: Array(fileName.utf8))
            out.append(0x00)
        }

        out.append(deflated)
        out.append(contentsOf: withUnsafeBytes(of: crc32(data).littleEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(data.count).littleEndian, Array.init))
        return out
    }

    private static func rawDeflate(_ data: Data) -> Data {
        let capacity = max(data.count * 2, 1024)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written > 0 ? out.prefix(written) : Data()
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
