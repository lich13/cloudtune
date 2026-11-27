import CloudTuneCore
import CloudTuneUI
import Foundation
import XCTest

final class CloudTuneIOSSnapshotTests: XCTestCase {
    @MainActor
    func testRenderIPhoneAndIPadLightDarkSnapshots() throws {
        guard let fixtureURL = Bundle(for: Self.self).url(forResource: "representative-state", withExtension: "json") else {
            XCTFail("Missing representative-state.json in test bundle")
            return
        }
        let fixture = try RepresentativeFixture.load(from: fixtureURL)
        let outBase = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDTUNE_IOS_SNAPSHOT_DIR"]
                ?? "/tmp/cloudtune-ios-snapshots"
        )

        for (deviceName, isIPad) in [("iphone", false), ("ipad", true)] {
            for (themeName, isDark) in [("light", false), ("dark", true)] {
                let dir = outBase.appendingPathComponent("\(deviceName)/\(themeName)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for scene in SnapshotScene.allCases {
                    let png = try SnapshotRenderer.renderIOSScenePNG(
                        scene: scene,
                        fixture: fixture,
                        isDark: isDark,
                        isIPad: isIPad
                    )
                    try png.write(to: dir.appendingPathComponent("\(scene.rawValue).png"), options: .atomic)
                    let metrics = try SnapshotRenderer.analyzePNGData(png)
                    XCTAssertTrue(metrics.isNonBlankAndLegible, "\(deviceName) \(themeName) \(scene.rawValue) failed contrast check")
                    if isDark {
                        XCTAssertLessThan(metrics.meanLuminance, 0.36)
                    } else {
                        XCTAssertGreaterThan(metrics.meanLuminance, 0.58)
                    }
                }
            }
        }
    }
}
