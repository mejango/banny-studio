import Foundation
import XCTest
@testable import BannyLive

final class LiveRoomFramePipelineTests: XCTestCase {
    func testCancelingOneViewerDoesNotCancelSharedFrameForAnother() async throws {
        let clock = FrameTestClock()
        let cache = LiveRoomJPEGCache(clockMS: { clock.get() })
        let producer = GatedFrameProducer(data: Data([1, 2, 3]))

        let first = Task {
            try await cache.jpeg(epoch: 1) { try await producer.render() }
        }
        await producer.waitUntilStarted()
        let second = Task {
            try await cache.jpeg(epoch: 1) { try await producer.render() }
        }
        let bothAttached = await waitForWaiters(cache, count: 2)
        XCTAssertTrue(bothAttached)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("A canceled viewer should return immediately")
        } catch is CancellationError {
            // Expected. The shared producer still has the second viewer.
        }
        let survivorAttached = await waitForWaiters(cache, count: 1)
        let cancellationsBeforeRelease = await producer.cancellationCount()
        XCTAssertTrue(survivorAttached)
        XCTAssertEqual(cancellationsBeforeRelease, 0)

        await producer.release()
        let secondValue = try await second.value
        let starts = await cache.renderStartCount()
        XCTAssertEqual(secondValue, Data([1, 2, 3]))
        XCTAssertEqual(starts, 1)
    }

    func testCancelingLastViewerCancelsProducerAndClearsFlight() async throws {
        let cache = LiveRoomJPEGCache(clockMS: { 0 })
        let producer = CancellationObservingProducer()
        let request = Task {
            try await cache.jpeg(epoch: 1) { try await producer.render() }
        }
        await producer.waitUntilStarted()

        request.cancel()
        do {
            _ = try await request.value
            XCTFail("A canceled viewer should not wait for rendering")
        } catch is CancellationError {
            // Expected.
        }
        await producer.waitUntilCanceled()
        let hasFlight = await cache.hasFlight()
        let waiterCount = await cache.waiterCount()
        XCTAssertFalse(hasFlight)
        XCTAssertEqual(waiterCount, 0)
    }

    func testFailedFrameFlightCanRetryAndExpiredBytesAreEvicted() async throws {
        let clock = FrameTestClock()
        let cache = LiveRoomJPEGCache(clockMS: { clock.get() })
        let producer = FailingOnceFrameProducer()

        do {
            _ = try await cache.jpeg(epoch: 4) { try await producer.render() }
            XCTFail("The first render should fail")
        } catch FramePipelineTestError.expectedFailure {
            // Expected.
        }
        let recovered = try await cache.jpeg(epoch: 4) {
            try await producer.render()
        }
        XCTAssertEqual(recovered, Data([4]))
        let starts = await cache.renderStartCount()
        let cachedBeforeExpiry = await cache.hasCachedFrame()
        XCTAssertEqual(starts, 2)
        XCTAssertTrue(cachedBeforeExpiry)

        clock.advance(by: 125)
        await cache.evictExpired()
        let cachedAfterExpiry = await cache.hasCachedFrame()
        XCTAssertFalse(cachedAfterExpiry)
    }

    func testStaleEpochCannotCancelNewerFrameFlight() async throws {
        let cache = LiveRoomJPEGCache(clockMS: { 0 })
        let producer = GatedFrameProducer(data: Data([5]))
        let current = Task {
            try await cache.jpeg(epoch: 2) { try await producer.render() }
        }
        await producer.waitUntilStarted()

        do {
            _ = try await cache.jpeg(epoch: 1) { Data([1]) }
            XCTFail("An older caller must not replace newer render work")
        } catch {
            XCTAssertEqual(error as? LiveRoomFrameError, .superseded)
        }
        let currentWaiters = await cache.waiterCount()
        let cancellations = await producer.cancellationCount()
        XCTAssertEqual(currentWaiters, 1)
        XCTAssertEqual(cancellations, 0)

        await producer.release()
        let currentValue = try await current.value
        let starts = await cache.renderStartCount()
        XCTAssertEqual(currentValue, Data([5]))
        XCTAssertEqual(starts, 1)
    }

    func testTerminalSealPinsFinalFlightAndBecomesAbsorbing() async throws {
        let cache = LiveRoomJPEGCache(clockMS: { 0 })
        let producer = GatedFrameProducer(data: Data([6]))
        let seal = Task {
            try await cache.seal(epoch: 3) { try await producer.render() }
        }
        await producer.waitUntilStarted()

        do {
            _ = try await cache.jpeg(epoch: 2) { Data([2]) }
            XCTFail("A stale live frame must not cancel terminal sealing")
        } catch {
            XCTAssertEqual(error as? LiveRoomFrameError, .superseded)
        }
        let terminalViewer = Task {
            try await cache.jpeg(epoch: 3) { Data([0]) }
        }
        let terminalWaiters = await waitForWaiters(cache, count: 2)
        XCTAssertTrue(terminalWaiters)

        await producer.release()
        let sealedValue = try await seal.value
        let viewerValue = try await terminalViewer.value
        XCTAssertEqual(sealedValue, Data([6]))
        XCTAssertEqual(viewerValue, Data([6]))

        let staleAfterEnd = try await cache.jpeg(epoch: 1) { Data([1]) }
        let starts = await cache.renderStartCount()
        let isSealed = await cache.isSealed()
        XCTAssertEqual(staleAfterEnd, Data([6]))
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(isSealed)
    }

    func testRenderLimiterRecoversPermitAfterQueuedCancellation() async throws {
        let limiter = LiveRoomRenderLimiter(limit: 1)
        let producer = GatedFrameProducer(data: Data([7]))
        let first = Task {
            try await limiter.withPermit { try await producer.render() }
        }
        await producer.waitUntilStarted()

        let queued = Task {
            try await limiter.withPermit { Data([8]) }
        }
        let enteredQueue = await waitForLimiterQueue(limiter, count: 1)
        XCTAssertTrue(enteredQueue)
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("A canceled queued render should not acquire a permit")
        } catch is CancellationError {
            // Expected.
        }

        await producer.release()
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, Data([7]))
        let subsequent = try await limiter.withPermit { Data([9]) }
        XCTAssertEqual(subsequent, Data([9]))
        let diagnostics = await limiter.diagnostics()
        XCTAssertEqual(diagnostics.active, 0)
        XCTAssertEqual(diagnostics.queued, 0)
    }

    func testRenderLimiterBoundsConcurrentRoomsToTwo() async throws {
        let limiter = LiveRoomRenderLimiter(limit: 2)
        let probe = ConcurrentRenderProbe()
        let tasks = (0..<3).map { _ in
            Task { try await limiter.withPermit { await probe.run() } }
        }
        await probe.waitUntilStarted(count: 2)
        let limited = await limiter.diagnostics()
        XCTAssertEqual(limited.active, 2)
        XCTAssertEqual(limited.queued, 1)

        await probe.release()
        for task in tasks { _ = try await task.value }
        let maximumActive = await probe.maximumActive()
        XCTAssertEqual(maximumActive, 2)
        let drained = await limiter.diagnostics()
        XCTAssertEqual(drained.active, 0)
        XCTAssertEqual(drained.queued, 0)
    }

    private func waitForWaiters(
        _ cache: LiveRoomJPEGCache,
        count: Int
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await cache.waiterCount() == count { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForLimiterQueue(
        _ limiter: LiveRoomRenderLimiter,
        count: Int
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await limiter.diagnostics().queued == count { return true }
            await Task.yield()
        }
        return false
    }
}

private enum FramePipelineTestError: Error {
    case expectedFailure
}

private final class FrameTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64 = 0

    func get() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return milliseconds
    }

    func advance(by amount: Int64) {
        lock.lock()
        milliseconds += amount
        lock.unlock()
    }
}

private actor GatedFrameProducer {
    private let data: Data
    private var started = false
    private var released = false
    private var cancellations = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data) { self.data = data }

    func render() async throws -> Data {
        started = true
        let observers = startWaiters
        startWaiters.removeAll()
        for observer in observers { observer.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.markCanceled() }
        }
        try Task.checkCancellation()
        return data
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func cancellationCount() -> Int { cancellations }
    private func markCanceled() {
        cancellations += 1
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CancellationObservingProducer {
    private var started = false
    private var canceled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func render() async throws -> Data {
        started = true
        let observers = startWaiters
        startWaiters.removeAll()
        for observer in observers { observer.resume() }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Data([0])
        } catch {
            canceled = true
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            throw error
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCanceled() async {
        if canceled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

private actor FailingOnceFrameProducer {
    private var attempts = 0

    func render() throws -> Data {
        attempts += 1
        if attempts == 1 { throw FramePipelineTestError.expectedFailure }
        return Data([4])
    }
}

private actor ConcurrentRenderProbe {
    private var active = 0
    private var maximum = 0
    private var starts = 0
    private var released = false
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async -> Int {
        active += 1
        maximum = max(maximum, active)
        starts += 1
        let ready = startWaiters.filter { starts >= $0.0 }
        startWaiters.removeAll { starts >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
        active -= 1
        return starts
    }

    func waitUntilStarted(count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func maximumActive() -> Int { maximum }
}
