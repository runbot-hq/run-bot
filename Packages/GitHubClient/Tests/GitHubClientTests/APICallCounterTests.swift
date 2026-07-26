// APICallCounterTests.swift
// GitHubClientTests
//
// Unit tests for APICallCounter and APICallCounterSnapshot.
//
// The key invariants tested:
//   1. Fresh actor starts at zero, fraction 0.0, and limit == hourlyLimit.
//   2. record() increments count within the rolling window.
//   3. fraction is always clamped to [0, 1].
//   4. snapshot() is atomic — consistent count + limit in one hop (P10).
//   5. APICallCounterSnapshot is Equatable and Sendable.
//   6. snapshot() returns zero after all timestamps expire (idle-gap regression).
//   7. GitHubTransport increments the injected callCounter on every 2xx response.
//      Each successful HTTP page counts as one hit, regardless of HTTP verb.
//   8. record() trims buffer to hourlyLimit at >5,000 entries.
//   9. purge() retains entries exactly at the 60-minute boundary (inclusive).
//  10. purge() evicts entries just beyond the 60-minute boundary (exclusive).
//  11. record() trims to hourlyLimit when buffer is at exactly hourlyLimit before the call.
import Foundation
import Testing

@testable import GitHubClient

@Suite("APICallCounter")
struct APICallCounterTests {

  // MARK: - Defaults

  /// Merged from freshActorStartsAtZero, freshActorFractionIsZero, and
  /// snapshotLimitMatchesConstant — all shared identical setup and tested
  /// different fields of the same snapshot value.
  @Test("fresh actor has expected defaults: count 0, fraction 0.0, limit == hourlyLimit")
  func freshActorHasExpectedDefaults() async {
    let counter = APICallCounter()
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
    #expect(snap.fraction == 0.0)
    #expect(snap.limit == APICallCounter.hourlyLimit)
  }

  // MARK: - record()

  @Test("record() increments count by one per call")
  func recordIncrementsCount() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    #expect(snap.count == 3)
  }

  @Test("record() from concurrent tasks all land in the count")
  func recordConcurrentTasks() async {
    let counter = APICallCounter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask { await counter.record() }
      }
    }
    let snap = await counter.snapshot()
    #expect(snap.count == 20)
  }

  @Test("record() trims buffer to hourlyLimit when entries exceed it")
  func recordTrimsToHourlyLimit() async {
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

  /// Verifies the exact-boundary case of `record()`'s trim guard:
  /// `if timestamps.count > Self.hourlyLimit`.
  ///
  /// `recordTrimsToHourlyLimit` seeds `hourlyLimit + 10` entries, which is
  /// already **over** the limit before `record()` is called. This test seeds
  /// exactly `hourlyLimit` entries — the buffer is full but not yet over —
  /// then calls `record()` once.
  ///
  /// After the append, `timestamps.count == hourlyLimit + 1`, which is
  /// strictly greater than `hourlyLimit`, so the trim fires:
  ///   `timestamps = Array(timestamps.suffix(hourlyLimit))`
  ///
  /// The suffix slice keeps the **newest** `hourlyLimit` entries, evicting
  /// only the oldest seeded entry (index 0). The result must be
  /// `count == hourlyLimit`, not `hourlyLimit + 1`.
  ///
  /// This test would catch a regression where the guard is changed to
  /// `>=` (which would trim one call too early, preventing the counter
  /// from ever reaching the limit) or to `> hourlyLimit + 1` (which would
  /// allow the buffer to grow one entry beyond the cap).
  @Test("record() at exact hourlyLimit boundary trims back to hourlyLimit")
  func recordAtExactHourlyLimit_trimsToLimit() async {
    let counter = APICallCounter()
    let now = ContinuousClock.now
    // Seed exactly hourlyLimit fresh timestamps (buffer full, not over).
    let full = (0..<APICallCounter.hourlyLimit).map {
      now.advanced(by: .milliseconds($0))
    }
    await counter.seed(timestamps: full)

    // One more record() call tips the buffer to hourlyLimit + 1, triggering trim.
    await counter.record()

    let snap = await counter.snapshot()
    // Must be trimmed back to exactly hourlyLimit, not hourlyLimit + 1.
    #expect(
      snap.count == APICallCounter.hourlyLimit,
      "record() must trim the buffer to hourlyLimit when it reaches hourlyLimit + 1 entries")
  }

  // MARK: - fraction clamping

  @Test("fraction returns 0.0 when limit is zero to prevent NaN propagation")
  func fractionWithZeroLimitIsZero() {
    let snap = APICallCounterSnapshot(count: 42, limit: 0)
    #expect(snap.fraction == 0.0)
  }

  @Test("fraction is clamped to 1.0 when count exceeds limit")
  func fractionClampedToOne() {
    let snap = APICallCounterSnapshot(count: 9_999, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 1.0)
  }

  @Test("fraction is clamped to 0.0 when count is negative")
  func fractionClampedToZeroForNegativeCount() {
    let snap = APICallCounterSnapshot(count: -1, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.0)
  }

  @Test("fraction is exactly 0.5 at half the limit")
  func fractionAtHalf() {
    let snap = APICallCounterSnapshot(
      count: APICallCounter.hourlyLimit / 2, limit: APICallCounter.hourlyLimit)
    #expect(snap.fraction == 0.5)
  }

  @Test("fraction stays within [0, 1] for any count")
  func fractionBounded() {
    for count in [0, 1, 2_500, 5_000, 7_500, 10_000] {
      let snap = APICallCounterSnapshot(count: count, limit: APICallCounter.hourlyLimit)
      #expect(snap.fraction >= 0.0)
      #expect(snap.fraction <= 1.0)
    }
  }

  // MARK: - snapshot atomicity (P10)

  /// Two consecutive snapshot() calls on an idle actor return the same value.
  /// This is not a concurrency stress test — concurrent atomicity is covered
  /// by snapshotAtomicUnderConcurrentMutations. Renamed from snapshotIsConsistent
  /// to reflect what is actually verified.
  @Test("snapshot() is deterministic on an idle actor")
  func snapshotIsDeterministicOnIdle() async {
    let counter = APICallCounter()
    await counter.record()
    let s1 = await counter.snapshot()
    let s2 = await counter.snapshot()
    #expect(s1 == s2)
  }

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

  // MARK: - Idle-gap regression

  @Test("snapshot() returns zero after all timestamps expire without a record() call")
  func snapshotPurgesIdleStaleEntries() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-5_400))
    await counter.seed(timestamps: [stale, stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0)
  }

  // MARK: - Boundary regression

  @Test("purge() retains entry seeded exactly at the 60-minute boundary")
  func snapshotRetainsEntryExactlyAtCutoffBoundary() async {
    let counter = APICallCounter()
    let boundary = ContinuousClock.now.advanced(by: .seconds(-3_599))
    await counter.seed(timestamps: [boundary])
    let snap = await counter.snapshot()
    #expect(
      snap.count == 1, "entry at exactly the cutoff boundary must be retained (inclusive window)")
  }

  @Test("purge() evicts entry seeded just beyond the 60-minute boundary")
  func snapshotEvictsEntryBeyondCutoff() async {
    let counter = APICallCounter()
    let stale = ContinuousClock.now.advanced(by: .seconds(-3_601))
    await counter.seed(timestamps: [stale])
    let snap = await counter.snapshot()
    #expect(snap.count == 0, "entry 1 s past the cutoff must be evicted")
  }

  // MARK: - APICallCounterSnapshot struct

  @Test("APICallCounterSnapshot is Equatable")
  func snapshotEquatable() {
    let a = APICallCounterSnapshot(count: 42, limit: 5_000)
    let b = APICallCounterSnapshot(count: 42, limit: 5_000)
    let c = APICallCounterSnapshot(count: 99, limit: 5_000)
    #expect(a == b)
    #expect(a != c)
  }

  @Test("APICallCounterSnapshot is Sendable across task boundary")
  func snapshotSendable() async {
    let counter = APICallCounter()
    await counter.record()
    await counter.record()
    let snap = await counter.snapshot()
    let transferred = await Task.detached { snap }.value
    #expect(transferred.count == snap.count)
    #expect(transferred.limit == snap.limit)
  }

  // MARK: - Transport-layer counter (TransportIncrementGuard)
  //
  // Verifies that GitHubTransport.interpretHTTPResponse() increments the
  // injected callCounter on every 2xx response, using IsolatedStubURLProtocol
  // as the network shim. IsolatedStubURLProtocol has its own static registry
  // completely separate from StubURLProtocol used in GitHubTransportPaginatedTests.
  //
  // URLSession isolation
  // --------------------
  // Each test builds a private URLSession using
  // URLSessionConfiguration.ephemeral with protocolClasses = [IsolatedStubURLProtocol]
  // injected directly. This session is fully self-contained and never touches
  // URLSession.shared or the registerClass/unregisterClass lifecycle owned by
  // GitHubTransportPaginatedTests.
  //
  // Why IsolatedStubURLProtocol instead of StubURLProtocol?
  // --------------------------------------------------------
  // The two suites (GitHubTransportPaginatedTests + TransportIncrementGuard)
  // run concurrently. GitHubTransportPaginatedTests calls StubURLProtocol.reset()
  // at the top of every test, wiping the process-global stub registry. Using
  // IsolatedStubURLProtocol gives TransportIncrementGuard its own registry
  // that reset() never touches — eliminating the flake entirely.
  // IsolatedStubURLProtocol.reset() is called in init() before each test.
  //
  // Why does MockAPICallCounter expose reset() if it isn't called here?
  // --------------------------------------------------------------------
  // MockAPICallCounter.reset() is a test-spy convenience method, not part
  // of APICallCounterProtocol. It exists for tests that reuse a single spy
  // instance across multiple assertions (e.g. if a future test verifies
  // count before and after a second call). It is intentionally not called
  // here because each test instantiates a fresh MockAPICallCounter(),
  // making reset() redundant. If APICallCounterProtocol gains new
  // requirements, MockAPICallCounter will need to be updated, but reset()
  // itself does not create coupling to the protocol.
  //
  // Stub data shapes
  // ----------------
  // apiPaginated decodes each HTTP response body as [AnyJSON] (a flat JSON
  // array). Stubs for endpoints that go through apiPaginated must return a
  // bare JSON array — NOT a dict wrapper like {"workflow_runs":[]}.
  // All three paginated functions decode the flat array directly:
  //   fetchActiveRuns  — [GitHubWorkflowRun] directly (no envelope)
  //   fetchJobs        — [GitHubJob] directly (no envelope)
  //   fetchRunners     — [GitHubRunner] directly (no envelope)
  //
  // fetchRunners   — apiPaginated — stub: [{runner object}]
  // fetchActiveRuns — apiPaginated — stub: [] (per status)
  // fetchJobs      — apiPaginated — stub: [{job object}]
  // fetchUserOrgs  — apiPaginated — stub: []
  // fetchUserRepos — apiPaginated — stub: []
  // post verb      — transport.post — stub: 201 empty body
  //
  // fetchUserOrgs / fetchUserRepos stub URL construction
  // ----------------------------------------------------
  // Stub URLs mirror the exact endpoint string the production functions pass
  // to apiPaginated — i.e. the same GitHubConstants interpolation used in
  // GitHubHelpers.swift. Do NOT use trimmingCharacters(in:) + base string
  // concatenation: that indirection works today only because the trim rescues
  // a double-slash, but would silently break if apiBase or the path constants
  // ever change shape.
  //
  // How nil is forced for early-exit tests
  // ---------------------------------------
  // IsolatedStubURLProtocol.canInit returns false for URLs that have no registered
  // stub or error stub. Unregistered URLs therefore fall through to the
  // underlying URLSession networking, which is non-deterministic in CI.
  // To force a deterministic nil return from apiPaginated, use
  // IsolatedStubURLProtocol.registerError(.init(error: URLError(.notConnectedToInternet)))
  // for any URL that must produce a network-error response. registerError
  // causes canInit to return true, IsolatedStubURLProtocol intercepts the request,
  // and startLoading fires client.urlProtocol(didFailWithError:)—
  // guaranteed to map to .networkError inside execute() and nil inside
  // apiPaginated, regardless of real network reachability.
  //
  // .rateLimited vs .noToken branch selection in fetchActiveRuns
  // -------------------------------------------------------------
  // fetchActiveRuns returns .noToken when allRuns.isEmpty at the nil guard,
  // and .rateLimited(partialRuns) only when allRuns is non-empty.
  // The fetchActiveRunsCounterStopsAtOneOnRateLimitedEarlyExit test stubs
  // in_progress with oneRunJSON — a flat array containing one GitHubWorkflowRun
  // object with only the fields required by its Decodable init. This makes
  // allRuns non-empty after the first successful page, so when queued hits a
  // network error the nil guard correctly takes .rateLimited(partialRuns).
  // A bare [] body leaves allRuns empty and takes .noToken instead.
  //
  // oneRunJSON fields match GitHubWorkflowRun.CodingKeys exactly:
  //   id, name, status, conclusion(optional), head_branch, head_sha,
  //   html_url, created_at, updated_at.
  // No other fields (repository, run_number, workflow_id, event) are needed
  // or present on GitHubWorkflowRun.
  //
  // .rateLimited vs .permissionDenied for 403 responses
  // -----------------------------------------------------
  // handleRateLimitResponse returns true (→ .rateLimited) only when the 403
  // carries rate-limit signals: X-RateLimit-Remaining: 0 or a Retry-After
  // header. A plain 403 with neither header returns false (→ .permissionDenied).
  // counterNotIncrementedOnPermissionDenied403 covers the .permissionDenied path.
  // The .rateLimited 403 path (X-RateLimit-Remaining: 0) is tracked in #43.
  //
  // .serialized prevents tests within this suite from racing on the
  // shared stub registry.
  // final class is required for stored properties.

  @Suite("TransportIncrementGuard", .serialized)
  final class TransportIncrementGuard {

    init() {
      // Reset the isolated stub registry before each test so stubs from a
      // prior test cannot intercept requests in the next one.
      IsolatedStubURLProtocol.reset()
    }

    // Distinct org — never appears in GitHubTransportPaginatedTests.
    private let org = "counter-test"

    // Private URLSession with IsolatedStubURLProtocol injected via protocolClasses.
    // Fully self-contained; does not depend on URLProtocol.registerClass /
    // unregisterClass.
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

    // Stub a 200 response returning a bare JSON array — required by apiPaginated.
    private func stub200array(_ url: String) {
      IsolatedStubURLProtocol.register(.init(data: Data("[]".utf8), statusCode: 200, headers: [:]), for: url)
    }

    private func stubError(_ url: String, statusCode: Int) {
      IsolatedStubURLProtocol.register(
        .init(data: Data("{\"message\":\"error\"}".utf8), statusCode: statusCode, headers: [:]),
        for: url)
    }

    // Force a deterministic network-error nil from apiPaginated for a given URL.
    // Uses registerError so canInit returns true and IsolatedStubURLProtocol intercepts
    // the request — never falling through to real networking.
    private func stubNetworkError(_ url: String) {
      IsolatedStubURLProtocol.registerError(
        .init(error: URLError(.notConnectedToInternet)),
        for: url)
    }

    // A minimal flat JSON array containing one GitHubWorkflowRun object.
    // Fields match GitHubWorkflowRun.CodingKeys exactly — no extra fields.
    // Used to make allRuns non-empty so .rateLimited is reachable in the
    // early-exit counter test.
    private static let oneRunJSON = Data("""
      [{"id":1,"name":"CI","status":"in_progress",\
      "head_branch":"main","head_sha":"abc",\
      "html_url":"https://github.com/counter-test/r/actions/runs/1",\
      "created_at":"2024-01-01T00:00:00Z",\
      "updated_at":"2024-01-01T00:00:00Z"}]
      """.utf8)

    // A minimal flat JSON array containing one GitHubJob object.
    // Fields satisfy GitHubJob's custom Decodable init (id, run_id, name, status required;
    // steps omitted — falls back to [] via the try? guard in the init).
    private static let oneJobJSON = Data("""
      [{"id":1,"run_id":1,"name":"build","status":"completed"}]
      """.utf8)

    // A minimal flat JSON array containing one GitHubRunner object.
    // All five fields are required by GitHubRunner's synthesised Decodable init.
    private static let oneRunnerJSON = Data("""
      [{"id":1,"name":"my-runner","status":"online","busy":false,"labels":[]}]
      """.utf8)

    private var base: String { GitHubConstants.apiBase + "/" }

    // MARK: fetchRunners

    @Test("fetchRunners() increments counter once and returns decoded runners")
    func fetchRunnersIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      IsolatedStubURLProtocol.register(
        .init(data: Self.oneRunnerJSON, statusCode: 200, headers: [:]), for: url)
      let runners = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
      #expect(runners.count == 1, "fetchRunners must return the decoded runner, not [] — verify apiPaginated flat-array decode is used (no keyed wrapper)")
    }

    // MARK: fetchActiveRuns — happy path

    @Test("fetchActiveRuns() increments counter once per status query (2 total)")
    func fetchActiveRunsIncrementsTwice() async {
      let counter = MockAPICallCounter()
      let ps = GitHubConstants.activeRunsPageSize
      // Must be bare [] arrays — apiPaginated rejects dict bodies.
      stub200array("\(base)orgs/\(org)/actions/runs?status=in_progress&per_page=\(ps)")
      stub200array("\(base)orgs/\(org)/actions/runs?status=queued&per_page=\(ps)")
      _ = await fetchActiveRuns(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 2)
    }

    // MARK: fetchActiveRuns — nil-exit counter invariants
    //
    // Both tests use stubNetworkError() — not an unregistered URL — to force a
    // deterministic nil from apiPaginated.
    //
    // The .rateLimited test stubs in_progress with oneRunJSON (one decodable run)
    // so allRuns is non-empty before the nil guard fires on queued — the only way
    // to reach the .rateLimited(partialRuns) branch. A bare [] body would leave
    // allRuns empty and take .noToken instead.

    @Test("fetchActiveRuns() counter == 1 when second status query returns nil (.rateLimited exit)")
    func fetchActiveRunsCounterStopsAtOneOnRateLimitedEarlyExit() async {
      let counter = MockAPICallCounter()
      let ps = GitHubConstants.activeRunsPageSize
      let inProgressURL = "\(base)orgs/\(org)/actions/runs?status=in_progress&per_page=\(ps)"
      let queuedURL = "\(base)orgs/\(org)/actions/runs?status=queued&per_page=\(ps)"
      // in_progress returns one run — allRuns becomes non-empty, counter gets 1 hit.
      IsolatedStubURLProtocol.register(
        .init(data: Self.oneRunJSON, statusCode: 200, headers: [:]),
        for: inProgressURL)
      // queued returns a network error — apiPaginated returns nil, allRuns
      // is non-empty → .rateLimited(partialRuns) branch. No counter hit.
      stubNetworkError(queuedURL)
      let result = await fetchActiveRuns(
        scope: .org(org), transport: makeTransport(counter: counter))
      if case .rateLimited = result { /* expected */ } else {
        Issue.record("expected .rateLimited, got \(result)")
      }
      #expect(
        await counter.recordedCount == 1,
        "only the successful in_progress hit should be counted; the network-error queued exit must not add a second hit")
    }

    @Test("fetchActiveRuns() counter == 0 when first status query returns nil (.noToken exit)")
    func fetchActiveRunsCounterIsZeroOnNoTokenEarlyExit() async {
      let counter = MockAPICallCounter()
      let ps = GitHubConstants.activeRunsPageSize
      let inProgressURL = "\(base)orgs/\(org)/actions/runs?status=in_progress&per_page=\(ps)"
      let queuedURL = "\(base)orgs/\(org)/actions/runs?status=queued&per_page=\(ps)"
      // in_progress returns a network error — fetchActiveRuns hits the nil guard
      // with allRuns still empty and returns .noToken immediately. No record() call.
      stubNetworkError(inProgressURL)
      // queuedURL is registered but structurally unreachable: fetchActiveRuns
      // returns .noToken after the first nil guard fires and never reaches the
      // second loop iteration. The stub is present only to ensure IsolatedStubURLProtocol
      // intercepts the URL if the early-exit logic ever regresses, rather than
      // falling through to real networking.
      stubNetworkError(queuedURL)
      let result = await fetchActiveRuns(
        scope: .org(org), transport: makeTransport(counter: counter))
      if case .noToken = result { /* expected */ } else {
        Issue.record("expected .noToken, got \(result)")
      }
      #expect(
        await counter.recordedCount == 0,
        "a network-error first-page result must not increment the counter")
    }

    // MARK: fetchJobs

    @Test("fetchJobs() increments counter once and returns decoded jobs")
    func fetchJobsIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let url =
        "\(base)repos/\(org)/myrepo/actions/runs/1/jobs?per_page=\(GitHubConstants.maxPageSize)"
      IsolatedStubURLProtocol.register(
        .init(data: Self.oneJobJSON, statusCode: 200, headers: [:]), for: url)
      let jobs = await fetchJobs(
        runID: 1, scope: .repo(owner: org, name: "myrepo"),
        transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
      #expect(jobs.count == 1, "fetchJobs must return the decoded job, not [] — verify apiPaginated flat-array decode is used (no keyed wrapper)")
    }

    // MARK: fetchUserOrgs

    // Stub URL mirrors the exact endpoint string fetchUserOrgs passes to apiPaginated
    // (GitHubHelpers.swift). Do not use path-trimming + base concatenation —
    // see "fetchUserOrgs / fetchUserRepos stub URL construction" above.
    @Test("fetchUserOrgs() increments counter once per successful HTTP response")
    func fetchUserOrgsIncrementsCounter() async {
      let counter = MockAPICallCounter()
      stub200array(
        "\(GitHubConstants.apiBase)\(GitHubConstants.userOrgsPath)?per_page=\(GitHubConstants.maxPageSize)"
      )
      _ = await fetchUserOrgs(transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
    }

    // MARK: fetchUserRepos

    // Stub URL mirrors the exact endpoint string fetchUserRepos passes to apiPaginated
    // (GitHubHelpers.swift). Do not use path-trimming + base concatenation —
    // see "fetchUserOrgs / fetchUserRepos stub URL construction" above.
    @Test("fetchUserRepos() increments counter once per successful HTTP response")
    func fetchUserReposIncrementsCounter() async {
      let counter = MockAPICallCounter()
      stub200array(
        "\(GitHubConstants.apiBase)\(GitHubConstants.userReposPath)?sort=updated&per_page=\(GitHubConstants.maxPageSize)"
      )
      _ = await fetchUserRepos(transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 1)
    }

    // MARK: mutation verb — POST

    // This test directly proves the core correctness claim of PR #37:
    // all HTTP verbs are now counted via interpretHTTPResponse, not just
    // GET-like methods that flow through apiPaginated.
    // A 201 Created response is used because POST endpoints (e.g. runner
    // registration token) commonly return 201, and interpretHTTPResponse
    // treats the full 200..<300 range as 2xx success.
    @Test("POST 2xx response increments counter once")
    func postVerbIncrementsCounter() async {
      let counter = MockAPICallCounter()
      let endpoint = "orgs/\(org)/actions/runners/registration-token"
      let url = "\(base)\(endpoint)"
      IsolatedStubURLProtocol.register(
        .init(data: Data("{\"token\":\"abc\",\"expires_at\":\"2099-01-01T00:00:00Z\"}".utf8),
              statusCode: 201,
              headers: [:]),
        for: url)
      _ = await makeTransport(counter: counter).post(endpoint, body: nil)
      #expect(
        await counter.recordedCount == 1,
        "a 201 Created POST response must increment the counter once via interpretHTTPResponse")
    }

    // MARK: non-2xx does not increment

    @Test("counter is not incremented on 404 response")
    func counterNotIncrementedOn404() async {
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      stubError(url, statusCode: 404)
      _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 0)
    }

    // A plain 403 with no rate-limit headers maps to .permissionDenied — not .rateLimited.
    // handleRateLimitResponse returns false, callCounter.record() is never reached.
    // For the .rateLimited 403 path (X-RateLimit-Remaining: 0), see #43.
    @Test("counter is not incremented on 403 permission-denied response (no rate-limit headers)")
    func counterNotIncrementedOnPermissionDenied403() async {
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      // stubError returns {"message":"error"} with no rate-limit headers —
      // handleRateLimitResponse returns false → .permissionDenied path.
      stubError(url, statusCode: 403)
      _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 0)
    }

    @Test("counter is not incremented on 429 response (secondary rate-limit signal)")
    func counterNotIncrementedOn429() async {
      let counter = MockAPICallCounter()
      let url = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      stubError(url, statusCode: 429)
      _ = await fetchRunners(scope: .org(org), transport: makeTransport(counter: counter))
      #expect(await counter.recordedCount == 0)
    }

    // MARK: multi-page

    @Test("counter increments once per page for multi-page paginated responses")
    func counterIncrementsPerPage() async {
      let counter = MockAPICallCounter()
      let page1URL = "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
      let page2URL =
        "\(base)orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)&page=2"
      IsolatedStubURLProtocol.register(
        .init(
          data: Data(
            "[{\"id\":1,\"name\":\"r1\",\"status\":\"online\",\"busy\":false,\"labels\":[]}]".utf8),
          statusCode: 200,
          headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
        for: page1URL)
      IsolatedStubURLProtocol.register(
        .init(
          data: Data(
            "[{\"id\":2,\"name\":\"r2\",\"status\":\"online\",\"busy\":false,\"labels\":[]}]".utf8),
          statusCode: 200, headers: [:]),
        for: page2URL)
      _ = await makeTransport(counter: counter).apiPaginated(
        "orgs/\(org)/actions/runners?per_page=\(GitHubConstants.maxPageSize)")
      #expect(await counter.recordedCount == 2)
    }
  }
}
