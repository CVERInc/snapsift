import Foundation

/// 64-bit difference hash from a flat row-major grayscale buffer that is
/// `(size+1)` wide by `size` tall. Each bit is "is this pixel brighter than the
/// one to its right". Mirrors Python `hash.dhash_from_gray`.
public func dHash(grayRowMajor pixels: [Int], size: Int = 8) -> UInt64 {
    let width = size + 1
    var bits: UInt64 = 0
    for row in 0..<size {
        let base = row * width
        for col in 0..<size {
            bits = (bits << 1) | (pixels[base + col] > pixels[base + col + 1] ? 1 : 0)
        }
    }
    return bits
}

/// Number of differing bits between two hashes.
public func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

/// Metric tree over Hamming distance for fast "all within d" queries.
public final class BKTree {
    private final class Node {
        let key: UInt64
        var children: [Int: Node] = [:]
        init(_ key: UInt64) { self.key = key }
    }
    private var root: Node?

    public init() {}

    public func add(_ key: UInt64) {
        guard let root else { self.root = Node(key); return }
        var node = root
        while true {
            let d = hamming(key, node.key)
            if let child = node.children[d] {
                node = child
            } else {
                node.children[d] = Node(key)
                return
            }
        }
    }

    public func query(_ key: UInt64, maxDistance: Int) -> [UInt64] {
        guard let root else { return [] }
        var out: [UInt64] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            let d = hamming(key, node.key)
            if d <= maxDistance { out.append(node.key) }
            for (dist, child) in node.children where (d - maxDistance) <= dist && dist <= (d + maxDistance) {
                stack.append(child)
            }
        }
        return out
    }
}

/// How `groupByHash` finds the pairs within `maxDistance`. Every strategy
/// returns the same grouping; they differ only in cost. Callers use
/// `.automatic` (the two-argument `groupByHash`); the explicit cases exist so
/// the test target can hold each path against the reference on any input.
public enum HashGroupingStrategy {
    /// Multi-index hashing when it pays, the BK-tree otherwise.
    case automatic
    /// Multi-index hashing whenever the item indices fit in Int32 (beyond
    /// that it falls back to the BK-tree). Correct for every distance, but
    /// slower than the BK-tree on small inputs or large distances.
    case multiIndex
    /// Always the BK-tree: quadratic on 64-bit hashes, cheap on small inputs.
    case bkTree
}

/// Group payloads whose 64-bit hashes are within `maxDistance` Hamming bits
/// (transitively). Distinct payloads that share an identical hash always group
/// together. Returns components of size >= 2 — a component is counted in
/// payloads, so one hash carried by two payloads is a group and a hash with a
/// single payload and no neighbour is not returned.
/// Same grouping as Python `hash.group_by_hash`.
///
/// Ordering:
/// - Within a group, payloads follow the first appearance of their hash in
///   `items`, and payloads sharing a hash keep their `items` order.
/// - Groups are ordered by their first member's position in `items`. (Before
///   multi-index hashing this was dictionary order, which differs between
///   runs; no caller could rely on it.)
///
/// A negative `maxDistance` links nothing beyond identical hashes; 64 or more
/// links everything.
public func groupByHash<P>(_ items: [(UInt64, P)], maxDistance: Int) -> [[P]] {
    groupByHash(items, maxDistance: maxDistance, strategy: .automatic)
}

public func groupByHash<P>(_ items: [(UInt64, P)], maxDistance: Int,
                           strategy: HashGroupingStrategy) -> [[P]] {
    var byHash: [UInt64: [P]] = [:]
    var order: [UInt64] = []
    for (h, payload) in items {
        if byHash[h] == nil { order.append(h) }
        byHash[h, default: []].append(payload)
    }

    let useMultiIndex: Bool
    switch strategy {
    case .multiIndex: useMultiIndex = order.count <= Int(Int32.max)
    case .bkTree: useMultiIndex = false
    case .automatic: useMultiIndex = multiIndexPays(keyCount: order.count, maxDistance: maxDistance)
    }
    // One label per distinct hash; equal labels mean the same component.
    let labels = useMultiIndex
        ? multiIndexLabels(order, maxDistance: maxDistance)
        : bkTreeLabels(order, maxDistance: maxDistance)

    var slotOfLabel: [Int: Int] = [:]
    var groups: [[P]] = []
    for (i, h) in order.enumerated() {
        let slot: Int
        if let known = slotOfLabel[labels[i]] {
            slot = known
        } else {
            slot = groups.count
            slotOfLabel[labels[i]] = slot
            groups.append([])
        }
        groups[slot].append(contentsOf: byHash[h]!)
    }
    return groups.filter { $0.count >= 2 }
}

// MARK: - BK-tree path

/// Components via BK-tree queries and a union-find keyed by hash. On 64-bit
/// hashes a query visits most of the tree, so this is quadratic in the number
/// of distinct hashes; it stays the path for inputs too small, or distances
/// too large, for multi-index hashing to pay.
private func bkTreeLabels(_ keys: [UInt64], maxDistance: Int) -> [Int] {
    let tree = BKTree()
    for h in keys { tree.add(h) }

    var parent: [UInt64: UInt64] = [:]
    func find(_ x: UInt64) -> UInt64 {
        var root = x
        while parent[root, default: root] != root { root = parent[root, default: root] }
        var cur = x
        while parent[cur, default: cur] != root {
            let next = parent[cur, default: cur]
            parent[cur] = root
            cur = next
        }
        return root
    }
    func union(_ a: UInt64, _ b: UInt64) { parent[find(a)] = find(b) }

    for h in keys { parent[h] = h }
    for h in keys {
        for neighbour in tree.query(h, maxDistance: maxDistance) { union(h, neighbour) }
    }

    // A component's label is the bit pattern of its root hash. A plain loop,
    // not `map`: a closure capturing `find` would move `parent` to the heap
    // and slow every access to it in the loops above.
    var labels: [Int] = []
    labels.reserveCapacity(keys.count)
    for h in keys { labels.append(Int(bitPattern: UInt(find(h)))) }
    return labels
}

// MARK: - Multi-index path

/// A 64-bit hash is cut into four 16-bit chunks. Two hashes within `d` bits
/// differ by at most `d / 4` bits (rounded down) in at least one chunk —
/// otherwise every chunk would differ by more, and the total would exceed `d`.
private let chunkCount = 4
private let chunkBits = 16
private let chunkValues = 1 << chunkBits

/// Number of 16-bit masks with at most `radius` bits set, for radius 0…16.
private let maskCountByRadius = [1, 17, 137, 697, 2517, 6885, 14893, 26333, 39203,
                                 50643, 58651, 63019, 64839, 65399, 65519, 65535, 65536]

private func chunkRadius(_ maxDistance: Int) -> Int {
    min(max(maxDistance, 0), 64) / chunkCount
}

/// Multi-index hashing pays a fixed cost to build its buckets and then a fixed
/// number of probes per hash; the BK-tree visits most other hashes for each
/// hash. A probe costs roughly a tenth of a BK-tree visit, so multi-index wins
/// once there are a few hundred hashes and the probes per hash stay within
/// eight times the hash count. Smaller inputs — a single burst — keep the
/// BK-tree, as do distances so large that nearly every bucket is probed.
private func multiIndexPays(keyCount: Int, maxDistance: Int) -> Bool {
    guard keyCount >= 512, keyCount <= Int(Int32.max) else { return false }
    return chunkCount * maskCountByRadius[chunkRadius(maxDistance)] < 8 * keyCount
}

/// Components via multi-index hashing: every hash is filed under each of its
/// four chunks; a hash then looks only in the buckets whose chunk is within
/// the per-chunk radius of its own, and each hash found there is confirmed
/// with `hamming` before the two are joined. Correct for every distance — at
/// 64 the radius covers every bucket.
private func multiIndexLabels(_ keys: [UInt64], maxDistance: Int) -> [Int] {
    let n = keys.count
    var parent = [Int32](repeating: 0, count: n)
    for i in 0..<n { parent[i] = Int32(i) }
    guard n >= 2, maxDistance >= 0 else { return parent.map { Int($0) } }

    // Per chunk: `starts` has one slot per chunk value plus a terminator, and
    // `members` lists hash indices bucket by bucket, ascending within a bucket.
    let span = chunkValues + 1
    var starts = [Int32](repeating: 0, count: chunkCount * span)
    var members = [Int32](repeating: 0, count: chunkCount * n)
    for c in 0..<chunkCount {
        let shift = UInt64(c * chunkBits)
        let base = c * span
        for h in keys { starts[base + Int((h >> shift) & 0xFFFF) + 1] += 1 }
        for v in 0..<chunkValues { starts[base + v + 1] += starts[base + v] }
        var cursor = Array(starts[base..<(base + chunkValues)])
        for (i, h) in keys.enumerated() {
            let v = Int((h >> shift) & 0xFFFF)
            members[c * n + Int(cursor[v])] = Int32(i)
            cursor[v] += 1
        }
    }

    let radius = chunkRadius(maxDistance)
    var masks: [UInt16] = []
    masks.reserveCapacity(maskCountByRadius[radius])
    for m in 0..<chunkValues where m.nonzeroBitCount <= radius { masks.append(UInt16(m)) }

    keys.withUnsafeBufferPointer { keys in
    starts.withUnsafeBufferPointer { starts in
    members.withUnsafeBufferPointer { members in
    masks.withUnsafeBufferPointer { masks in
    parent.withUnsafeMutableBufferPointer { parent in
        func find(_ x: Int32) -> Int32 {
            var root = x
            while parent[Int(root)] != root { root = parent[Int(root)] }
            var cur = x
            while parent[Int(cur)] != root {
                let next = parent[Int(cur)]
                parent[Int(cur)] = root
                cur = next
            }
            return root
        }
        for i in 0..<n {
            let h = keys[i]
            for c in 0..<chunkCount {
                let own = UInt16(truncatingIfNeeded: h >> UInt64(c * chunkBits))
                let base = c * span
                let offset = c * n
                for m in masks {
                    let v = Int(own ^ m)
                    let lo = Int(starts[base + v])
                    var at = Int(starts[base + v + 1])
                    // Buckets ascend, so walking down from the end and stopping
                    // at `i` visits each pair once, from its lower index.
                    while at > lo {
                        at -= 1
                        let j = members[offset + at]
                        if Int(j) <= i { break }
                        if hamming(h, keys[Int(j)]) <= maxDistance {
                            let a = find(Int32(i)), b = find(j)
                            if a != b { parent[Int(a)] = b }
                        }
                    }
                }
            }
        }
        for i in 0..<n { parent[i] = find(Int32(i)) }
    }}}}}
    return parent.map { Int($0) }
}
