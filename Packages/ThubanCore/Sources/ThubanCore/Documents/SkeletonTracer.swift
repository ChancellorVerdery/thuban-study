import Foundation

/// A curve's pixels as the strokes that were drawn, read from its skeleton: the ink thinned to one pixel wide, read
/// as a graph of branches between ends and junctions, and walked so a path keeps going straight through a crossing.
/// A loop that crosses itself, a figure-eight or two crossing lines come out whole this way, which reading the pixels
/// as a function of x or of y cannot do.
public enum SkeletonTracer {
    public typealias Point = (Double, Double)
    public typealias Blob = (x: Double, y: Double, radius: Double)

    /// One 8-connected ink component (column, row; row grows downward) as ordered paths in pixel coordinates,
    /// lightly smoothed and spaced about 2 px apart. A closed path repeats its first point at the end. Pixels inside
    /// `blobs` (arrowheads, dots) are erased first, and the gap each leaves in a curve is bridged.
    public static func paths(of pixels: [(Int, Int)], erasing blobs: [Blob] = []) -> [[Point]] {
        let kept = pixels.filter { p in !blobs.contains { hypot(Double(p.0) - $0.x, Double(p.1) - $0.y) <= $0.radius } }
        guard !kept.isEmpty else { return [] }
        var mask = Mask(kept)
        let ink = mask.count
        mask.thin()
        var graph = Graph(mask)
        // The stroke width: ink per unit of skeleton.
        let width = max(1, Double(ink) / max(1, graph.length))
        graph.pruneSpurs(shorterThan: max(3, 2 * width))
        graph.contractJunctions(closerThan: 3 * width)
        let traces = bridged(graph.walk(trim: 1.5 * width + 1), across: blobs, width: width)
        return traces.filter { length($0.points) >= max(4, 2 * width) }.map(finished)
    }

    /// An ordered run of skeleton points; a closed one does not repeat its first point.
    struct Trace {
        var points: [Point]
        var closed: Bool
    }

    // MARK: - Thinning

    /// The ink as a grid of cells with a blank border, so every set cell has eight neighbours to look at.
    struct Mask {
        let left: Int, top: Int, width: Int, height: Int
        var cells: [Bool]

        /// The eight neighbours clockwise from north, the order Zhang-Suen names P2…P9.
        static let ring = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

        init(_ pixels: [(Int, Int)]) {
            left = pixels.map(\.0).min()! - 1
            top = pixels.map(\.1).min()! - 1
            width = pixels.map(\.0).max()! - left + 2
            height = pixels.map(\.1).max()! - top + 2
            cells = [Bool](repeating: false, count: width * height)
            for (c, r) in pixels { cells[(r - top) * width + (c - left)] = true }
        }

        var count: Int { cells.reduce(0) { $0 + ($1 ? 1 : 0) } }

        func isSet(_ c: Int, _ r: Int) -> Bool {
            c >= 0 && c < width && r >= 0 && r < height && cells[r * width + c]
        }

        func neighbours(_ c: Int, _ r: Int) -> [Bool] { Mask.ring.map { isSet(c + $0.0, r + $0.1) } }

        /// Thinned to a one-pixel skeleton: Zhang-Suen, then the corner pixels of its staircases dropped so every
        /// pixel along a branch has exactly two neighbours.
        mutating func thin() {
            var changed = true
            while changed {
                changed = zhangSuenPass(first: true)
                changed = zhangSuenPass(first: false) || changed
            }
            dropCorners()
        }

        private mutating func zhangSuenPass(first: Bool) -> Bool {
            var doomed: [Int] = []
            for r in 0..<height { for c in 0..<width where cells[r * width + c] {
                let p = neighbours(c, r)
                let filled = p.filter { $0 }.count
                guard (2...6).contains(filled) else { continue }
                let rises = (0..<8).filter { !p[$0] && p[($0 + 1) % 8] }.count
                guard rises == 1 else { continue }
                let (n, e, s, w) = (p[0], p[2], p[4], p[6])
                if first ? (!(n && e && s) && !(e && s && w)) : (!(n && e && w) && !(n && s && w)) { doomed.append(r * width + c) }
            } }
            for k in doomed { cells[k] = false }
            return !doomed.isEmpty
        }

        /// Removes pixels whose neighbours stay joined without them (the inside corner of a staircase step), so a
        /// branch pixel never has a third neighbour that is only a shortcut.
        private mutating func dropCorners() {
            var changed = true
            while changed {
                changed = false
                for r in 0..<height { for c in 0..<width where cells[r * width + c] {
                    let p = neighbours(c, r)
                    guard p.filter({ $0 }).count >= 2, Mask.groups(p) == 1 else { continue }
                    cells[r * width + c] = false
                    changed = true
                } }
            }
        }

        /// How many separate groups the set neighbours form among themselves: ring neighbours touch, and so do two
        /// edge neighbours either side of a corner.
        static func groups(_ p: [Bool]) -> Int {
            var parent = Array(0..<8)
            func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
            for i in 0..<8 where p[i] {
                if p[(i + 1) % 8] { parent[root(i)] = root((i + 1) % 8) }
                if i % 2 == 0, p[(i + 2) % 8] { parent[root(i)] = root((i + 2) % 8) }
            }
            return Set((0..<8).filter { p[$0] }.map(root)).count
        }
    }

    // MARK: - Skeleton graph

    /// The skeleton as branches (edges) between nodes: clusters of pixels that are not plain branch pixels, so an
    /// end of the curve or a junction. A loop with no node is one edge without ends.
    struct Graph {
        struct Edge {
            /// Branch pixels from the first node to the second, nodes excluded.
            var points: [Point]
            var ends: (Int, Int)?
            var alive = true
        }

        var nodes: [[Point]]
        var edges: [Edge] = []

        init(_ mask: Mask) {
            let w = mask.width
            var degree = [Int](repeating: 0, count: mask.cells.count)
            for k in mask.cells.indices where mask.cells[k] {
                degree[k] = mask.neighbours(k % w, k / w).filter { $0 }.count
            }
            func steps(_ k: Int) -> [Int] {
                Mask.ring.compactMap { d in mask.isSet(k % w + d.0, k / w + d.1) ? k + d.1 * w + d.0 : nil }
            }
            func point(_ k: Int) -> Point { (Double(k % w + mask.left), Double(k / w + mask.top)) }
            let isNode = mask.cells.indices.map { mask.cells[$0] && degree[$0] != 2 }
            // Node pixels that touch are one node.
            var node = [Int](repeating: -1, count: mask.cells.count)
            nodes = []
            for start in mask.cells.indices where isNode[start] && node[start] < 0 {
                var stack = [start], members: [Point] = []
                node[start] = nodes.count
                while let k = stack.popLast() {
                    members.append(point(k))
                    for n in steps(k) where isNode[n] && node[n] < 0 { node[n] = nodes.count; stack.append(n) }
                }
                nodes.append(members)
            }
            var visited = [Bool](repeating: false, count: mask.cells.count)
            for start in mask.cells.indices where isNode[start] {
                for first in steps(start) where !isNode[first] && !visited[first] {
                    var points: [Point] = [], previous = start, current = first
                    while true {
                        visited[current] = true
                        points.append(point(current))
                        guard let next = steps(current).first(where: { $0 != previous }) else { break }
                        if isNode[next] { edges.append(Edge(points: points, ends: (node[start], node[next]))); break }
                        guard !visited[next] else { break }
                        (previous, current) = (current, next)
                    }
                }
            }
            // What is left is loops of branch pixels with no node on them.
            for start in mask.cells.indices where mask.cells[start] && !isNode[start] && !visited[start] {
                var points: [Point] = [], previous = steps(start)[0], current = start
                while !visited[current] {
                    visited[current] = true
                    points.append(point(current))
                    guard let next = steps(current).first(where: { $0 != previous }) else { break }
                    (previous, current) = (current, next)
                }
                edges.append(Edge(points: points, ends: nil))
            }
        }

        func centre(_ n: Int) -> Point {
            let members = nodes[n]
            return (members.reduce(0) { $0 + $1.0 } / Double(members.count), members.reduce(0) { $0 + $1.1 } / Double(members.count))
        }

        /// An edge's length from node centre to node centre.
        func length(_ e: Int) -> Double {
            guard let (a, b) = edges[e].ends else { return SkeletonTracer.length(edges[e].points + edges[e].points.prefix(1)) }
            return SkeletonTracer.length([centre(a)] + edges[e].points + [centre(b)])
        }

        var length: Double { edges.indices.filter { edges[$0].alive }.reduce(0) { $0 + length($1) } }

        func degrees() -> [Int] {
            var degree = [Int](repeating: 0, count: nodes.count)
            for edge in edges where edge.alive { if let (a, b) = edge.ends { degree[a] += 1; degree[b] += 1 } }
            return degree
        }

        /// Removes the short whiskers thinning leaves on a stroke's ends and sides: branches from a junction to a
        /// free end. Repeats, since a fork of whiskers leaves a short stub once they go.
        mutating func pruneSpurs(shorterThan limit: Double) {
            while true {
                let degree = degrees()
                let spurs = edges.indices.filter { e in
                    guard edges[e].alive, let (a, b) = edges[e].ends, a != b else { return false }
                    return min(degree[a], degree[b]) == 1 && max(degree[a], degree[b]) >= 3 && length(e) < limit
                }
                guard !spurs.isEmpty else { return }
                for e in spurs { edges[e].alive = false }
            }
        }

        /// Merges junctions joined by a short branch into one: two thick strokes crossing thin to a pair of forks a
        /// stroke width apart, and the crossing is the pair together. Tiny loops left on a node (a pinhole in the
        /// ink) go too.
        mutating func contractJunctions(closerThan limit: Double) {
            while true {
                let degree = degrees()
                guard let e = edges.indices.first(where: { e in
                    guard edges[e].alive, let (a, b) = edges[e].ends, a != b else { return false }
                    return degree[a] >= 3 && degree[b] >= 3 && length(e) < limit
                }), let (keep, gone) = edges[e].ends else { break }
                edges[e].alive = false
                nodes[keep] += nodes[gone]
                nodes[gone] = []
                for i in edges.indices { if let (a, b) = edges[i].ends { edges[i].ends = (a == gone ? keep : a, b == gone ? keep : b) } }
            }
            for e in edges.indices where edges[e].alive {
                if let (a, b) = edges[e].ends, a == b, length(e) < 2 * limit { edges[e].alive = false }
            }
        }

        // MARK: Walking

        /// End `k` of edge `k / 2`: its start when even, its finish when odd.
        func node(ofEnd k: Int) -> Int? { edges[k / 2].ends.map { k % 2 == 0 ? $0.0 : $0.1 } }

        /// The edge's points leading away from end `k`.
        func points(fromEnd k: Int) -> [Point] { k % 2 == 0 ? edges[k / 2].points : edges[k / 2].points.reversed() }

        /// The points leading away from end `k`, without those within `trim` of its node, where thinning bends the
        /// branches toward the junction.
        func trimmed(fromEnd k: Int, trim: Double) -> [Point] {
            let points = points(fromEnd: k)
            guard let n = node(ofEnd: k) else { return points }
            let c = centre(n)
            return Array(points.drop { distance($0, c) <= trim })
        }

        /// The direction the branch leaves its node at end `k`, read past the bend near the junction.
        func heading(ofEnd k: Int, trim: Double) -> Point {
            let away = trimmed(fromEnd: k, trim: trim)
            guard let anchor = away.first else {
                let all = points(fromEnd: k)
                return node(ofEnd: k).map { unit(all.last!, minus: centre($0)) } ?? (0, 0)
            }
            return unit(SkeletonTracer.point(along: away, at: 10), minus: anchor)
        }

        /// Pairs the branch ends at each node into continuations: at a plain node both ends, at a junction the ends
        /// that line up best (nearly opposite headings), straightest first. An unpaired end finishes a path.
        func links(trim: Double) -> [Int: Int] {
            var atNode: [Int: [Int]] = [:]
            for e in edges.indices where edges[e].alive {
                guard let (a, b) = edges[e].ends else { continue }
                atNode[a, default: []].append(2 * e)
                atNode[b, default: []].append(2 * e + 1)
            }
            var link: [Int: Int] = [:]
            for ends in atNode.values where ends.count >= 2 {
                if ends.count == 2 { link[ends[0]] = ends[1]; link[ends[1]] = ends[0]; continue }
                let headings = Dictionary(uniqueKeysWithValues: ends.map { ($0, heading(ofEnd: $0, trim: trim)) })
                var pairs: [(Int, Int, Double)] = []
                for i in ends.indices { for j in ends.indices where j > i {
                    let u = headings[ends[i]]!, v = headings[ends[j]]!
                    pairs.append((ends[i], ends[j], u.0 * v.0 + u.1 * v.1))
                } }
                for (i, j, alignment) in pairs.sorted(by: { $0.2 < $1.2 }) where alignment < -0.5 && link[i] == nil && link[j] == nil {
                    link[i] = j; link[j] = i
                }
            }
            return link
        }

        /// The skeleton walked into paths: each starts at a free end and follows the pairings until it reaches
        /// another; what is left is closed loops. Paired ends meet in a smooth bridge across the junction.
        func walk(trim: Double) -> [Trace] {
            let link = links(trim: trim)
            var used = [Bool](repeating: false, count: edges.count)
            func piece(_ k: Int) -> [Point] {
                let points = points(fromEnd: k)
                var kept = link[k] == nil ? points : trimmed(fromEnd: k, trim: trim)
                if link[k ^ 1] != nil, let n = node(ofEnd: k ^ 1) {
                    let c = centre(n)
                    while let last = kept.last, distance(last, c) <= trim { kept.removeLast() }
                }
                return kept.isEmpty ? [points[points.count / 2]] : kept
            }
            func run(from first: Int) -> Trace {
                var points: [Point] = []
                if link[first] == nil, let n = node(ofEnd: first) { points.append(centre(n)) }
                var entry = first, next = piece(first)
                while true {
                    used[entry / 2] = true
                    points += next
                    guard let onward = link[entry ^ 1] else {
                        if let n = node(ofEnd: entry ^ 1) { points.append(centre(n)) }
                        return Trace(points: points, closed: false)
                    }
                    next = piece(onward)
                    let into = heading(ofEnd: entry ^ 1, trim: trim), out = heading(ofEnd: onward, trim: trim)
                    points += hermite(from: points.last!, heading: (-into.0, -into.1), to: next[0], heading: out)
                    if onward == first { return Trace(points: points, closed: true) }
                    guard !used[onward / 2] else { return Trace(points: points, closed: false) }
                    entry = onward
                }
            }
            var traces: [Trace] = []
            for e in edges.indices where edges[e].alive && edges[e].ends != nil {
                for k in [2 * e, 2 * e + 1] where !used[e] && link[k] == nil { traces.append(run(from: k)) }
            }
            for e in edges.indices where edges[e].alive && !used[e] {
                if edges[e].ends == nil { used[e] = true; traces.append(Trace(points: edges[e].points, closed: true)) } else { traces.append(run(from: 2 * e)) }
            }
            return traces
        }
    }

    // MARK: - Gaps

    /// Joins path ends that face each other across an erased blob into one path (or closes a path whose two ends
    /// face each other), nearest pair first. Thinning pulls each cut end back about half a stroke, so the reach is
    /// the blob's width plus a little and a stroke width.
    static func bridged(_ traces: [Trace], across blobs: [Blob], width: Double) -> [Trace] {
        var traces = traces
        while let (a, b) = nearestFacingEnds(traces, blobs: blobs, width: width) {
            let first = a.atStart ? Array(traces[a.trace].points.reversed()) : traces[a.trace].points
            if a.trace == b.trace {
                traces[a.trace] = Trace(points: first + hermite(from: a.point, heading: a.heading, to: b.point, heading: (-b.heading.0, -b.heading.1)), closed: true)
                continue
            }
            let second = b.atStart ? traces[b.trace].points : Array(traces[b.trace].points.reversed())
            let joined = first + hermite(from: a.point, heading: a.heading, to: b.point, heading: (-b.heading.0, -b.heading.1)) + second
            traces[a.trace] = Trace(points: joined, closed: false)
            traces.remove(at: b.trace)
        }
        return traces
    }

    struct End {
        let trace: Int, atStart: Bool, point: Point
        /// Pointing out of the path, into the gap.
        let heading: Point
    }

    static func nearestFacingEnds(_ traces: [Trace], blobs: [Blob], width: Double) -> (End, End)? {
        var ends: [End] = []
        for (i, trace) in traces.enumerated() where !trace.closed && trace.points.count >= 2 {
            for atStart in [true, false] {
                let inward = atStart ? trace.points : trace.points.reversed()
                ends.append(End(trace: i, atStart: atStart, point: inward[0], heading: unit(inward[0], minus: point(along: inward, at: 10))))
            }
        }
        var best: (End, End, Double)?
        for i in ends.indices { for j in ends.indices where j > i {
            let a = ends[i], b = ends[j]
            guard a.trace != b.trace || a.atStart != b.atStart else { continue }
            let gap = distance(a.point, b.point)
            guard gap > 0 else { continue }
            let across = ((b.point.0 - a.point.0) / gap, (b.point.1 - a.point.1) / gap)
            let facing = a.heading.0 * across.0 + a.heading.1 * across.1 > 0.5
                && -(b.heading.0 * across.0 + b.heading.1 * across.1) > 0.5
                && a.heading.0 * b.heading.0 + a.heading.1 * b.heading.1 < -0.3
            let middle = ((a.point.0 + b.point.0) / 2, (a.point.1 + b.point.1) / 2)
            let overBlob = blobs.contains { gap <= 2 * $0.radius + 4 + 2 * width && distance(middle, ($0.x, $0.y)) <= $0.radius + 2 }
            if facing, overBlob, gap < best?.2 ?? .infinity { best = (a, b, gap) }
        } }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: - Geometry

    /// The points strictly between `a` and `b` on a cubic Hermite curve leaving `a` along `u` and arriving at `b`
    /// along `v` (unit headings), about a pixel apart: a bridge that keeps the curve's direction on both sides.
    static func hermite(from a: Point, heading u: Point, to b: Point, heading v: Point) -> [Point] {
        let span = distance(a, b)
        let steps = Int(span.rounded(.up))
        guard steps >= 2 else { return [] }
        return (1..<steps).map { i in
            let t = Double(i) / Double(steps), t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
            return (h00 * a.0 + h10 * span * u.0 + h01 * b.0 + h11 * span * v.0,
                    h00 * a.1 + h10 * span * u.1 + h01 * b.1 + h11 * span * v.1)
        }
    }

    /// The path smoothed over five samples (ends kept where they are) and resampled about 2 px apart.
    static func finished(_ trace: Trace) -> [Point] {
        let points = trace.points, n = points.count
        let smoothed: [Point] = points.indices.map { i in
            let half = trace.closed ? min(2, (n - 1) / 2) : min(2, i, n - 1 - i)
            guard half > 0 else { return points[i] }
            var x = 0.0, y = 0.0
            for d in -half...half { let p = points[(i + d + n) % n]; x += p.0; y += p.1 }
            return (x / Double(2 * half + 1), y / Double(2 * half + 1))
        }
        return resampled(trace.closed ? smoothed + [smoothed[0]] : smoothed, spacing: 2)
    }

    static func resampled(_ points: [Point], spacing: Double) -> [Point] {
        guard let first = points.first else { return [] }
        var out = [first], owed = spacing
        for (a, b) in zip(points, points.dropFirst()) {
            let step = distance(a, b)
            var at = owed
            while at <= step {
                let t = at / step
                out.append((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
                at += spacing
            }
            owed = at - step
        }
        if let last = points.last, distance(out.last!, last) > spacing / 4 { out.append(last) } else { out[out.count - 1] = points.last! }
        return out
    }

    static func length(_ points: [Point]) -> Double { zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) } }

    /// The first point at least `arc` along the path from its start, or its last point.
    static func point(along points: [Point], at arc: Double) -> Point {
        var travelled = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            travelled += distance(a, b)
            if travelled >= arc { return b }
        }
        return points.last!
    }

    static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.0 - b.0, a.1 - b.1) }

    static func unit(_ a: Point, minus b: Point) -> Point {
        let d = distance(a, b)
        return d > 0 ? ((a.0 - b.0) / d, (a.1 - b.1) / d) : (0, 0)
    }
}
