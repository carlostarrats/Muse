//
//  EditKernels.swift
//  Muse
//
//  Loads the stitchable kernels from the default metallib and holds the
//  renderer's tuning constants.
//
//  Every radius here is a FRACTION OF THE SOURCE LONG EDGE, never a pixel
//  count. That is the single rule that makes a 320px thumbnail, the on-screen
//  proxy and a 60 MP export agree: a fixed 3px blur is a heavy vignette on a
//  thumbnail and invisible on an export. `EditRenderConsistencyTests` is the
//  permanent gate on it.
//

import CoreImage

nonisolated enum EditKernels {
    // Owner-tunable first guesses — expected to move once real photos are graded.
    static let clarityRadiusFraction: CGFloat = 0.015
    static let textureRadiusFraction: CGFloat = 0.003
    static let sharpenRadiusFraction: CGFloat = 0.0008
    /// Vignette feather, also a long-edge fraction for the same reason.
    static let vignetteRadiusFraction: CGFloat = 0.75

    /// Loading is lazy and NON-fatal: a metallib that failed to build must not
    /// crash the app on first slider drag. `EditRenderer` treats a nil kernel
    /// as "skip this stage", so the photo still renders (minus that effect),
    /// and `EditKernelLoadTests` is what makes a broken Metal build phase fail
    /// in CI instead of silently degrading for users.
    static let toneBands: CIColorKernel? = load("toneBands")
    static let clarityTexture: CIKernel? = loadGeneral("clarityTexture")

    // MARK: - Spec 05

    /// Clipping zebras. `zebraPeriodPx` is mirrored in the kernel source — it
    /// is a screen-space pattern, deliberately NOT a long-edge fraction: the
    /// stripes exist to be seen at canvas resolution, not to survive a rescale.
    static let zebraStripes: CIColorKernel? = load("zebraStripes")
    static let zebraPeriodPx: CGFloat = 8

    /// Tone-zone guided filter + application.
    static let tzLog2Luma: CIColorKernel? = load("tzLog2Luma")
    static let tzSquare: CIColorKernel? = load("tzSquare")
    static let tzLinearCoeffs: CIColorKernel? = load("tzLinearCoeffs")
    static let tzApplyCoeffs: CIColorKernel? = load("tzApplyCoeffs")
    static let toneZoneGain: CIColorKernel? = load("toneZoneGain")

    /// Zone overlay. The floor is mirrored in the kernel source.
    static let zoneHatch: CIColorKernel? = load("zoneHatch")
    static let overlayWeightFloor: Float = 0.5
    static let hatchPeriodPx: CGFloat = 10

    /// LUT strength mix.
    static let lutMix: CIColorKernel? = load("lutMix")

    private static var libraryData: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib")
        else { return nil }
        return try? Data(contentsOf: url)
    }()

    private static func load(_ name: String) -> CIColorKernel? {
        guard let data = libraryData else { return nil }
        return try? CIColorKernel(functionName: name, fromMetalLibraryData: data)
    }

    private static func loadGeneral(_ name: String) -> CIKernel? {
        guard let data = libraryData else { return nil }
        return try? CIKernel(functionName: name, fromMetalLibraryData: data)
    }
}
