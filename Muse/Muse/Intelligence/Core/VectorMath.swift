import Foundation
import Accelerate

nonisolated enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)   // dot = a·b
        vDSP_svesq(a, 1, &na, n)          // na  = Σ aᵢ²
        vDSP_svesq(b, 1, &nb, n)          // nb  = Σ bᵢ²
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot) / (Double(na).squareRoot() * Double(nb).squareRoot())
    }
    static func toData(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func fromData(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
