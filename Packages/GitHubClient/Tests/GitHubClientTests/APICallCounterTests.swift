// APICallCounterTests.swift
// GitHubClientTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// Retained contracts:
//   1. record() increments count; snapshot() reflects initial zero and recorded count.
//   2. purge() removes expired entries, retains the inclusive 60-minute boundary, and
//      returns zero after all entries expire (idle-gap regression).
//   3. record() trims the buffer to hourlyLimit — storage never grows without bound.
//   4. snapshot() count+limit are consistent under concurrent record() mutations.
//   5. GitHubTransport increments the counter once per completed HTTP round-trip,
//      regardless of status code (200–500 matrix).
//   6. A transport-layer error (URLError) before any HTTP response must not increment.
//   7. Each paginated page increments the counter exactly once.
import Foundation
import Testing

@testable import GitHubClient

@Suite("APICallCounter")
struct APICallCounterTests {

  // MARK: - Record lifecycle

  @Test("record() and snapshot() lifecycle: initial zero, increments, limit")
  func recordAndSnapshotLifecycle() async {
    let counter = APICallCounter()

    let initial = await counter.snapshot()
    #expect(initial.count == 0)

    await counter.record()
    await counter.record()

    let recorded = await counter.snapshot()
    #expect(recorded.count == 2)
    #expect(recorded.limit == APICallCounter.hourlyLimit)
  }

  // MARK: - Purge window

  @Test("purge() removes expired entries, retains inclusive boundary, zeros on full expiry")
  func purgeWindowContract() async {
    let counter = APICallCounter()
    let now = ContinuousClock.now

    // 1. One entry older than one hour (expired).
    let expired = now.advanced(by: .seconds(-3_601))
    // 2. One entry exactly at the inclusive 60-minute boundary (retained).
    let boundary = now.advanced(by: .seconds(-3_599))
    // 3. One entry well inside the window (retained).
    let recent = now.advanced(by: .seconds(-60))

    await counter.seed(timestamps: [expired, boundary, recent])
    let snap = await counter.snapshot()

    // Expired evicted; boundary and recent retained → count == 2.
    #expect(
      snap.count == 2,
      "expired entry must be evicted; boundary and recent entries must be retained")

    // Seed only stale entries — snapshot should return zero (idle-gap regression).
    let stale = now.advanced(by: .seconds(-5_400))
    await counter.seed(timestamps: [stale, stale])
    let zeroed = await counter.snapshot()
    #expect(zeroed.count == 0, "all entries past the window must produce a zero count")
  }

  // MARK: - Storage cap

  @Test("record() trims buffer to hourlyLimit when entries exceed it")
  func storageIsCappedAtHourlyLimit() async {
    let counter = APICallCounter()
    let now = ContinuousClock.now
    let fresh = (0..<(APICallCounter.hourlyLimit + 10)).map {
      now.advanced(by: .milliseconds($0))
    }
    await counter.seed(timestamps: fresh)
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == APICallCounter.hourlyLimit)
  }

  // MARK: - Concurrency

  @Test("snapshot() count+limit are consistent under concurrent record() mutations")
  func snapshotAtomicUnderConcurrentMutations() async {
    let counter = APICallCounter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask { await counter.record() }
      }
      for _ in 0..<20 {
        group.addTask {
          let snap = await counter.snapshot()
          #expect(snap.limit == APICallCounter.hourlyLimit)
          #expect(snap.count <= APICallCounter.hourlyLimit)
          #expect(snap.fraction >= 0.0)
          #expect(snap.fraction <= 1.0)
        }
      }
    }
  }

  // MARK: - Transport-layer counter
  //
  // Verifies that GitHubTransport.interpretHTTPResponse() increments the
  // injected callCounter on every completed HTTP round-trip, using
  // IsolatedStubURLProtocol as the network shim.
  //
  // URLSession isolation
  // --------------------
  // Each inner suite builds a private URLSession using
  // URLSessionConfiguration.ephemeral with protocolClasses =
  // [IsolatedStubURLProtocol] injected directly. This session is fully
  // self-contained and never touches URLSession.shared or the
  // registerClass/unregisterClass lifecycle owned by other suites.
  //
  // Why IsolatedStubURLProtocol instead of StubURLProtocol?
  // --------------------------------------------------------
  // GitHubTransportPaginatedTests calls StubURLProtocol.reset() at the top
  // of every test, wiping the process-global stub registry. Using
  // IsolatedStubURLProtocol gives these tests their own registry that reset()
  // never touches — eliminating the concurrency flake entirely.
  //
  // Stub data shapes
  // ----------------
  // apiPaginated decodes each HTTP response body as [AnyJSON] (a flat JSON
  // array). Stubs must return a bare JSON array — NOT a dict wrapper.
  //   fetchRunners — [{runner object}]

  @Suite("TransportIncrementGuard", .serialized)
  struct TransportIncrementGuard {

    init() {
      IsolatedStubURLProtocol.reset()
    }

    private let org = "counter-test"

    private let stubSession: URLSession = {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [IsolatedStubURLProtocol.self]
      return URLSession(configuration: config)
    }()

    private func makeTransport(counter: MockAPICallCounter) -> GitHubTransport {
      GitHubTransport(
        session: stubSession,
        tokenProvider: { "test-token" },
        callCounter: counter)
    }

    private func stubSuccess(_ url: String, statusCode: Int) {
      IsolatedStubURLProtocol.register(
        .init(data: Self.oneRunnerJSON, statusCode: statusCode, headers: [:]),
        for: url)
    }

    private func stubError(_ url: String, statusCode: Int) {
      IsolatedStubURLProtocol.register(
        .init(data: Data(#"{"message":"error"}"#.utf8), statusCode: statusCode, headers: [:]),
        for: url)
    }

    private func stubNetworkError(_ url: String) {
      IsolatedStubURLProtocol.registerError(
        .init(error: URLError(.notConnectedToInternet)),
        for: url)
    }

    private static let oneRunnerJSON = Data(
      #"[{"id":1,"name":"my-runner","status":"online","busy":false,"labels":[]}]"#.utf8)

    private var base: String { GitHubConstants.apiBase + "/" }

    // MARK: - Status matrix

    @Test("completed HTTP round-trip increments counter once for every status code")
    func transportCountsCompletedRoundTrips() async {
      let statusCodes = [200, 201, 403, 404, 429, 500]
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"

      for statusCode in statusCodes {
        IsolatedStubURLProtocol.reset()
        let counter = MockAPICallCounter()

        if (200...299).contains(statusCode) {
          stubSuccess(url, statusCode: statusCode)
        } else {
          stubError(url, statusCode: statusCode)
        }

        _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))

        #expect(
          await counter.recordedCount == 1,
          "status=\(statusCode) should count one completed HTTP round-trip")
      }
    }

    // MARK: - Network failure

    @Test("transport-layer URLError before HTTP response must not increment counter")
    func networkFailureDoesNotIncrementCounter() async {
      IsolatedStubURLProtocol.reset()
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      stubNetworkError(url)
      _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(
        await counter.recordedCount == 0,
        "a URLError before any HTTP response must not increment the counter")
    }

    // MARK: - Pagination

    @Test("counter increments once per page for multi-page paginated responses")
    func paginatedRequestCountsEveryPage() async {
      IsolatedStubURLProtocol.reset()
      let counter = MockAPICallCounter()
      let page1URL = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      let page2URL =
        "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)&page=2"
      IsolatedStubURLProtocol.register(
        .init(
          data: Data(
            #"[{"id":1,"name":"r1","status":"online","busy":false,"labels":[]}]"#.utf8),
          statusCode: 200,
          headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
        for: page1URL)
      IsolatedStubURLProtocol.register(
        .init(
          data: Data(
            #"[{"id":2,"name":"r2","status":"online","busy":false,"labels":[]}]"#.utf8),
          statusCode: 200, headers: [:]),
        for: page2URL)
      _ = await makeTransport(counter: counter).apiPaginated(
        "orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)")
      #expect(await counter.recordedCount == 2)
    }
  }
}
