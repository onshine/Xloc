// Xloc — MachOInjector.swift
// 往 Mach-O 头部空白处插入一条 LC_LOAD_DYLIB。
//
// 只做这一件事，不改代码、不移动任何 section。
// 前提：header + load commands 之后到第一个 section 之间有空隙（几乎所有 App 都有）。
//
// 插入后原有签名失效 —— 所以产物必须交给 TrollStore 重新签名安装，
// 这也是为什么 Xloc 走「生成 .tipa → TrollStore 覆盖安装」的路线。

import Foundation

enum MachOError: LocalizedError {
    case notMachO
    case fatBinary
    case noSpace(need: Int, have: Int)
    case alreadyInjected
    case badExecutable

    var errorDescription: String? {
        switch self {
        case .notMachO: return "不是有效的 Mach-O"
        case .fatBinary: return "暂不支持 fat 二进制"
        case .noSpace(let need, let have):
            return "头部空间不足（需要 \(need) 字节，只有 \(have) 字节）"
        case .alreadyInjected: return "已经注入过了"
        case .badExecutable: return "找不到可执行文件"
        }
    }
}

enum MachOInjector {

    static let lcLoadDylib: UInt32 = 0xC

    /// 在 url 指向的 Mach-O 里插入 `@executable_path/<name>` 的加载命令
    @discardableResult
    static func insertDylib(at url: URL, path: String) throws -> Bool {
        var data = try Data(contentsOf: url)
        guard data.count > 32 else { throw MachOError.notMachO }

        let magic = data.leU32(0)
        guard magic == 0xFEEDFACF else {
            if magic == 0xCAFEBABE || magic == 0xCAFEBABF { throw MachOError.fatBinary }
            throw MachOError.notMachO
        }

        let ncmds = data.leU32(16)
        let sizeofcmds = data.leU32(20)
        let headerSize = 32
        let cmdsEnd = headerSize + Int(sizeofcmds)

        // 遍历 load command：找最小 section 偏移（内容起点）和已有 dylib
        var contentStart = data.count
        var offset = headerSize
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= data.count else { break }
            let cmd = data.leU32(offset)
            let size = Int(data.leU32(offset + 4))
            guard size >= 8, offset + size <= data.count else { break }

            if cmd == lcLoadDylib {
                let nameOff = Int(data.leU32(offset + 8))
                let start = offset + nameOff
                if start < offset + size,
                   let name = String(data: data[start..<(offset + size)], encoding: .utf8)?
                    .split(separator: "\0").first.map(String.init),
                   name == "@executable_path/\(path)" {
                    throw MachOError.alreadyInjected
                }
            }

            // LC_SEGMENT_64：取 section 的最小 file offset
            if cmd == 0x19, size >= 72 {
                let nsects = Int(data.leU32(offset + 64))
                var s = offset + 72
                for _ in 0..<nsects {
                    guard s + 80 <= data.count else { break }
                    let secOffset = Int(data.leU32(s + 48))
                    if secOffset > 0 { contentStart = min(contentStart, secOffset) }
                    s += 80
                }
            }
            offset += size
        }

        // 构造 LC_LOAD_DYLIB
        let pathBytes = Array("@executable_path/\(path)".utf8) + [0]
        let rawSize = 24 + pathBytes.count
        let cmdsize = (rawSize + 7) & ~7
        let available = contentStart - cmdsEnd
        guard available >= cmdsize else {
            throw MachOError.noSpace(need: cmdsize, have: max(0, available))
        }

        var cmd = Data(count: cmdsize)
        cmd.writeLE32(lcLoadDylib, at: 0)
        cmd.writeLE32(UInt32(cmdsize), at: 4)
        cmd.writeLE32(24, at: 8)          // name.offset
        cmd.writeLE32(2, at: 12)          // timestamp
        cmd.writeLE32(0x00010000, at: 16) // current_version
        cmd.writeLE32(0x00010000, at: 20) // compatibility_version
        for (i, b) in pathBytes.enumerated() { cmd[24 + i] = b }

        data.replaceSubrange(cmdsEnd..<(cmdsEnd + cmdsize), with: cmd)
        data.writeLE32(ncmds + 1, at: 16)
        data.writeLE32(sizeofcmds + UInt32(cmdsize), at: 20)

        try data.write(to: url, options: .atomic)
        return true
    }
}

// MARK: - Data 小工具

extension Data {
    func leU32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        }
    }

    mutating func writeLE32(_ value: UInt32, at offset: Int) {
        guard offset + 4 <= count else { return }
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
