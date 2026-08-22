// SaveRunnerEditsUseCaseTests.swift
// RunBotCoreTests
// Unit tests for SaveRunnerEditsUseCase — Phase 5 (#1300).
import Foundation
import RunBotCore
import Testing

// MARK: - Helpers

private func makeRunner(
  runnerName: String = "test-runner",
  agentId: Int? = 42,
  gitHubUrl: URL? = URL(string: "https://github.com/owner/repo"),
  installPath: String? = testRunnerInstallPath
) -> RunnerModel {
  RunnerModel(
    runnerName: runnerName,
    gitHubUrl: gitHubUrl,
    agentId: agentId,
    workFolder: nil,
    installPath: installPath,
    isRunning: false
  )
}

// MARK: - UseCase factory

private func makeUseCase(
  labels: SpyLabelsService = SpyLabelsService(),
  config: SpyConfigStore = SpyConfigStore(),
  proxy: SpyProxyStore = SpyProxyStore()
) -> SaveRunnerEditsUseCase {
  SaveRunnerEditsUseCase(configStore: config, proxyStore: proxy, labelsService: labels)
}

// MARK: - Tests

// Note: ownership semantics (`consuming draft:`, `borrowing runner:/original:`) are
// enforced at compile time — there is no runtime behaviour to test for those annotations.
// The tests below verify *what* gets written and *when*, not ownership transfer.
@Suite("SaveRunnerEditsUseCase")
struct SaveRunnerEditsUseCaseTests {

  /// Verifies that executing with an unchanged draft returns `.success` without calling any downstream service or store.
  @Test("returns .success when no fields changed")
  func noChanges() async {
    let runner = makeRunner()
    let draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    let labels = SpyLabelsService()
    let config = SpyConfigStore()
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(labels: labels, config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    #expect(result == .success)
    #expect(await labels.callCount == 0)
    #expect(await !config.saveCalled)
    #expect(await !proxy.saveCalled)
  }

  /// Verifies that a `nil` response from the labels API causes the whole commit to abort, returning a single `.failure` message and leaving config/proxy stores untouched.
  @Test("aborts entire commit when labels API returns nil")
  func labelsAPIFailureAborts() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.labelsText = "ci, fast"

    let labels = SpyLabelsService()
    await labels.setUp(result: nil)
    let config = SpyConfigStore()
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(labels: labels, config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.count == 1)
    #expect(msgs[0].contains("GitHub API"))
    #expect(await !config.saveCalled)
    #expect(await !proxy.saveCalled)
  }

  /// Verifies that a config-store write failure is accumulated as a `.failure` message but execution still proceeds to the proxy-store step.
  @Test("accumulates JSON error but continues to proxy step")
  func jsonWriteFailureContinues() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    draft.proxyUrl = "http://proxy.example.com"

    let config = SpyConfigStore()
    await config.setUp(shouldThrowOnSave: true)
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.contains(where: { $0.contains("/.runner:") }))
    #expect(await proxy.saveCalled)
  }

  /// Verifies that a proxy-store write failure is independently accumulated as a `.failure` message even when the config-store step succeeds.
  @Test("accumulates proxy error independently of JSON success")
  func proxyWriteFailureAccumulated() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.proxyUrl = "http://proxy.example.com"

    let proxy = SpyProxyStore()
    await proxy.setUp(shouldThrowOnSave: true)
    let useCase = makeUseCase(proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.contains(where: { $0.contains("proxy") }))
  }

  /// Verifies that the labels service is invoked with the correct `owner/repo` scope and integer runner ID derived from the runner model.
  @Test("calls labelsService with correct scope and runnerID")
  func labelsCalledWithCorrectArgs() async {
    let runner = makeRunner(agentId: 99, gitHubUrl: URL(string: "https://github.com/myorg/myrepo"))
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.labelsText = "gpu, large"

    let labels = SpyLabelsService()
    await labels.setUp(result: ["gpu", "large"])
    let useCase = makeUseCase(labels: labels)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    #expect(result == .success)
    #expect(await labels.callCount == 1)
    #expect(await labels.lastScope == "myorg/myrepo")
    #expect(await labels.lastRunnerID == 99)
    #expect(await labels.lastLabels == ["gpu", "large"])
  }

  /// Verifies that a `nil` `installPath` when JSON config changes are pending returns `.failure` without attempting to write to the config store.
  @Test("returns failure when installPath is nil and JSON changes pending")
  func missingInstallPathForJSON() async {
    let runner = makeRunner(installPath: nil)
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "other"

    let useCase = makeUseCase()

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure")
      return
    }
    #expect(msgs.contains(where: { $0.contains("Install path") }))
  }

  /// Verifies that a `nil` `installPath` when proxy changes are pending returns `.failure` without attempting to write to the proxy store.
  @Test("returns failure when installPath is nil and proxy changes pending")
  func missingInstallPathForProxy() async {
    // Runner has no installPath; only a proxy field is changed so Step 2
    // (JSON) is skipped and we land directly on the Step 3 guard.
    let runner = makeRunner(installPath: nil)
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.proxyUrl = "http://proxy.example.com"

    let proxy = SpyProxyStore()
    let useCase = makeUseCase(proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.contains(where: { $0.contains("Install path") }))
    #expect(await !proxy.saveCalled)
  }

  /// #1451 — Both JSON and proxy stores throw simultaneously.
  /// The use case must accumulate both errors (not short-circuit after the
  /// first failure), so the result must contain exactly two error messages.
  /// Verifies that simultaneous failures in both the config store and the proxy store produce exactly two accumulated error messages in the `.failure` result.
  @Test("accumulates both errors when JSON and proxy stores both fail")
  func bothStoresFailAccumulatesTwoErrors() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    draft.proxyUrl = "http://proxy.example.com"

    let config = SpyConfigStore()
    await config.setUp(shouldThrowOnSave: true)
    let proxy = SpyProxyStore()
    await proxy.setUp(shouldThrowOnSave: true)
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.count == 2)
    #expect(msgs.contains(where: { $0.contains("/.runner:") }))
    #expect(msgs.contains(where: { $0.contains("proxy") }))
    // proxy.saveCalled is not asserted here: the spy only sets it on success,
    // but both stores are configured to throw. The content checks above confirm
    // the proxy error path was reached.
  }

  /// configStore.load() returning .decodeFailed must emit the
  /// "Cannot decode config at <path>/.runner" message and still continue
  /// to the proxy step — the decodeFailed switch arm must not be dead code.
  /// Verifies that a config-store decode failure emits an error message containing the expected text and does not prevent the proxy step from executing.
  @Test("config decode failure emits correct message and proxy step still runs")
  func configDecodeFailureContinuesToProxy() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    draft.proxyUrl = "http://proxy.example.com"

    let config = SpyConfigStore()
    await config.setUp(shouldThrowOnDecode: true)
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    // decodeFailed message contains the install path and /.runner (no underlying error)
    #expect(msgs.contains(where: { $0.contains("/.runner") && !$0.contains(":") }))
    // proxy step must still execute despite the decode error
    #expect(await proxy.saveCalled)
  }

  /// configStore.load() failing on the read-modify-write step must accumulate a
  /// readFailed error and still continue to the proxy step — same fan-out
  /// behaviour as a save failure.
  /// Verifies that a config-store load failure is accumulated as an error and execution still continues to the proxy step.
  @Test("config load failure is accumulated and proxy step still runs")
  func configLoadFailureContinuesToProxy() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    draft.proxyUrl = "http://proxy.example.com"

    let config = SpyConfigStore()
    await config.setUp(shouldThrowOnLoad: true)
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    // readFailed message contains the install path and /.runner:
    #expect(msgs.contains(where: { $0.contains("/.runner:") }))
    // proxy step must still execute despite the config load error
    #expect(await proxy.saveCalled)
  }

  /// #1478 — configStore.save() throwing .malformedExistingFile must accumulate the
  /// correct error message. The malformed-file path is distinct from .writeFailed and
  /// must have its own branch in the exhaustive switch.
  /// Verifies that a malformed-file error from the config store emits an error message with the expected description text.
  @Test("config save malformed-file error emits correct message")
  func configSaveMalformedFileEmitsError() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    // No proxyUrl change — Step 3 must be skipped entirely.

    let config = SpyConfigStore()
    let proxy = SpyProxyStore()
    await config.setUp(shouldThrowMalformedOnSave: true)
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    // Message must mention the path, malformed, and agent-managed keys
    #expect(
      msgs.contains(where: { msg in
        msg.contains("malformed") && msg.contains("/.runner") && msg.contains("agent-managed")
      }))
    // No proxy change — proxy step must not have run
    #expect(await !proxy.saveCalled)
  }

  /// #1478 — configStore.save() throwing .malformedExistingFile must still allow
  /// the proxy step (Step 3) to execute. The use-case accumulates errors and
  /// continues — config and proxy writes are independent paths.
  /// Verifies that a malformed-file error from the config store does not prevent the proxy step from executing.
  @Test("config save malformed-file error still runs proxy step")
  func configSaveMalformedFileContinuesToProxy() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    draft.proxyUrl = "http://proxy.example.com"

    let config = SpyConfigStore()
    await config.setUp(shouldThrowMalformedOnSave: true)
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    // Message must mention path, malformed, and agent-managed keys (same contract as the sibling test)
    #expect(
      msgs.contains(where: { msg in
        msg.contains("malformed") && msg.contains("/.runner") && msg.contains("agent-managed")
      }))
    // Proxy step must still execute despite the malformed-file config error
    #expect(await proxy.saveCalled)
  }

  /// #1452 — Changing only a non-label field must not trigger the labels API.
  /// The label guard must be narrow enough that an unrelated field change
  /// (workFolder) does not call `labelsService.patch`.
  /// Verifies that changing a non-label field (e.g. `workFolder`) does not trigger a call to the labels service.
  @Test("non-label field change does not call labelsService")
  func nonLabelChangeDoesNotCallLabelsService() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "other_work"

    let labels = SpyLabelsService()
    let config = SpyConfigStore()
    let useCase = makeUseCase(labels: labels, config: config)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    #expect(result == .success)
    #expect(await labels.callCount == 0)
    #expect(await config.saveCalled)
  }

  // MARK: - LabelsPrerequisiteError

  /// #1480 — When agentId is nil, execute() must append the `.missingAgentId` message
  /// and must NOT call labelsService.patch.
  /// Verifies that a `nil` `agentId` on the runner appends an appropriate error message and skips the labels API patch call.
  @Test("labels step — missing agentId appends correct error and skips patch")
  func labelsPrereqMissingAgentId() async {
    let runner = makeRunner(agentId: nil)
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.labelsText = "some-label"

    let labels = SpyLabelsService()
    let useCase = makeUseCase(labels: labels)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.contains(where: { $0.contains("missing agent ID") }))
    #expect(await labels.callCount == 0)
  }

  /// #1480 — When agentId is present but gitHubUrl is nil, execute() must append
  /// the `.missingGitHubUrl` message and must NOT call labelsService.patch.
  /// Verifies that a `nil` `gitHubUrl` on the runner appends an appropriate error message and skips the labels API patch call.
  @Test("labels step — nil gitHubUrl appends correct error and skips patch")
  func labelsPrereqMissingGitHubUrl() async {
    let runner = makeRunner(gitHubUrl: nil)
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.labelsText = "some-label"

    let labels = SpyLabelsService()
    let useCase = makeUseCase(labels: labels)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.contains(where: { $0.contains("missing GitHub URL") }))
    #expect(await labels.callCount == 0)
  }

  /// #1480 — When gitHubUrl is present but is a bare-host URL (no org/repo path),
  /// execute() must append the `.invalidScope` message and must NOT call labelsService.patch.
  /// Verifies that a bare-host `gitHubUrl` (no path segments) resolves to an invalid scope, appends an appropriate error, and skips the labels API patch call.
  @Test("labels step — bare-host gitHubUrl appends invalidScope error and skips patch")
  func labelsPrereqInvalidScope() async {
    let runner = makeRunner(gitHubUrl: URL(string: "https://github.com"))
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.labelsText = "some-label"

    let labels = SpyLabelsService()
    let useCase = makeUseCase(labels: labels)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    #expect(msgs.contains(where: { $0.contains("no org/repo path") }))
    #expect(await labels.callCount == 0)
  }

  // MARK: - #1499 I/O-unreadable .runner during save

  /// #1499 — configStore.save() throwing .ioReadFailedDuringSave must accumulate the
  /// correct error message. The I/O-unreadable path is distinct from .writeFailed and
  /// .malformedExistingFile and must have its own branch in the exhaustive switch.
  /// Verifies that an IO-read-failed error from the config store emits an error message with the expected description text.
  @Test("config save IO-read-failed error emits correct message")
  func configSaveIOReadFailedEmitsError() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    // No proxyUrl change — Step 3 must be skipped entirely.

    let config = SpyConfigStore()
    let proxy = SpyProxyStore()
    await config.setUp(shouldThrowIOReadFailedOnSave: true)
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    // Message must mention path, unreadable, and agent-managed keys
    #expect(
      msgs.contains(where: { msg in
        msg.contains("unreadable") && msg.contains("/.runner") && msg.contains("agent-managed")
      }))
    // No proxy change — proxy step must not have run
    #expect(await !proxy.saveCalled)
  }

  /// #1499 — configStore.save() throwing .ioReadFailedDuringSave must still allow
  /// the proxy step (Step 3) to execute. Error fan-out behaviour must be identical
  /// to the .malformedExistingFile path: accumulate and continue.
  /// Verifies that an IO-read-failed error from the config store does not prevent the proxy step from executing.
  @Test("config save IO-read-failed error still runs proxy step")
  func configSaveIOReadFailedContinuesToProxy() async {
    let runner = makeRunner()
    var draft = RunnerEditDraft(runner: runner)
    let original = RunnerEditDraft(runner: runner)
    draft.workFolder = "custom_work"
    draft.proxyUrl = "http://proxy.example.com"

    let config = SpyConfigStore()
    await config.setUp(shouldThrowIOReadFailedOnSave: true)
    let proxy = SpyProxyStore()
    let useCase = makeUseCase(config: config, proxy: proxy)

    let result = await useCase.execute(runner: runner, draft: draft, original: original)

    guard case .failure(let msgs) = result else {
      Issue.record("expected .failure, got .success")
      return
    }
    // Message must mention path, unreadable, and agent-managed keys
    #expect(
      msgs.contains(where: { message in
        message.contains("unreadable") && message.contains("/.runner") && message.contains("agent-managed")
      }))
    // Proxy step must still execute despite the I/O read error
    #expect(await proxy.saveCalled)
  }
}
