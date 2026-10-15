import XCTest
import UniformTypeIdentifiers
@testable import NoteAssistant

final class AttachmentCancellationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func stalledProvider(_ state: StalledProviderState, started: XCTestExpectation) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "Public synthetic.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            state.storeCallback(completion)
            started.fulfill()
            return Progress(totalUnitCount: 1)
        }
        return provider
    }

    func testCancellationDoesNotWaitForAProviderThatNeverCallsBack() async throws {
        let state = StalledProviderState()
        let started = expectation(description: "The provider has begun loading")
        let finished = expectation(description: "Cancellation completes without a provider callback")
        let provider = stalledProvider(state, started: started)
        let staging = root.appendingPathComponent("inbox")
        let receiving = Task {
            do {
                _ = try await AttachmentReceiver.receive([provider], staging: staging)
                state.finish(nil)
            } catch { state.finish(error) }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        receiving.cancel()
        await fulfillment(of: [finished], timeout: 3)
        guard state.hasFinished else { return }
        XCTAssertTrue(state.error is CancellationError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testLateProviderCallbackCannotCopyAfterCancellationAndCleanup() async throws {
        let state = StalledProviderState()
        let started = expectation(description: "The provider exposes a delayed file callback")
        let finished = expectation(description: "Cancellation finishes before the delayed callback")
        let provider = stalledProvider(state, started: started)
        let staging = root.appendingPathComponent("inbox")
        let receiving = Task {
            do {
                _ = try await AttachmentReceiver.receive([provider], staging: staging)
                state.finish(nil)
            } catch { state.finish(error) }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        receiving.cancel()
        await fulfillment(of: [finished], timeout: 3)
        guard state.hasFinished else { return }
        XCTAssertTrue(state.error is CancellationError)
        try FileManager.default.removeItem(at: staging)
        let lateFile = root.appendingPathComponent("late-public.pdf")
        try Data("%PDF-public synthetic delayed provider payload".utf8).write(to: lateFile)
        let callback = try XCTUnwrap(state.callback)
        callback(lateFile, false, nil)
        // NSItemProvider can dispatch its consumer callback on another queue.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(state.error is CancellationError)
        XCTAssertEqual(try Data(contentsOf: lateFile), Data("%PDF-public synthetic delayed provider payload".utf8))
    }
}

private final class StalledProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((URL?, Bool, Error?) -> Void)?
    private var completed = false
    private var storedError: Error?

    func storeCallback(_ completion: @escaping (URL?, Bool, Error?) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    func finish(_ error: Error?) {
        lock.lock()
        completed = true
        storedError = error
        lock.unlock()
    }

    var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var callback: ((URL?, Bool, Error?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return completion
    }
}
