import CloudTuneCore
import CloudTuneUI
import Foundation
import Testing

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Suite("CloudTuneUI Draft Isolation & Offscreen Light/Dark Snapshot Verification")
struct CloudTuneUITests {
    @Test("Settings draft edits stay isolated from committedSettings across module switches and validate on commit")
    @MainActor
    func verifyDraftSettingsIsolation() async throws {
        let fixtureURL = repoRootURL().appendingPathComponent("contracts/representative-state.json")
        let fixture = try RepresentativeFixture.load(from: fixtureURL)
        let vm = CloudTuneViewModel.fixture(scene: .music, fixture: fixture)

        #expect(vm.committedSettings.cacheLimitMb == 2048)
        #expect(vm.committedSettings.downloadThreads == 8)

        // Invalid draft must NOT overwrite committedSettings and must survive tab switches
        vm.cacheLimitDraft = "128"
        vm.activeModule = .video
        vm.activeModule = .music
        #expect(vm.cacheLimitDraft == "128")
        #expect(vm.committedSettings.cacheLimitMb == 2048)

        let rejected = await vm.commitCacheLimitDraft()
        #expect(rejected == false)
        #expect(vm.settingsValidationError != nil)
        #expect(vm.committedSettings.cacheLimitMb == 2048)

        // Editing draft resets stale error immediately
        vm.cacheLimitDraft = "4096"
        vm.noteDraftEdited()
        #expect(vm.settingsValidationError == nil)

        let accepted = await vm.commitCacheLimitDraft()
        #expect(accepted == true)
        #expect(vm.committedSettings.cacheLimitMb == 4096)

        // Remote pause command must be idempotent (never start playing when already paused)
        vm.pauseIfPlaying()
        #expect(vm.isPlaying == false)
        vm.pauseIfPlaying()
        #expect(vm.isPlaying == false)

        // Unsupported local .ape codec failure must immediately stop playback and show guidance
        let apeTrack = TrackSummary(id: "ape-1", name: "Archive.ape", folderPath: "Lossless", sizeBytes: 1024)
        vm.isPlaying = true
        await vm.handlePlaybackPreparationFailure(
            track: apeTrack,
            error: CloudTuneError.unsupportedLocalMediaFormat("decode failed"),
            wasLoopback: false,
            resumeTime: 0
        )
        #expect(vm.isPlaying == false)
        #expect(vm.statusMessage?.contains(".ape") == true)
    }

    @Test("QRCodeGenerator maintains high-contrast dark-on-light substrate")
    func verifyQRCodeRendering() throws {
        let png = try #require(QRCodeGenerator.generatePNGData(content: "https://open.e.189.cn/qr/test", dimension: 320))
        let metrics = try SnapshotRenderer.analyzePNGData(png)
        #expect(metrics.width >= 300)
        #expect(metrics.meanLuminance > 0.45)
        #expect(metrics.highContrastPixelCount > 400)
    }

    #if os(macOS)
    @Test("macOS full-state Light & Dark offscreen PNG rendering and glyph pixel contrast")
    @MainActor
    func verifyMacOSLightAndDarkSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDTUNE_RENDER_SNAPSHOTS"] == "1" else {
            return
        }
        let root = repoRootURL()
        let fixture = try RepresentativeFixture.load(from: root.appendingPathComponent("contracts/representative-state.json"))
        let outRoot = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDTUNE_SNAPSHOT_DIR"]
                ?? root.appendingPathComponent("dist/snapshots/macos").path
        )
        try FileManager.default.createDirectory(at: outRoot.appendingPathComponent("light"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outRoot.appendingPathComponent("dark"), withIntermediateDirectories: true)

        for scene in SnapshotScene.allCases {
            let lightPNG = try SnapshotRenderer.renderMacScenePNG(scene: scene, fixture: fixture, isDark: false)
            let darkPNG = try SnapshotRenderer.renderMacScenePNG(scene: scene, fixture: fixture, isDark: true)

            try lightPNG.write(to: outRoot.appendingPathComponent("light/\(scene.rawValue).png"), options: .atomic)
            try darkPNG.write(to: outRoot.appendingPathComponent("dark/\(scene.rawValue).png"), options: .atomic)

            let lightMetrics = try SnapshotRenderer.analyzePNGData(lightPNG)
            let darkMetrics = try SnapshotRenderer.analyzePNGData(darkPNG)

            #expect(lightMetrics.isNonBlankAndLegible, "Light snapshot \(scene.rawValue) failed pixel contrast check")
            #expect(darkMetrics.isNonBlankAndLegible, "Dark snapshot \(scene.rawValue) failed pixel contrast check")
            #expect(lightMetrics.meanLuminance > 0.65, "Light snapshot \(scene.rawValue) should have warm light luminance")
            #expect(darkMetrics.meanLuminance < 0.35, "Dark snapshot \(scene.rawValue) should have pine-night dark luminance")
        }
    }
    #endif
}
