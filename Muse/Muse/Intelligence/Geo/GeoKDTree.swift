//
//  GeoKDTree.swift
//  Muse
//
//  Pure geo math shared by offline reverse geocoding (ReverseGeocoder) and the
//  `.near` search-token / smart-rule evaluation.
//
//  A 3-D k-d tree over unit-sphere CARTESIAN coordinates, not a 2-D lat/lon
//  tree: Euclidean (chord) distance on the unit sphere is monotone in
//  great-circle distance, so the nearest point found this way is exactly the
//  nearest by great-circle distance — and the antimeridian and the poles,
//  which a lat/lon tree gets badly wrong, stop being special cases at all.
//

import Foundation

/// Mean Earth radius (km) — the one place this constant is declared.
private let earthRadiusKM = 6371.0

private struct SpherePoint {
    let x: Double, y: Double, z: Double
    let index: Int
}

private func toCartesian(lat: Double, lon: Double) -> (x: Double, y: Double, z: Double) {
    let latRad = lat * .pi / 180
    let lonRad = lon * .pi / 180
    return (cos(latRad) * cos(lonRad), cos(latRad) * sin(lonRad), sin(latRad))
}

nonisolated struct GeoKDTree {
    private indirect enum Node {
        case leaf
        case branch(point: SpherePoint, axis: Int, left: Node, right: Node)
    }
    private let root: Node
    private let empty: Bool

    init(points: [(lat: Double, lon: Double)]) {
        let spherePoints = points.enumerated().map { i, p -> SpherePoint in
            let c = toCartesian(lat: p.lat, lon: p.lon)
            return SpherePoint(x: c.x, y: c.y, z: c.z, index: i)
        }
        empty = spherePoints.isEmpty
        root = Self.build(spherePoints, depth: 0)
    }

    private static func build(_ points: [SpherePoint], depth: Int) -> Node {
        guard !points.isEmpty else { return .leaf }
        let axis = depth % 3
        let sorted = points.sorted { lhs, rhs in
            switch axis {
            case 0: return lhs.x < rhs.x
            case 1: return lhs.y < rhs.y
            default: return lhs.z < rhs.z
            }
        }
        let mid = sorted.count / 2
        return .branch(point: sorted[mid], axis: axis,
                       left: build(Array(sorted[..<mid]), depth: depth + 1),
                       right: build(Array(sorted[(mid + 1)...]), depth: depth + 1))
    }

    /// Index of the nearest input point + great-circle distance in km. nil for
    /// an empty tree.
    func nearest(lat: Double, lon: Double) -> (index: Int, distanceKM: Double)? {
        guard !empty else { return nil }
        let q = toCartesian(lat: lat, lon: lon)
        var best: (point: SpherePoint, distSq: Double)?
        search(root, query: q, best: &best)
        guard let best else { return nil }
        // Chord length → central angle → great-circle distance. Exact, not an
        // approximation: chord distance is monotone in central angle.
        let chord = sqrt(best.distSq)
        let angle = 2 * asin(min(1, chord / 2))
        return (best.point.index, angle * earthRadiusKM)
    }

    private func search(_ node: Node, query: (x: Double, y: Double, z: Double),
                        best: inout (point: SpherePoint, distSq: Double)?) {
        guard case let .branch(point, axis, left, right) = node else { return }
        let dx = query.x - point.x, dy = query.y - point.y, dz = query.z - point.z
        let distSq = dx * dx + dy * dy + dz * dz
        if best == nil || distSq < best!.distSq { best = (point, distSq) }

        let diff: Double
        switch axis {
        case 0: diff = query.x - point.x
        case 1: diff = query.y - point.y
        default: diff = query.z - point.z
        }
        let (nearSide, farSide) = diff < 0 ? (left, right) : (right, left)
        search(nearSide, query: query, best: &best)
        // The far side can only hold something closer if the splitting plane
        // itself is nearer than the best so far.
        if diff * diff < (best?.distSq ?? .greatestFiniteMagnitude) {
            search(farSide, query: query, best: &best)
        }
    }
}

nonisolated enum GreatCircle {
    /// Haversine great-circle distance in km.
    static func distanceKM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusKM * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

nonisolated enum GeoBounds {
    /// Bounding box(es) in degrees for a radius query — the SQL prefilter that
    /// lets the v13 partial index do the work before an exact haversine pass
    /// in Swift. Splits into two ranges when the box crosses ±180°.
    static func boxes(lat: Double, lon: Double, radiusKM: Double)
        -> [(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>)] {
        let latDelta = radiusKM / 111.32
        let latMin = max(-90, lat - latDelta)
        let latMax = min(90, lat + latDelta)
        // Longitude degrees-per-km shrinks toward the poles; clamp cos away
        // from zero so a polar query doesn't produce an infinite span.
        let cosLat = max(cos(lat * .pi / 180), 0.01)
        let lonDelta = radiusKM / (111.32 * cosLat)
        let lonMin = lon - lonDelta
        let lonMax = lon + lonDelta

        if lonDelta >= 180 {
            // The span wraps the whole globe — one box covering everything is
            // both correct and cheaper than two overlapping ones.
            return [(latMin...latMax, -180...180)]
        }
        if lonMin < -180 {
            return [(latMin...latMax, (lonMin + 360)...180), (latMin...latMax, -180...lonMax)]
        }
        if lonMax > 180 {
            return [(latMin...latMax, lonMin...180), (latMin...latMax, -180...(lonMax - 360))]
        }
        return [(latMin...latMax, lonMin...lonMax)]
    }
}
