// Runner.swift
// RunBotCore
//
// ⚠️ DELETED — migrated to GitHubRunner (GitHubClient package).
//
// All functionality has moved:
//   - API model fields (id, name, status, busy, labels) → GitHubRunner
//   - metrics carrier                                   → IndexedScopedRunner.metrics
//   - copying(metrics:), displayStatus(metrics:)        → GitHubRunner+AppExtensions.swift
//   - runnerStatus computed property                    → GitHubRunner+AppExtensions.swift
//   - AggregateStatus.init(runners:)                   → now accepts [GitHubRunner]
//
// This file is intentionally empty. It will be hard-deleted once the build
// is confirmed green on CI.
