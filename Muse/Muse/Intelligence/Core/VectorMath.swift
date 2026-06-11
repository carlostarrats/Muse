import Foundation

enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
    static func toData(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func fromData(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
