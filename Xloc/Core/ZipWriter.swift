// Xloc — ZipWriter.swift
// 最小 ZIP 写入器（仅 store，不压缩）。
// 生成 .tipa 用：结构就是 Payload/<App>.app/...

import Foundation

enum ZipError: LocalizedError {
    case empty
    case io(String)
    var errorDescription: String? {
        switch self {
        case .empty: return "没有可打包的文件"
        case .io(let s): return "写入失败：\(s)"
        }
    }
}

enum ZipWriter {

    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    /// 把 folder 里的内容打包成 zip（保留相对路径）
    static func zip(folder: URL, to output: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: []) else {
            throw ZipError.empty
        }

        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let rel = url.path.replacingOccurrences(of: folder.path + "/", with: "")
            files.append((url, rel))
        }
        guard !files.isEmpty else { throw ZipError.empty }
        files.sort { $0.1 < $1.1 }

        var body = Data()
        var central = Data()
        var entries: [Entry] = []

        for (url, rel) in files {
            let data = try Data(contentsOf: url)
            let name = Array(rel.utf8)
            let crc = crc32(data)
            let offset = UInt32(body.count)

            // local file header
            var h = Data()
            h.appendLE32(0x04034b50)
            h.appendLE16(20)              // version needed
            h.appendLE16(0x0800)          // UTF-8 flag
            h.appendLE16(0)               // method: store
            h.appendLE16(0)               // time
            h.appendLE16(0x21)            // date (1980-01-01)
            h.appendLE32(crc)
            h.appendLE32(UInt32(data.count))
            h.appendLE32(UInt32(data.count))
            h.appendLE16(UInt16(name.count))
            h.appendLE16(0)               // extra len
            h.append(contentsOf: name)

            body.append(h)
            body.append(data)

            entries.append(Entry(name: name, crc: crc, size: UInt32(data.count), offset: offset))
        }

        let cdStart = UInt32(body.count)
        for e in entries {
            var c = Data()
            c.appendLE32(0x02014b50)
            c.appendLE16(20)              // version made by
            c.appendLE16(20)              // version needed
            c.appendLE16(0x0800)
            c.appendLE16(0)
            c.appendLE16(0)
            c.appendLE16(0x21)
            c.appendLE32(e.crc)
            c.appendLE32(e.size)
            c.appendLE32(e.size)
            c.appendLE16(UInt16(e.name.count))
            c.appendLE16(0)               // extra
            c.appendLE16(0)               // comment
            c.appendLE16(0)               // disk
            c.appendLE16(0)               // internal attrs
            c.appendLE32(0)               // external attrs
            c.appendLE32(e.offset)
            c.append(contentsOf: e.name)
            central.append(c)
        }

        var end = Data()
        end.appendLE32(0x06054b50)
        end.appendLE16(0)
        end.appendLE16(0)
        end.appendLE16(UInt16(entries.count))
        end.appendLE16(UInt16(entries.count))
        end.appendLE32(UInt32(central.count))
        end.appendLE32(cdStart)
        end.appendLE16(0)

        var out = Data()
        out.append(body)
        out.append(central)
        out.append(end)

        try? FileManager.default.removeItem(at: output)
        try out.write(to: output, options: .atomic)
    }

    // MARK: - CRC32

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
