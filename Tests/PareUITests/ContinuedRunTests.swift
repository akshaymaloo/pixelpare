import Foundation
import PareEngine
import Testing
@testable import PareUI

@MainActor
private final class FakeHandle: ContinuedTaskHandle {
    var results: [Bool] = []
    func complete(success: Bool) { results.append(success) }
}

@MainActor
@Suite struct ContinuedRunTests {
    @Test func finishDuringExpiryCleanupCompletesExactlyOnce() async {
        let gate = ContinuedCompletion(), h = FakeHandle()
        gate.attach(h)
        await gate.expire { gate.finish(success: true) }   // the run ends while cleanup is suspended
        #expect(h.results == [false])
    }

    @Test func expiryAfterFinishDoesNothing() async {
        let gate = ContinuedCompletion(), h = FakeHandle()
        gate.attach(h)
        gate.finish(success: true)
        await gate.expire { }
        #expect(h.results == [true])
    }

    @Test func secondExpiryAndFinishAreIgnored() async {
        let gate = ContinuedCompletion(), h = FakeHandle()
        gate.attach(h)
        await gate.expire { }
        await gate.expire { }
        gate.finish(success: true)
        #expect(h.results == [false])
    }

    @Test func taskArrivingAfterFinishIsCompletedImmediately() {
        let gate = ContinuedCompletion(), h = FakeHandle()
        gate.finish(success: true)
        gate.attach(h)
        #expect(h.results == [true])
    }
}

@Suite struct ContinuedProgressTests {
    @Test func progressAdvancesWithinAJobAndNeverGoesBack() {
        var u = 0
        let steps: [(PipelineStep, Double?)] = [(.download, 0.5), (.download, 1), (.encode, 0.2), (.encode, 1), (.verify, nil), (.importCopy, nil)]
        for (s, f) in steps {
            let next = ContinuedProgress.advance(previous: u, step: s, fraction: f)
            #expect(next >= u); u = next
        }
        #expect(u > 80 && u < 100)
        // A retry restarting the download must not move the bar back.
        #expect(ContinuedProgress.advance(previous: u, step: .download, fraction: 0.1) == u)
        #expect(ContinuedProgress.advance(previous: u, step: .remove, fraction: nil, finished: true) == 100)
    }

    @Test func unfinishedJobNeverReachesFullUnits() {
        #expect(ContinuedProgress.advance(previous: 0, step: .remove, fraction: 1) < ContinuedProgress.unitsPerJob)
    }
}
