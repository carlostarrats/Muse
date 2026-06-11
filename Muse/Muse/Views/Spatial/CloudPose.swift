//
//  CloudPose.swift
//  Muse
//
//  One card's pose on the cloud stage, in reference-canvas pixels.
//  The 25 measured poses were fitted from the Sternberg Press reference
//  (traced corners -> rigid tilted-rectangle fit, worst error 0.6% of
//  canvas) — see docs/superpowers/assets/cloud-pose-prototype.html and
//  cloud-poses.json. w/h here already include the fitted scale.
//  Angles are CSS-space degrees (x right, y down, z toward viewer),
//  applied rotateZ -> rotateY -> rotateX. CloudMath converts to SceneKit.
//

import Foundation

struct CloudPose: Equatable {
    var w: Double
    var h: Double
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
    var rz: Double

    /// Reference stage size and perspective the poses were measured in.
    static let refW: Double = 1999
    static let refH: Double = 1064
    static let f: Double = 1100

    static let measured: [CloudPose] = [
        .init(w: 194.0, h: 219.4, cx: 337.5, cy: 199.4, rx: -33.0, ry: -30.4, rz: 47.5),
        .init(w: 80.5, h: 224.2, cx: 487.5, cy: 417.8, rx: -29.8, ry: -28.6, rz: 23.9),
        .init(w: 103.4, h: 180.8, cx: 605.4, cy: 387.6, rx: -20.9, ry: -21.6, rz: 22.3),
        .init(w: 178.6, h: 147.3, cx: 384.9, cy: 579.5, rx: 20.4, ry: -19.1, rz: 6.3),
        .init(w: 123.5, h: 175.2, cx: 553.9, cy: 593.1, rx: 11.4, ry: -10.0, rz: 11.2),
        .init(w: 154.1, h: 230.8, cx: 771.9, cy: 567.1, rx: -11.2, ry: -10.2, rz: 10.4),
        .init(w: 203.6, h: 237.9, cx: 941.4, cy: 493.5, rx: 23.6, ry: 21.8, rz: -8.5),
        .init(w: 119.9, h: 153.5, cx: 1036.2, cy: 309.6, rx: -11.4, ry: 6.2, rz: 8.5),
        .init(w: 113.4, h: 249.0, cx: 1187.6, cy: 375.8, rx: -27.3, ry: -25.3, rz: 25.9),
        .init(w: 114.4, h: 219.8, cx: 1375.0, cy: 383.4, rx: 23.2, ry: 21.4, rz: 20.2),
        .init(w: 177.3, h: 175.5, cx: 1537.1, cy: 288.7, rx: 7.4, ry: -12.0, rz: 15.9),
        .init(w: 88.5, h: 138.1, cx: 1472.1, cy: 480.7, rx: 2.8, ry: -5.8, rz: 13.2),
        .init(w: 248.8, h: 223.8, cx: 1681.8, cy: 417.6, rx: 16.9, ry: -17.8, rz: 16.3),
        .init(w: 128.8, h: 159.7, cx: 1241.9, cy: 579.4, rx: 18.1, ry: -18.4, rz: 16.4),
        .init(w: 216.2, h: 227.0, cx: 1088.6, cy: 669.5, rx: 14.4, ry: -13.9, rz: 25.9),
        .init(w: 142.8, h: 190.0, cx: 1425.6, cy: 709.2, rx: -3.3, ry: -7.6, rz: 14.3),
        .init(w: 162.4, h: 237.6, cx: 1603.4, cy: 748.5, rx: -0.3, ry: -8.0, rz: 21.0),
        .init(w: 148.9, h: 137.0, cx: 1771.4, cy: 680.4, rx: 26.0, ry: -24.7, rz: 12.5),
        .init(w: 124.3, h: 234.7, cx: 1275.4, cy: 849.0, rx: -16.1, ry: -16.1, rz: 25.4),
        .init(w: 225.9, h: 242.6, cx: 228.8, cy: 843.4, rx: 21.9, ry: -13.3, rz: -4.9),
        .init(w: 97.8, h: 297.9, cx: 420.1, cy: 918.1, rx: 31.7, ry: -26.2, rz: 30.8),
        .init(w: 126.3, h: 188.5, cx: 634.0, cy: 789.6, rx: 11.6, ry: -14.1, rz: 21.7),
        .init(w: 206.1, h: 301.9, cx: 848.2, cy: 831.0, rx: 24.7, ry: -14.7, rz: -6.8),
        .init(w: 124.5, h: 231.7, cx: 974.2, cy: 821.7, rx: 7.2, ry: -9.5, rz: 8.8),
        .init(w: 514.8, h: 114.6, cx: 1732.1, cy: 1006.4, rx: 8.8, ry: 0.4, rz: 0.4),
    ]
}
