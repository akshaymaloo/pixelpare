import Testing
import Foundation
@testable import PareCore

struct PresetPolicyTests {
    @Test func normalVideoIsEligible() {
        #expect(PresetPolicy.eligibility(video("v")) == .eligible)
    }

    @Test func skipsHDRSlowMoEdited() {
        var v = video("v"); v.isHDR = true
        #expect(PresetPolicy.eligibility(v) == .skipped(.hdr))
        v = video("v"); v.isSlowMo = true
        #expect(PresetPolicy.eligibility(v) == .skipped(.slowMo))
        v = video("v"); v.isEdited = true
        #expect(PresetPolicy.eligibility(v) == .skipped(.edited))
    }

    @Test func skipsShortAndSmall() {
        #expect(PresetPolicy.eligibility(video("v", dur: 2)) == .skipped(.tooShort))
        #expect(PresetPolicy.eligibility(video("v", size: 10_000_000)) == .skipped(.tooSmall))
    }

    @Test func skipsAlreadyEfficientHEVCButNotLowEfficiencyOrH264() {
        // 4K30 60 s at ~0.04 bpp ≈ 60 MB HEVC
        #expect(PresetPolicy.eligibility(video("v", size: 60_000_000, codec: "hvc1")) == .skipped(.alreadyEfficient))
        #expect(PresetPolicy.eligibility(video("v", size: 60_000_000, codec: "avc1")) == .eligible)
        #expect(PresetPolicy.eligibility(video("v", size: 400_000_000, codec: "hvc1")) == .eligible)
    }

    @Test func unknownSizeIsNotSkipped() {
        #expect(PresetPolicy.eligibility(video("v", size: nil)) == .eligible)
    }

    @Test func nonVideoSkipped() {
        #expect(PresetPolicy.eligibility(photo("p")) == .skipped(.notVideo))
    }

    @Test func gentleAndBalancedKeepResolutionAndFPS() throws {
        let v = video("v", fps: 60)
        let g = try #require(PresetPolicy.settings(for: v, preset: .gentle))
        let b = try #require(PresetPolicy.settings(for: v, preset: .balanced))
        #expect(g.width == 3840 && g.height == 2160 && g.frameRate == 60 && g.codec == "hvc1")
        #expect(b.width == 3840 && b.frameRate == 60)
        #expect(g.bitsPerPixel > b.bitsPerPixel)
        #expect(g.quality! > b.quality!)
    }

    @Test func smallerResolutionCapsLongEdgeWithEvenDimensions() throws {
        let s = try #require(PresetPolicy.settings(for: video("v", w: 3840, h: 2160), preset: .smallerResolution))
        #expect(s.width == 1920 && s.height == 1080)
        let odd = try #require(PresetPolicy.settings(for: video("v", w: 4001, h: 3001), preset: .smallerResolution))
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0 && max(odd.width, odd.height) <= 1920)
        let portrait = try #require(PresetPolicy.settings(for: video("v", w: 2160, h: 3840), preset: .smallerResolution))
        #expect(portrait.width == 1080 && portrait.height == 1920)
    }

    @Test func smallerResolutionNilAt1080pOrBelow() {
        #expect(PresetPolicy.settings(for: video("v", w: 1920, h: 1080), preset: .smallerResolution) == nil)
        #expect(PresetPolicy.settings(for: video("v", w: 1280, h: 720), preset: .smallerResolution) == nil)
    }

    @Test func neverUpscales() throws {
        for preset in VideoPreset.allCases {
            if let s = PresetPolicy.settings(for: video("v", w: 1280, h: 720), preset: preset) {
                #expect(s.width <= 1280 && s.height <= 720)
            }
        }
    }

    @Test func estimateRangeAndNeverLargerThanOriginal() {
        for preset in VideoPreset.allCases {
            let v = video("v", size: 150_000_000)
            let e = PresetPolicy.estimate(v, preset: preset)
            #expect(e.state == .estimate)
            #expect(e.low <= e.high && e.high <= 150_000_000)
        }
        // Tiny original: clamp to original.
        let small = video("v", size: 1_000_000)
        #expect(PresetPolicy.estimate(small, preset: .gentle).high <= 1_000_000)
    }

    @Test func estimateOrdering() {
        let v = video("v", size: 2_000_000_000)
        let g = PresetPolicy.estimate(v, preset: .gentle)
        let b = PresetPolicy.estimate(v, preset: .balanced)
        let s = PresetPolicy.estimate(v, preset: .smallerResolution)
        #expect(g.high > b.high && b.high > s.high)
        let mid = Double(b.low + b.high) / 2
        #expect(abs(Double(b.high - b.low) / mid - 0.30) < 0.01) // ±15% of midpoint
    }

    @Test func estimateWhenPresetNotApplicableIsOriginalSize() {
        let v = video("v", w: 1280, h: 720, size: 50_000_000)
        let e = PresetPolicy.estimate(v, preset: .smallerResolution)
        #expect(e.low == 50_000_000 && e.high == 50_000_000)
    }
}
