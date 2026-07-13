<div align="center">

<img width="140" alt="RunBot" src="logo.png">

# RunBot

> GitHub Actions and local runners — in your macOS menu bar.

[![Version](https://img.shields.io/github/v/release/runbot-hq/run-bot?label=release)](https://github.com/runbot-hq/run-bot/releases/latest)
[![Beta](https://img.shields.io/github/v/tag/runbot-hq/run-bot?include_prereleases&label=beta&filter=*beta*)](https://github.com/runbot-hq/run-bot/releases)
[![Downloads](https://img.shields.io/github/downloads/runbot-hq/run-bot/RunBot.zip?label=downloads&displayAssetName=false)](https://github.com/runbot-hq/run-bot/releases)
[![Stars](https://img.shields.io/github/stars/runbot-hq/run-bot)](https://github.com/runbot-hq/run-bot/stargazers)
[![Open PRs](https://img.shields.io/github/issues-pr/runbot-hq/run-bot)](https://github.com/runbot-hq/run-bot/pulls)

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-000000?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM 6.2](https://img.shields.io/badge/SPM-6.2-F05138?logo=swift&logoColor=white)
![Liquid Glass](https://img.shields.io/badge/UI-Liquid%20Glass-0A84FF?logo=apple&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-compatible-2088FF?logo=githubactions&logoColor=white)

[Download for Mac](https://github.com/runbot-hq/run-bot/releases/latest) · [Docs](docs/development.md) · [Architecture](docs/architecture.md) · [Contributing](docs/contributing.md)

</div>

---

**CI Checks**

![UI Tests](https://github.com/runbot-hq/run-bot/actions/workflows/ui-tests.yml/badge.svg)
![Unit Tests](https://github.com/runbot-hq/run-bot/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/runbot-hq/run-bot/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/runbot-hq/run-bot/actions/workflows/periphery.yml/badge.svg)
[![CodeQL](https://github.com/runbot-hq/run-bot/actions/workflows/codeql.yml/badge.svg)](https://github.com/runbot-hq/run-bot/actions/workflows/codeql.yml)

**AI Reviewers**

[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)
[![CodeRabbit](https://img.shields.io/badge/🐰%20AI%20Review-CodeRabbit-FF6B35?logoColor=white)](https://coderabbit.ai)
[![Octopus Review](https://img.shields.io/badge/🐙%20AI%20Review-Octopus-00B4D8?logoColor=white)](https://octopusreview.com)

**Activity**

[![Latest release](https://img.shields.io/github/release-date/runbot-hq/run-bot?label=latest%20release)](https://github.com/runbot-hq/run-bot/releases/latest)
[![Closed PRs](https://img.shields.io/github/issues-pr-closed/runbot-hq/run-bot)](https://github.com/runbot-hq/run-bot/pulls?q=is%3Apr+is%3Aclosed)
[![Open Issues](https://img.shields.io/github/issues/runbot-hq/run-bot)](https://github.com/runbot-hq/run-bot/issues)
[![Closed Issues](https://img.shields.io/github/issues-closed/runbot-hq/run-bot)](https://github.com/runbot-hq/run-bot/issues?q=is%3Aissue+is%3Aclosed)

**Code Quality**

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Reliability Rating](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Technical Debt](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=bugs)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Duplicated Lines (%)](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=duplicated_lines_density)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)

---

## Features

**🚦 Workflow status**
- Live run status across all your repos and orgs — expand any run into a full **Workflow → Jobs → Steps** tree with elapsed time and live progress
- Drill into jobs and steps; copy logs at the workflow, job, or step level
- Re-run all, re-run failed jobs, or cancel directly from the panel or right-click context menu
- Right-click a run to open the workflow or commit on GitHub

**🏃 Local runner manager**
- Provision new runners in one click — the app handles the token, the install script, and the registration with GitHub
- Add pre-existing runners already on your Mac
- Start, stop, and deregister runners directly from the UI — no Terminal or github.com required
- Active runners show live **CPU & memory** badges while a job is in progress


---

## Install

```bash
curl -fsSL https://runbot-hq.github.io/run-bot/install.sh | bash
```

---

## External Dependencies

- **[AppUpdater](https://github.com/runbot-hq/AppUpdater)** (first-party) — headless auto-update library; polls GitHub Releases for new versions, verifies each release via **Ed25519 signature** (`CryptoKit.Curve25519.Signing`) before install, and hands update state to the host app via `UpdateStateProviding`
- **[GitHubClient](https://github.com/runbot-hq/GitHubClient)** (first-party) — lightweight GitHub REST client; OAuth Authorization Code flow, layered token resolution (Keychain → env var), paginated API calls, and rate-limit handling; currently embedded as a local SPM target and extracted to its own repo as part of the ongoing modularisation effort
- **[MenuBarKit](https://github.com/runbot-hq/MenuBarKit)** (first-party) — SwiftUI + AppKit helpers for `NSPopover`-hosted menu bar apps; anchored sheets, overlay gate, file picker, and popover lifecycle management

---

## Docs

- [Development](docs/development.md) — dev loop, build, [releasing](docs/development.md#releasing), and [testing](docs/development.md#testing)
- [Architecture](docs/architecture.md) — data model, concurrency model, regression guards
- [Contributing](docs/contributing.md) — contribution guidelines
- [Principles](docs/principles.md) — engineering and design principles
- [Privacy](docs/privacy.md) — OAuth scopes, token storage, data handling
- [Agents](AGENTS.md) — context for AI coding agents

--- 

**Test a branch:**
```bash
git fetch && git checkout feature/your-branch && git pull
bash build.sh && open dist/RunBot.app
```
  
**Deploy release or beta:**  
- Deploy releases, betas and dry-runs here: [publish.yml](https://github.com/runbot-hq/run-bot/actions/workflows/publish.yml)
- select dry_run false or true and
- select beta or release
- Tag will be bumped according to rollover rules v1.0.9 -> v1.1.0 etc
- Version will be updated in app config files
- Beta will match release version and append its own integer v1.0.2 beta-4 etc
- Dry run and test ew functinality with beta before deploying an official release
- Users toggle beta in the app prefs  
