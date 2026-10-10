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

/// Group payloads whose 64-bit hashes are within `maxDistance` Hamming bits
/// (transitively), via a BK-tree + union-find. Distinct payloads that share an
/// identical hash always group together. Returns components of size >= 2.
/// Mirrors Python `hash.group_by_hash`.
public func groupByHash<P>(_ items: [(UInt64, P)], maxDistance: Int) -> [[P]] {
    var byHash: [UInt64: [P]] = [:]
    var order: [UInt64] = []
    for (h, payload) in items {
        if byHash[h] == nil { order.append(h) }
        byHash[h, default: []].append(payload)
    }

    let tree = BKTree()
    for h in order { tree.add(h) }

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

    for h in order { parent[h] = h }
    for h in order {
        for neighbour in tree.query(h, maxDistance: maxDistance) { union(h, neighbour) }
    }

    var components: [UInt64: [P]] = [:]
    for h in order { components[find(h), default: []].append(contentsOf: byHash[h]!) }
    return components.values.filter { $0.count >= 2 }
}
