import NetworkExtension
import XCTest
@testable import AwgScale

@MainActor
final class VPNLifecycleTests: XCTestCase {
    func testAlreadyStoppedCompletesWithoutPollingAgain() async throws {
        for stoppedStatus: NEVPNStatus in [.disconnected, .invalid] {
            var reads = 0
            try await waitForVPNStopped(timeout: 0) {
                reads += 1
                return stoppedStatus
            }
            XCTAssertEqual(reads, 1)
        }
    }

    func testDisconnectingMustBecomeDisconnectedBeforeContinuing() async throws {
        var statuses: [NEVPNStatus] = [.connected, .disconnecting, .disconnected]
        var observed: [NEVPNStatus] = []
        try await waitForVPNStopped(timeout: 1, pollIntervalNanoseconds: 1) {
            let status = statuses.removeFirst()
            observed.append(status)
            return status
        }
        XCTAssertEqual(observed, [.connected, .disconnecting, .disconnected])
        XCTAssertTrue(statuses.isEmpty)
    }

    func testTimeoutDoesNotPermitRestartOrStateDeletion() async {
        for activeStatus: NEVPNStatus in [.connected, .connecting, .reasserting, .disconnecting] {
            var performedNextOperation = false
            do {
                try await waitForVPNStopped(timeout: 0) { activeStatus }
                performedNextOperation = true
                XCTFail("An active tunnel must not count as stopped")
            } catch VPNError.stopTimeout {
                // Expected: the caller must keep the old owner's state intact.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(performedNextOperation)
        }
    }

    func testCancellationDoesNotPermitNextOperationEvenIfStopped() async {
        var performedNextOperation = false
        let task = Task { @MainActor in
            try await waitForVPNStopped(timeout: 1) { .disconnected }
            performedNextOperation = true
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled transition must not continue")
        } catch is CancellationError {
            // Expected even if the connection has just finished stopping.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(performedNextOperation)
    }

    func testCancellationDuringStopWaitPropagates() async {
        var statusReads = 0
        let task = Task { @MainActor in
            try await waitForVPNStopped(timeout: 60) {
                statusReads += 1
                return .disconnecting
            }
        }
        while statusReads == 0 { await Task.yield() }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled wait must throw")
        } catch is CancellationError {
            // Task.sleep must propagate cancellation rather than swallow it.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(statusReads, 1)
    }
}
