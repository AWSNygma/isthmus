import Foundation

/// Minimal read-only Portable Executable parser: imported DLL names and
/// the primary icon group. Enough to choose a graphics backend and to give
/// shortcuts a real icon, without shelling out to Wine.
public struct PEFile: Sendable {
    public enum Machine: Sendable, Equatable { case i386, x86_64, arm64, other(UInt16) }

    public let machine: Machine
    public let imports: [String]
    private let data: Data
    private let sections: [Section]
    private let resourceRVA: UInt32

    private struct Section { var va: UInt32; var vsize: UInt32; var rawSize: UInt32; var rawPtr: UInt32 }

    public init(url: URL) throws {
        // Executables can be huge (multi-GB with packed assets); headers and
        // resources live near the start in practice, but map lazily to be safe.
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count > 0x40, data.u16(0) == 0x5A4D else { throw PEError.notPE }
        let pe = Int(data.u32(0x3C))
        guard pe + 24 < data.count, data.u32(pe) == 0x0000_4550 else { throw PEError.notPE }
        let coff = pe + 4
        switch data.u16(coff) {
        case 0x14C: machine = .i386
        case 0x8664: machine = .x86_64
        case 0xAA64: machine = .arm64
        case let m: machine = .other(m)
        }
        let nSections = min(Int(data.u16(coff + 2)), 96)
        let optSize = Int(data.u16(coff + 16))
        let opt = coff + 20
        let magic = data.u16(opt)
        let ddBase = opt + (magic == 0x20B ? 112 : 96)
        let nDirs = Int(data.u32(opt + (magic == 0x20B ? 108 : 92)))
        func dir(_ i: Int) -> (rva: UInt32, size: UInt32) {
            guard i < nDirs, ddBase + i * 8 + 8 <= data.count else { return (0, 0) }
            return (data.u32(ddBase + i * 8), data.u32(ddBase + i * 8 + 4))
        }
        var secs: [Section] = []
        let secBase = opt + optSize
        for i in 0..<nSections {
            let s = secBase + i * 40
            guard s + 40 <= data.count else { break }
            secs.append(Section(va: data.u32(s + 12), vsize: data.u32(s + 8), rawSize: data.u32(s + 16), rawPtr: data.u32(s + 20)))
        }
        sections = secs
        resourceRVA = dir(2).rva

        func offset(_ rva: UInt32) -> Int? { PEFile.fileOffset(rva, sections: secs, count: data.count) }
        func cString(_ rva: UInt32) -> String? {
            guard let o = offset(rva) else { return nil }
            var end = o
            while end < data.count, data[data.startIndex + end] != 0, end - o < 256 { end += 1 }
            return String(data: data.subdata(in: data.startIndex + o ..< data.startIndex + end), encoding: .ascii)
        }

        var names: [String] = []
        if let start = offset(dir(1).rva), dir(1).rva != 0 {
            var d = start
            while d + 20 <= data.count {
                let nameRVA = data.u32(d + 12)
                if nameRVA == 0 && data.u32(d) == 0 { break }
                if let n = cString(nameRVA) { names.append(n) }
                d += 20
                if names.count > 512 { break }
            }
        }
        if let start = offset(dir(13).rva), dir(13).rva != 0 {
            var d = start
            while d + 32 <= data.count {
                let nameRVA = data.u32(d + 4)
                if nameRVA == 0 { break }
                if let n = cString(nameRVA) { names.append(n) }
                d += 32
                if names.count > 1024 { break }
            }
        }
        imports = names
    }

    /// DirectX level from the import table; when that's inconclusive
    /// (engines often `LoadLibrary` their renderer), fall back to looking for
    /// the DLL names as ASCII or UTF-16 strings in the binary.
    public var directXLevel: DirectXLevel {
        let fromImports = DirectXLevel(imports: imports)
        if fromImports != .unknown { return fromImports }
        let has12 = mentions("d3d12.dll"), has11 = mentions("d3d11.dll")
        if has12 && !has11 { return .d3d12 }
        if has11 { return .d3d11 }
        if mentions("d3d9.dll") { return .d3d9 }
        return .unknown
    }

    /// Case-insensitive search for an ASCII string, stored as ASCII or UTF-16LE.
    /// Bounded to the first 256 MB so huge packed executables stay fast.
    public func mentions(_ needle: String) -> Bool {
        let limit = min(data.count, 256 << 20)
        let lower = Array(needle.lowercased().utf8), upper = Array(needle.uppercased().utf8)
        guard !lower.isEmpty, limit > lower.count * 2 else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            let n = lower.count
            var i = 0
            while i < limit - n * 2 {
                let c = b[i]
                if c == lower[0] || c == upper[0] {
                    var ok = true
                    for k in 1..<n where b[i + k] != lower[k] && b[i + k] != upper[k] { ok = false; break }
                    if ok { return true }
                    ok = true
                    for k in 0..<n where (b[i + k * 2] != lower[k] && b[i + k * 2] != upper[k]) || b[i + k * 2 + 1] != 0 { ok = false; break }
                    if ok { return true }
                }
                i += 1
            }
            return false
        }
    }

    private func offset(_ rva: UInt32) -> Int? { PEFile.fileOffset(rva, sections: sections, count: data.count) }

    /// RVA → file offset. Int arithmetic: corrupt headers must not trap on UInt32 overflow.
    private static func fileOffset(_ rva: UInt32, sections: [Section], count: Int) -> Int? {
        let r = Int(rva)
        for s in sections {
            let va = Int(s.va), size = Int(max(s.vsize, s.rawSize))
            if r >= va && r < va + size {
                let o = r - va + Int(s.rawPtr)
                return o >= 0 && o < count ? o : nil
            }
        }
        return nil
    }

    // MARK: Resources

    private struct ResEntry { var id: UInt32?; var isDir: Bool; var offset: Int }

    private func resEntries(at dirOffset: Int, base: Int) -> [ResEntry] {
        guard dirOffset + 16 <= data.count else { return [] }
        let count = Int(data.u16(dirOffset + 12)) + Int(data.u16(dirOffset + 14))
        var out: [ResEntry] = []
        for i in 0..<min(count, 4096) {
            let e = dirOffset + 16 + i * 8
            guard e + 8 <= data.count else { break }
            let name = data.u32(e), off = data.u32(e + 4)
            out.append(ResEntry(id: name & 0x8000_0000 == 0 ? name : nil,
                                isDir: off & 0x8000_0000 != 0,
                                offset: base + Int(off & 0x7FFF_FFFF)))
        }
        return out
    }

    /// Returns (id → bytes) for every leaf of a resource type (first language).
    private func resources(type: UInt32) -> [(id: UInt32?, data: Data)] {
        guard resourceRVA != 0, let base = offset(resourceRVA) else { return [] }
        guard let typeDir = resEntries(at: base, base: base).first(where: { $0.id == type && $0.isDir }) else { return [] }
        var out: [(UInt32?, Data)] = []
        for item in resEntries(at: typeDir.offset, base: base) where item.isDir {
            guard let lang = resEntries(at: item.offset, base: base).first, !lang.isDir, lang.offset + 8 <= data.count else { continue }
            let rva = data.u32(lang.offset), size = Int(data.u32(lang.offset + 4))
            guard let o = offset(rva), size > 0, size <= data.count - o else { continue }
            out.append((item.id, data.subdata(in: data.startIndex + o ..< data.startIndex + o + size)))
        }
        return out
    }

    /// The executable's main icon as a `.ico` file, if it has one.
    public func iconData() -> Data? {
        guard let group = resources(type: 14).first?.data, group.count >= 6 else { return nil }
        let icons = Dictionary(resources(type: 3).compactMap { e in e.id.map { ($0, e.data) } }, uniquingKeysWith: { a, _ in a })
        let count = Int(group.u16(4))
        var entries: [(header: Data, image: Data)] = []
        for i in 0..<min(count, 64) {
            let e = 6 + i * 14
            guard e + 14 <= group.count else { break }
            let id = UInt32(group.u16(e + 12))
            guard let img = icons[id] else { continue }
            entries.append((group.subdata(in: group.startIndex + e ..< group.startIndex + e + 8), img))
        }
        guard !entries.isEmpty else { return nil }
        var ico = Data()
        ico.appendLE(UInt16(0)); ico.appendLE(UInt16(1)); ico.appendLE(UInt16(entries.count))
        var imageOffset = 6 + 16 * entries.count
        for e in entries {
            ico.append(e.header)
            ico.appendLE(UInt32(e.image.count))
            ico.appendLE(UInt32(imageOffset))
            imageOffset += e.image.count
        }
        for e in entries { ico.append(e.image) }
        return ico
    }

    public enum PEError: Error { case notPE }
}

extension Data {
    func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + o + $1]) << (8 * UInt32($1)) }
    }
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
