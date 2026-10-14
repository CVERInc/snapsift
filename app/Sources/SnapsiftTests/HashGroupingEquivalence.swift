import Foundation
import SnapsiftCore

// Equivalence gate for `groupByHash`.
//
// `groupByHash` decides which photos are shown together, so a faster way of
// finding near hashes may not move a single photo between groups. This file
// keeps the implementation that shipped through 0.10.0 as the reference and
// holds every strategy of the current one against it, plus an all-pairs oracle
// that shares no code with either.

// MARK: - Reference (the 0.10.0 implementation, kept verbatim)

private final class ReferenceBKTree {
    private final class Node {
        let key: UInt64
        var children: [Int: Node] = [:]
        init(_ key: UInt64) { self.key = key }
    }
    private var root: Node?

    func add(_ key: UInt64) {
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

    func query(_ key: UInt64, maxDistance: Int) -> [UInt64] {
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

private func referenceGroupByHash<P>(_ items: [(UInt64, P)], maxDistance: Int) -> [[P]] {
    var byHash: [UInt64: [P]] = [:]
    var order: [UInt64] = []
    for (h, payload) in items {
        if byHash[h] == nil { order.append(h) }
        byHash[h, default: []].append(payload)
    }

    let tree = ReferenceBKTree()
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

// MARK: - All-pairs oracle (no tree, no index)

private func allPairsGroups(_ items: [(UInt64, Int)], maxDistance: Int) -> Set<Set<Int>> {
    let n = items.count
    var parent = Array(0..<n)
    func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        return r
    }
    items.withUnsafeBufferPointer { items in
        for a in 0..<n {
            // Identical hashes always group, even below distance zero.
            for b in (a + 1)..<n where items[a].0 == items[b].0
                || (items[a].0 ^ items[b].0).nonzeroBitCount <= maxDistance {
                let ra = find(a), rb = find(b)
                if ra != rb { parent[ra] = rb }
            }
        }
    }
    var comp: [Int: Set<Int>] = [:]
    for i in 0..<n { comp[find(i), default: []].insert(items[i].1) }
    return Set(comp.values.filter { $0.count >= 2 })
}

// MARK: - Inputs

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

/// Exactly `bits` set, at random positions.
private func randomMask(_ bits: Int, _ rng: inout SplitMix64) -> UInt64 {
    var positions = Array(0..<64)
    var mask: UInt64 = 0
    for k in 0..<bits {
        let pick = k + rng.below(64 - k)
        positions.swapAt(k, pick)
        mask |= 1 << UInt64(positions[k])
    }
    return mask
}

/// Exactly `bits` set, dealt round-robin over the four 16-bit chunks — the
/// spread that leaves every chunk as far from its twin as the bound allows.
private func balancedMask(_ bits: Int, offset: Int = 0) -> UInt64 {
    var mask: UInt64 = 0
    for t in 0..<bits { mask |= 1 << UInt64((t % 4) * 16 + ((t / 4 + offset) % 16)) }
    return mask
}

/// Exactly `bits` set, packed from bit 0 up — as few chunks as possible.
private func packedMask(_ bits: Int) -> UInt64 {
    bits >= 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1
}

private typealias Items = [(UInt64, Int)]

private func labelled(_ hashes: [UInt64]) -> Items { hashes.enumerated().map { ($0.element, $0.offset) } }

private func randomHashes(_ n: Int, seed: UInt64) -> [UInt64] {
    var rng = SplitMix64(state: seed)
    return (0..<n).map { _ in rng.next() }
}

/// A library-shaped input: mostly unrelated hashes, about a third that are an
/// earlier hash with 0…18 bits flipped (so copies of copies form chains on
/// both sides of every threshold in use), and one hash repeated many times.
private func clusteredHashes(_ n: Int, seed: UInt64) -> [UInt64] {
    var rng = SplitMix64(state: seed)
    var out: [UInt64] = []
    out.reserveCapacity(n)
    let repeated = rng.next()
    for i in 0..<n {
        let roll = rng.below(100)
        if i > 0 && roll < 33 {
            out.append(out[rng.below(i)] ^ randomMask(rng.below(19), &rng))
        } else if roll < 36 {
            out.append(repeated)
        } else {
            out.append(rng.next())
        }
    }
    return out
}

/// Chains whose every link is exactly `step` bits on fresh bit positions, so
/// the two ends of a chain of k links are k × step apart; hidden among
/// unrelated hashes.
private func chainHashes(step: Int, chains: Int, background: Int, seed: UInt64) -> [UInt64] {
    var rng = SplitMix64(state: seed)
    var out = (0..<background).map { _ in rng.next() }
    let links = step == 0 ? 3 : min(4, 64 / step)
    for _ in 0..<chains {
        var h = rng.next()
        var positions = Array(0..<64)
        for k in 0..<63 { positions.swapAt(k, k + rng.below(64 - k)) }
        out.append(h)
        for link in 0..<links {
            for bit in 0..<step { h ^= 1 << UInt64(positions[link * step + bit]) }
            out.insert(h, at: rng.below(out.count + 1))
        }
    }
    return out
}

/// Many payloads on a few hashes: X, a hash exactly `d` from X, and a
/// hash exactly `d + 1` from X, among unrelated hashes.
private func heavyDuplicates(distance d: Int, count: Int, seed: UInt64) -> [UInt64] {
    var rng = SplitMix64(state: seed)
    let x = rng.next()
    let atThreshold = x ^ randomMask(d, &rng)
    let pastThreshold = x ^ balancedMask(min(d + 1, 64), offset: 5)
    var out: [UInt64] = []
    for i in 0..<count {
        switch i % 4 {
        case 0: out.append(x)
        case 1: out.append(atThreshold)
        case 2: out.append(pastThreshold)
        default: out.append(rng.next())
        }
    }
    return out
}

/// All-zero, all-one, every single-bit hash and every all-but-one-bit hash.
private func extremeHashes() -> [UInt64] {
    var out: [UInt64] = [0, UInt64.max, 0, UInt64.max]
    for b in 0..<64 { out.append(1 << UInt64(b)); out.append(~(UInt64(1) << UInt64(b))) }
    return out
}

// MARK: - Comparison

private var comparisons = 0
private var groupsCompared = 0
private var counterexamples = 0

private func hex(_ h: UInt64) -> String { String(h, radix: 16) }

/// Holds one strategy against the reference on one input: the same groups with
/// the same members in the same order, and groups in first-appearance order.
private func matchesReference(_ name: String, _ items: Items, _ d: Int,
                              _ strategy: HashGroupingStrategy,
                              reference: [[Int]]) -> Bool {
    let got = groupByHash(items, maxDistance: d, strategy: strategy)
    comparisons += 1
    groupsCompared += reference.count
    var problem: String?
    if Set(got) != Set(reference) || got.count != reference.count {
        let missing = Set(reference).subtracting(got).min { $0.count < $1.count }
        let extra = Set(got).subtracting(reference).min { $0.count < $1.count }
        func show(_ g: [Int]?) -> String {
            guard let g else { return "none" }
            let hashOf = Dictionary(items.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
            return "\(g.count) members " + g.prefix(6).map { "p\($0)=\(hex(hashOf[$0]!))" }.joined(separator: " ")
        }
        problem = "groups differ: reference \(reference.count), got \(got.count); "
            + "smallest reference-only group: \(show(missing)); smallest new-only group: \(show(extra))"
    } else {
        let position = Dictionary(items.enumerated().map { ($0.element.1, $0.offset) },
                                  uniquingKeysWith: { a, _ in a })
        let firsts = got.map { position[$0[0]]! }
        if firsts != firsts.sorted() { problem = "groups are not in first-appearance order" }
    }
    if let problem {
        counterexamples += 1
        if counterexamples <= 8 {
            print("    counterexample — \(name), n=\(items.count), maxDistance=\(d), strategy=\(strategy): \(problem)")
        }
        return false
    }
    return true
}

/// Reference vs the given strategies; optionally the all-pairs oracle too.
private func equivalent(_ name: String, _ hashes: [UInt64], distances: [Int],
                        strategies: [HashGroupingStrategy], oracle: Bool = false) -> Bool {
    let items = labelled(hashes)
    var ok = true
    for d in distances {
        let reference = referenceGroupByHash(items, maxDistance: d)
        for s in strategies where !matchesReference(name, items, d, s, reference: reference) { ok = false }
        if oracle {
            comparisons += 1
            if Set(reference.map { Set($0) }) != allPairsGroups(items, maxDistance: d) {
                counterexamples += 1
                print("    counterexample — \(name), maxDistance=\(d): reference disagrees with all-pairs oracle")
                ok = false
            }
        }
    }
    return ok
}

// MARK: - The gate

private var sectionStarted = Date()
/// `check`, plus how long the section took — these are the slow tests.
private func timedCheck(_ condition: Bool, _ label: String) {
    let took = Date().timeIntervalSince(sectionStarted)
    check(condition, label + String(format: " [%.1f s]", took))
    fflush(stdout)
    sectionStarted = Date()
}

func checkHashGroupingEquivalence() {
    print("Hash grouping equivalence (multi-index vs the 0.10.0 BK-tree)")
    let all: [HashGroupingStrategy] = [.automatic, .multiIndex, .bkTree]
    let everyDistance = Array(0...64)
    // What callers pass (8 look-alikes, 14 similar sets and burst verify), the
    // values either side of them, the ends, and each change of chunk radius.
    let callerDistances = [0, 1, 3, 4, 7, 8, 9, 11, 12, 13, 14, 15, 16]
    let near = [0, 8, 9, 14, 15]
    // The whole matrix takes minutes even optimised, so the default run keeps
    // one seed per shape; `SNAPSIFT_HASH_EQUIVALENCE=full swift run -c release
    // SnapsiftTests` runs all of it, and is the run to repeat before touching
    // `groupByHash` again.
    let full = ProcessInfo.processInfo.environment["SNAPSIFT_HASH_EQUIVALENCE"] == "full"
    // The BK-tree strategy is the reference's own algorithm; on the larger
    // inputs the default run leaves it to the small ones above.
    let large: [HashGroupingStrategy] = full ? all : [.automatic, .multiIndex]
    let started = Date()
    sectionStarted = started

    // Empty, single, and inputs with one distinct hash.
    do {
        var ok = true
        let shapes: [(String, [UInt64])] = [
            ("empty", []), ("single", [42]), ("same hash twice", [42, 42]),
            ("two far apart", [0, UInt64.max]), ("same hash ×3 + stranger", [7, 7, UInt64.max, 7]),
        ]
        for (name, hashes) in shapes {
            ok = equivalent(name, hashes, distances: [-1] + everyDistance + [65, 1000],
                            strategies: full ? all : [.automatic, .bkTree], oracle: true) && ok
            ok = equivalent(name, hashes, distances: [-1, 0, 1, 8, 14, 16, 64, 65, 1000],
                            strategies: [.multiIndex]) && ok
        }
        timedCheck(ok, "empty / single / one-hash inputs, every distance −1…65 and 1000")
        timedCheck(groupByHash([(UInt64, Int)](), maxDistance: 14, strategy: .multiIndex).isEmpty
              && groupByHash([(UInt64(1), 1)], maxDistance: 14, strategy: .multiIndex).isEmpty
              && groupByHash([(UInt64(1), 1), (UInt64(1), 2)], maxDistance: 0, strategy: .multiIndex) == [[1, 2]],
              "multi-index: [] → [], one item → [], one hash twice → one group")
    }

    // Exactly at the threshold, and one bit past it — asserted outright, with
    // no reference involved, for every distance and three ways of spreading
    // the differing bits over the chunks.
    do {
        var rng = SplitMix64(state: 0xD1CE)
        var ok = true
        var pairs = 0
        for d in everyDistance {
            let base = rng.next()
            let masksAt: [(String, UInt64, UInt64?)] = [
                ("random", randomMask(d, &rng), d < 64 ? randomMask(d + 1, &rng) : nil),
                ("balanced", balancedMask(d, offset: d % 16), d < 64 ? balancedMask(d + 1, offset: d % 16) : nil),
                ("packed", packedMask(d), d < 64 ? packedMask(d + 1) : nil),
            ]
            for (style, at, past) in masksAt {
                // Forcing multi-index at a large distance probes most of every
                // chunk's buckets; the default run does that at the ends only.
                let cheap = d <= 20 || d >= 63
                for s in (full || cheap) ? all : [.automatic, .bkTree] {
                    pairs += 1
                    // d == 0: the twin IS the base, one hash with two payloads.
                    if groupByHash([(base, 0), (base ^ at, 1)], maxDistance: d, strategy: s) != [[0, 1]] {
                        ok = false
                        print("    counterexample — \(style) pair exactly \(d) apart not grouped at maxDistance=\(d), strategy=\(s): \(hex(base)) \(hex(base ^ at))")
                    }
                    if let past, !groupByHash([(base, 0), (base ^ past, 1)], maxDistance: d, strategy: s).isEmpty {
                        ok = false
                        print("    counterexample — \(style) pair \(d + 1) apart grouped at maxDistance=\(d), strategy=\(s): \(hex(base)) \(hex(base ^ past))")
                    }
                }
            }
        }
        timedCheck(ok, "pairs exactly at the threshold group, pairs one bit past it do not (\(pairs) pairs × 2, distances 0…64)")
    }

    // All-zero, all-one, single-bit and all-but-one-bit hashes.
    timedCheck(equivalent("extremes", extremeHashes(), distances: everyDistance, strategies: [.automatic, .bkTree], oracle: true),
          "all-zero / all-one / single-bit hashes, every distance 0…64 (automatic, BK-tree, all-pairs oracle)")
    let extremeDistances = full ? [0, 1, 2, 3, 4, 8, 14, 16, 32, 61, 62, 63, 64] : [0, 1, 2, 8, 14, 64]
    timedCheck(equivalent("extremes", extremeHashes(), distances: extremeDistances, strategies: [.multiIndex]),
          "all-zero / all-one / single-bit hashes, multi-index forced, distances \(extremeDistances)")

    // Random hashes, N = 2,000.
    do {
        var ok = true
        let seeds: [UInt64] = full ? [1, 2, 3] : [1]
        for seed in seeds {
            let hashes = randomHashes(2_000, seed: seed)
            ok = equivalent("random 2K seed \(seed)", hashes, distances: full ? callerDistances : near,
                            strategies: large, oracle: true) && ok
            if full {
                ok = equivalent("random 2K seed \(seed)", hashes, distances: [20, 24, 32, 63, 64],
                                strategies: [.automatic, .bkTree], oracle: true) && ok
            }
        }
        timedCheck(ok, "random hashes N=2,000 × \(seeds.count) seed(s), distances \(full ? "0…16 all strategies, 20…64 automatic + BK-tree" : "\(near) automatic + multi-index"), all-pairs oracle")
        // Large distances with multi-index forced, on an input small enough to
        // afford probing most of every chunk's buckets.
        let wide = full ? [20, 24, 28, 32, 48, 63, 64] : [24, 32, 64]
        timedCheck(equivalent("random 150", randomHashes(150, seed: 9), distances: wide,
                         strategies: [.multiIndex], oracle: true),
              "random hashes N=150, multi-index forced at distances \(wide)")
    }

    // Clustered: near-copies, copies of copies, a heavily repeated hash.
    do {
        var ok = true
        let seeds: [UInt64] = full ? [11, 12, 13] : [11]
        for seed in seeds {
            ok = equivalent("clustered 2K seed \(seed)", clusteredHashes(2_000, seed: seed),
                            distances: full ? callerDistances : near, strategies: large, oracle: true) && ok
        }
        timedCheck(ok, "clustered hashes N=2,000 × \(seeds.count) seed(s), distances \(full ? "0…16, all strategies" : "\(near), automatic + multi-index"), all-pairs oracle")
    }

    // Chains A~B~C with the ends farther apart than the threshold: the whole
    // chain is one group when a link is exactly the threshold, and no group at
    // all when the threshold is one bit short of a link.
    do {
        var ok = true
        for step in full ? [0, 1, 2, 4, 8, 9, 14, 15, 16] : [8, 14] {
            let hashes = chainHashes(step: step, chains: full ? 150 : 40,
                                     background: full ? 3_200 : 1_100, seed: UInt64(100 + step))
            let around = [step - 1, step, step + 1].filter { $0 >= 0 }
            ok = equivalent("chains of \(step)-bit links", hashes, distances: around, strategies: large, oracle: true) && ok
        }
        // Stated outright for the callers' distances: three hashes, 2 × d end to end.
        for d in [8, 14] {
            let a: UInt64 = 0x0123_4567_89AB_CDEF
            let b = a ^ balancedMask(d), c = b ^ balancedMask(d, offset: 8)
            for s in all {
                ok = hamming(a, c) == 2 * d
                    && groupByHash([(a, 0), (c, 1), (b, 2)], maxDistance: d, strategy: s) == [[0, 1, 2]]
                    && groupByHash([(a, 0), (c, 1), (b, 2)], maxDistance: d - 1, strategy: s).isEmpty
                    && groupByHash([(a, 0), (c, 1)], maxDistance: d, strategy: s).isEmpty && ok
            }
        }
        timedCheck(ok, "chains: ends beyond the threshold still join through the middle; one bit short and nothing joins")
    }

    // Thousands of payloads on one hash.
    do {
        var ok = true
        for d in full ? [0, 8, 14] : [14] {
            ok = equivalent("heavy duplicates at \(d)",
                            heavyDuplicates(distance: d, count: full ? 12_000 : 4_800, seed: UInt64(700 + d)),
                            distances: [max(d - 1, 0), d, d + 1], strategies: large) && ok
        }
        let same = [UInt64](repeating: 0xABCD, count: 5_000)
        ok = equivalent("5,000 identical", same, distances: [0, 8, 14, 64], strategies: all) && ok
        timedCheck(ok, "exact duplicates: \(full ? "3,000" : "1,200") payloads per hash at the threshold and one past it; 5,000 identical")
    }

    // Large enough that `.automatic` takes the multi-index path at both of
    // the distances the app passes: N = 4,000 by default, 20,000 in full.
    do {
        var ok = true
        let n = full ? 20_000 : 4_000
        var inputs: [(String, [UInt64])] = [("clustered \(n) seed 31", clusteredHashes(n, seed: 31))]
        if full {
            for seed in [UInt64(32), 33] { inputs.append(("clustered \(n) seed \(seed)", clusteredHashes(n, seed: seed))) }
            for seed in [UInt64(21), 22, 23] { inputs.append(("random \(n) seed \(seed)", randomHashes(n, seed: seed))) }
        }
        for (name, hashes) in inputs {
            ok = equivalent(name, hashes, distances: full ? [0, 1, 8, 14] : [8, 14],
                            strategies: full ? [.automatic, .multiIndex] : [.automatic]) && ok
        }
        timedCheck(ok, "N=\(n) \(full ? "random + clustered × 3 seeds, distances 0, 1, 8, 14, automatic + multi-index" : "clustered × 1 seed, distances 8, 14, automatic")")
    }

    timedCheck(counterexamples == 0, "no counterexample in \(comparisons) comparisons over \(groupsCompared) reference groups")
    print("  (\(full ? "full" : "default") matrix, \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
}
