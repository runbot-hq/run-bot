<div align="center">

<img width="140" alt="RunBot" src="logo.png">

# RunBot

GitHub Actions and local runners — in your macOS menu bar.

[![Version](https://img.shields.io/github/v/release/runbot-hq/run-bot?label=release)](https://github.com/runbot-hq/run-bot/releases/latest)
[![Beta](https://img.shields.io/github/v/tag/runbot-hq/run-bot?include_prereleases&label=beta&filter=*beta*)](https://github.com/runbot-hq/run-bot/releases)
[![Downloads](https://img.shields.io/github/downloads/runbot-hq/run-bot/RunBot.zip?label=downloads&displayAssetName=false)](https://github.com/runbot-hq/run-bot/releases)
[![Stars](https://img.shields.io/github/stars/runbot-hq/run-bot)](https://github.com/runbot-hq/run-bot/stargazers)

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-000000?logo=apple&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

[Website](https://runbot-hq.github.io/run-bot) · [Docs](docs/) · [Install](https://github.com/runbot-hq/run-bot#install) · [Privacy](docs/privacy.md)

</div>

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

**🤖 Actions for local runners**

An open-source ecosystem of GitHub Actions built specifically for self-hosted
macOS runners — drop them into any workflow and they run directly on your Mac:

- **[AFM Release Notes](https://github.com/runbot-hq/afm-release-notes-action)** — Generates structured release notes from your commit history using Apple Intelligence (on-device AFM). No cloud API, no tokens — runs entirely on-device via Apple Foundation Models.
- **[Local AI Localisation](https://github.com/runbot-hq/translation-framework-action)** — Translates strings and localisation files using Apple AI Tranlsation Framework on-device. Inspired by Babel; no external service required.
- **[AI Remediation](https://github.com/runbot-hq/ai-remediation-action)** *(⚠️️ coming soon ⚠️️)* — On a failed run, automatically invokes an AI CLI of your choice (Claude Code, Gemini, Aider, Codex…) with full context: branch, commit SHA, failure log, and repo links. Full paper trail in the CI log; no UI dependency.

> All actions run on `self-hosted` runners — the same local runner RunBot manages — giving them direct access to your filesystem, installed tools, and on-device AI that cloud runners cannot reach.


---

## Install

Installs via Terminal.app directly from GitHub releases. Updates arrive automatically with Ed25519 signature, ensuring secure delivery.

```bash
curl -fsSL https://runbot-hq.github.io/run-bot/install.sh | bash
```

---

## External Dependencies

- **[AppUpdater](https://github.com/runbot-hq/AppUpdater)** — Auto-update for GitHub Releases with Ed25519 signature verification.
- **[GitHubClient](https://github.com/runbot-hq/GitHubClient)** — GitHub REST client with layered token resolution and rate-limit handling.
- **[MenuBarKit](https://github.com/runbot-hq/MenuBarKit)** — Menu bar plumbing for `NSPopover` lifecycle and anchored SwiftUI sheets.

--- 

**Test a branch:**
```bash
git fetch && git checkout main && git pull
bash build.sh && open dist/RunBot.app
```
  
**Deploy release or beta:**  
- Deploy releases, betas and dry-runs here: [publish.yml](https://github.com/runbot-hq/run-bot/actions/workflows/publish.yml)
- select dry_run false or true
- select beta or release
- Tag will be bumped according to rollover rules v1.0.9 -> v1.1.0 etc
- Version will be updated in app config files
- Beta will match release version and append its own integer v1.0.2 beta-4 etc
- Dry run and test new functinality with beta before deploying an official release
- Users toggle beta in the app prefs  
