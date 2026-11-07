// BTreeFile: one HFS+ B-tree (catalog, extents overflow or attributes, TN1150 "B-Trees") as its leaf records in
// key order, edited in memory and laid out whole when written: leaves packed in key order, then the index levels
// above them, a map record in the header node and map nodes past it when the header's map runs out, unused nodes
// zeroed. A fresh layout instead of node-by-node insertion: the same records always give the same bytes, and there
// are no splits or merges to get wrong; the kernel splits a packed node like any other once the device writes.
//
//   var t = try BTreeFile(fileBytes, compare: BTreeFile.catalogOrder)
//   t[key] = value; t[key] = nil                     // keys include their 2-byte keyLength
//   let bytes = try t.layout(totalNodes: n)          // the whole B-tree file; t.nodesNeeded(totalNodes:) first

import BinaryParsing
import Foundation

struct BTreeFile {
    struct Record: Equatable {
        var key: [UInt8]
        var value: [UInt8]
    }

    let nodeSize: Int
    let maxKeyLength: Int
    let clumpSize: UInt32
    let btreeType: UInt8
    let keyCompareType: UInt8
    let attributes: UInt32
    private let userData: [UInt8]
    let compare: ([UInt8], [UInt8]) -> Int
    private(set) var records: [Record] = []

    static let bigKeys: UInt32 = 2, variableIndexKeys: UInt32 = 4

    /// A tree with no records.
    init(
        nodeSize: Int,
        maxKeyLength: Int,
        clumpSize: UInt32,
        keyCompareType: UInt8 = 0,
        attributes: UInt32,
        compare: @escaping ([UInt8], [UInt8]) -> Int
    ) {
        self.nodeSize = nodeSize
        self.maxKeyLength = maxKeyLength
        self.clumpSize = clumpSize
        btreeType = 0
        self.keyCompareType = keyCompareType
        self.attributes = attributes
        userData = [UInt8](repeating: 0, count: 128)
        self.compare = compare
    }

    /// The tree in `file` (the B-tree file's bytes, from node 0), its records read along the leaf chain; each must
    /// be `wellFormed` (hold what `compare` and the tree's users read of it).
    init(
        _ file: [UInt8],
        compare: @escaping ([UInt8], [UInt8]) -> Int,
        wellFormed: (Record) -> Bool = { _ in true }
    ) throws {
        guard file.count >= 512, file[8] == 1 else { throw FirmwareError(.unsupported, "no B-tree header node") }
        let h = 14
        nodeSize = Int(try be16(file, h + 18))
        maxKeyLength = Int(try be16(file, h + 20))
        clumpSize = try be32(file, h + 32)
        btreeType = file[h + 36]
        keyCompareType = file[h + 37]
        attributes = try be32(file, h + 38)
        guard nodeSize >= 512, file.count >= nodeSize else { throw FirmwareError(.unsupported, "bad B-tree node size") }
        userData = Array(file[120..<248])
        self.compare = compare
        var n = Int(try be32(file, h + 10))
        var seen = Set<Int>()
        while n != 0 {
            guard seen.insert(n).inserted, (n + 1) * nodeSize <= file.count else {
                throw FirmwareError(.unsupported, "B-tree leaf chain breaks at node \(n)")
            }
            guard file[n * nodeSize + 8] == 0xFF else {
                throw FirmwareError(.unsupported, "B-tree node \(n) in the leaf chain")
            }
            n = try parsing(file[n * nodeSize..<(n + 1) * nodeSize], "B-tree node \(n)") { node in
                // the records' offsets, then the free space's, from the node's end
                let count = Int(try node.be16(at: 10))
                var table = try node.seeking(toOffsetFromEnd: 2 * (count + 1))
                let offs = try [UInt16](parsing: &table, count: count + 1) { try UInt16(parsingBigEndian: &$0) }
                    .reversed().map(Int.init)
                for i in 0..<count {
                    var r = try node.seeking(toRelativeOffset: offs[i])
                    let keyEnd = offs[i] + 2 + Int(try r.be16(at: 0))
                    guard offs[i] < keyEnd, keyEnd <= offs[i + 1] else {
                        throw FirmwareError(.unsupported, "B-tree node \(n) record \(i) is malformed")
                    }
                    let record = Record(
                        key: try [UInt8](parsing: &r, byteCount: keyEnd - offs[i]),
                        value: try [UInt8](parsing: &r, byteCount: offs[i + 1] - keyEnd)
                    )
                    guard wellFormed(record) else {
                        throw FirmwareError(.unsupported, "B-tree node \(n) record \(i) is malformed")
                    }
                    records.append(record)
                }
                return Int(try node.be32(at: 0))
            }
        }
        for i in records.indices.dropFirst() where compare(records[i - 1].key, records[i].key) >= 0 {
            throw FirmwareError(.unsupported, "B-tree records out of order at \(i)")
        }
    }

    // MARK: - Records

    /// Where `key` is, or where it would go.
    func position(_ key: [UInt8]) -> (index: Int, found: Bool) {
        var lo = 0
        var hi = records.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let c = compare(records[mid].key, key)
            if c == 0 { return (mid, true) }
            if c < 0 { lo = mid + 1 } else { hi = mid }
        }
        return (lo, false)
    }

    subscript(key: [UInt8]) -> [UInt8]? {
        get {
            let p = position(key)
            return p.found ? records[p.index].value : nil
        }
        set {
            let p = position(key)
            switch (newValue, p.found) {
            case (let v?, true): records[p.index].value = v
            case (let v?, false): records.insert(Record(key: key, value: v), at: p.index)
            case (nil, true): records.remove(at: p.index)
            case (nil, false): break
            }
        }
    }

    /// The records from the first whose key is not below `from` while `body` takes them.
    func scan(from key: [UInt8], while body: (Record) -> Bool) {
        for r in records[position(key).index...] { guard body(r) else { return } }
    }

    // MARK: - Layout

    private var mapBitsInHeader: Int { (nodeSize - 256) * 8 }
    private var mapBitsPerNode: Int { (nodeSize - 20) * 8 }

    private func mapNodes(_ totalNodes: Int) -> Int {
        totalNodes <= mapBitsInHeader ? 0 : (totalNodes - mapBitsInHeader + mapBitsPerNode - 1) / mapBitsPerNode
    }

    /// Records per node at each level, leaves first; the root level has one node (none when the tree is empty).
    private func levels() throws -> [[[Record]]] {
        var level = try pack(records)
        var out: [[[Record]]] = []
        while !level.isEmpty {
            out.append(level)
            if level.count == 1 { break }
            level = try pack(level.map { indexRecord($0[0].key, child: 0) })
        }
        return out
    }

    private func indexRecord(_ key: [UInt8], child: UInt32) -> Record {
        var k = key
        if attributes & Self.variableIndexKeys == 0 {
            k += [UInt8](repeating: 0, count: max(0, maxKeyLength + 2 - k.count))
            putBE16(&k, 0, UInt16(maxKeyLength))
        }
        var v = [UInt8](repeating: 0, count: 4)
        putBE32(&v, 0, child)
        return Record(key: k, value: v)
    }

    private func pack(_ rs: [Record]) throws -> [[Record]] {
        var nodes: [[Record]] = []
        var cur: [Record] = []
        var used = 14 + 2
        for r in rs {
            let size = r.key.count + r.value.count + 2
            guard 14 + 2 + size <= nodeSize else {
                throw FirmwareError(.internal, "a B-tree record of \(size) bytes does not fit a \(nodeSize)-byte node")
            }
            if used + size > nodeSize {
                nodes.append(cur)
                cur = []
                used = 14 + 2
            }
            cur.append(r)
            used += size
        }
        if !cur.isEmpty { nodes.append(cur) }
        return nodes
    }

    /// The nodes this tree takes in a file of `totalNodes` nodes: the header, its map nodes, the leaves and index.
    func nodesNeeded(totalNodes: Int) throws -> Int {
        try 1 + mapNodes(totalNodes) + levels().reduce(0) { $0 + $1.count }
    }

    /// The whole B-tree file of `totalNodes` nodes.
    func layout(totalNodes: Int) throws -> [UInt8] {
        let maps = mapNodes(totalNodes)
        var lv = try levels()
        let used = 1 + maps + lv.reduce(0) { $0 + $1.count }
        guard used <= totalNodes else {
            throw FirmwareError(.internal, "the B-tree needs \(used) nodes, its file has \(totalNodes)")
        }
        var file = [UInt8](repeating: 0, count: totalNodes * nodeSize)
        // node numbers: header 0, map nodes 1...maps, then each level's nodes in order, leaves first
        var first: [Int] = []
        var next = 1 + maps
        for l in lv {
            first.append(next)
            next += l.count
        }
        for h in 1..<max(1, lv.count) {
            for (i, node) in lv[h].enumerated() {
                var child = first[h - 1] + lv[h].prefix(i).reduce(0) { $0 + $1.count }
                lv[h][i] = node.map { r in
                    defer { child += 1 }
                    var v = r.value
                    putBE32(&v, 0, UInt32(child))
                    return Record(key: r.key, value: v)
                }
            }
        }
        for (h, l) in lv.enumerated() {
            for (i, node) in l.enumerated() {
                let n = first[h] + i
                writeNode(
                    &file,
                    n,
                    fLink: i + 1 < l.count ? n + 1 : 0,
                    bLink: i > 0 ? n - 1 : 0,
                    kind: h == 0 ? 0xFF : 0,
                    height: h + 1,
                    records: node.map { $0.key + $0.value }
                )
            }
        }
        // header record
        var hr = [UInt8](repeating: 0, count: 106)
        putBE16(&hr, 0, UInt16(lv.count))
        putBE32(&hr, 2, lv.isEmpty ? 0 : UInt32(first[lv.count - 1]))
        putBE32(&hr, 6, UInt32(records.count))
        putBE32(&hr, 10, lv.isEmpty ? 0 : UInt32(first[0]))
        putBE32(&hr, 14, lv.isEmpty ? 0 : UInt32(first[0] + lv[0].count - 1))
        putBE16(&hr, 18, UInt16(nodeSize))
        putBE16(&hr, 20, UInt16(maxKeyLength))
        putBE32(&hr, 22, UInt32(totalNodes))
        putBE32(&hr, 26, UInt32(totalNodes - used))
        putBE32(&hr, 32, clumpSize)
        hr[36] = btreeType
        hr[37] = keyCompareType
        putBE32(&hr, 38, attributes)
        // the map: one bit per node, most significant first, set for the nodes in use (all numbered below `used`)
        var bits = [UInt8](repeating: 0, count: mapBitsInHeader / 8 + maps * mapBitsPerNode / 8)
        for n in 0..<used { bits[n / 8] |= 0x80 >> UInt8(n % 8) }
        let headerMap = Array(bits[0..<mapBitsInHeader / 8])
        writeNode(&file, 0, fLink: maps > 0 ? 1 : 0, bLink: 0, kind: 1, height: 0, records: [hr, userData, headerMap])
        for m in 0..<maps {
            let at = mapBitsInHeader / 8 + m * mapBitsPerNode / 8
            writeNode(
                &file,
                1 + m,
                fLink: m + 1 < maps ? 2 + m : 0,
                bLink: 0,
                kind: 2,
                height: 0,
                records: [Array(bits[at..<at + mapBitsPerNode / 8])]
            )
        }
        return file
    }

    private func writeNode(
        _ file: inout [UInt8],
        _ n: Int,
        fLink: Int,
        bLink: Int,
        kind: UInt8,
        height: Int,
        records rs: [[UInt8]]
    ) {
        let base = n * nodeSize
        putBE32(&file, base, UInt32(fLink))
        putBE32(&file, base + 4, UInt32(bLink))
        file[base + 8] = kind
        file[base + 9] = UInt8(height)
        putBE16(&file, base + 10, UInt16(rs.count))
        var off = 14
        for (i, r) in rs.enumerated() {
            file.replaceSubrange(base + off..<base + off + r.count, with: r)
            putBE16(&file, base + nodeSize - 2 * (i + 1), UInt16(off))
            off += r.count
        }
        putBE16(&file, base + nodeSize - 2 * (rs.count + 1), UInt16(off))
    }

    // MARK: - Key orders

    // Keys reach the orders well-formed (wellFormed on load, the writer's own keys); a field one doesn't hold reads
    // as 0 and a name as the units it holds, so an order never reads past its key.

    /// HFSX catalog keys (keyLength, parentID, name length, UTF-16BE name): by parent, then name as binary UTF-16
    /// (kHFSBinaryCompare).
    static func catalogOrder(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let pa = word(a, 2)
        let pb = word(b, 2)
        if pa != pb { return pa < pb ? -1 : 1 }
        return compareNames(name(a, at: 6), name(b, at: 6))
    }

    /// Extents overflow keys (keyLength, forkType, pad, fileID, startBlock): by file, fork, start.
    static func extentsOrder(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let ka = (word(a, 4), a.count > 2 ? a[2] : 0, word(a, 8))
        let kb = (word(b, 4), b.count > 2 ? b[2] : 0, word(b, 8))
        return ka == kb ? 0 : ka < kb ? -1 : 1
    }

    /// Attributes keys (keyLength, pad, fileID, startBlock, name length, UTF-16BE name): by file, name, start.
    static func attributesOrder(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let fa = word(a, 4)
        let fb = word(b, 4)
        if fa != fb { return fa < fb ? -1 : 1 }
        let c = compareNames(name(a, at: 12), name(b, at: 12))
        if c != 0 { return c }
        let sa = word(a, 8)
        let sb = word(b, 8)
        return sa == sb ? 0 : sa < sb ? -1 : 1
    }

    private static func word(_ k: [UInt8], _ o: Int) -> UInt32 { (try? be32(k, o)) ?? 0 }

    /// The UTF-16BE name whose unit count (big-endian) is at `o`, the units after it, within the key.
    private static func name(_ k: [UInt8], at o: Int) -> ArraySlice<UInt8> {
        let units = Int((try? be16(k, o)) ?? 0)
        return k[min(o + 2, k.count)..<min(o + 2 + 2 * units, k.count)]
    }

    /// Two UTF-16BE names compared as binary code units, a prefix first: big-endian units order as their bytes.
    static func compareNames(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        if let (x, y) = zip(a, b).first(where: { $0 != $1 }) { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : a.count < b.count ? -1 : 1
    }
}
