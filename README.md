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

[Website](https://runbot-hq.github.io/run-bot) · [Docs](docs/) · [Install](https://github.com/runbot-hq/run-bot#install) · [Actions](https://github.com/runbot-hq?view_as=public#actions) 

</div>

---

## Features

#### 🚦 Live workflow status

Hierarchical overview of all your workflows. Active jobs are intelligently risen to the surface as they come alive.

#### 🏃 Local runner manager

One control plane for all your local runner needs. Provision new organization or repository runners with one easy click.

#### 🤖 AI-powered actions

Utilize your local AI capabilities in CI. Run [AI PR reviews](https://github.com/runbot-hq/local-ai-code-review-action), [AI localization](https://github.com/runbot-hq/translation-framework-action), and [AI release notes](https://github.com/runbot-hq/afm-release-notes-action). 

---

## Install

Installs via Terminal.app directly from GitHub releases. Updates arrive automatically with Ed25519 signature, ensuring secure delivery.

```bash
curl -fsSL https://runbot-hq.github.io/install.sh | bash
```

---

## External Dependencies

- **[AppUpdater](https://github.com/runbot-hq/AppUpdater)** — Auto-update for GitHub Releases with Ed25519 signature verification.
- **[GitHubClient](https://github.com/runbot-hq/GitHubClient)** — GitHub REST client with layered token resolution and rate-limit handling.
- **[MenuBarKit](https://github.com/runbot-hq/MenuBarKit)** — Menu bar plumbing for `NSPopover` lifecycle and anchored SwiftUI sheets.

--- 

## Test a branch:

Requires cloning the repo to a local folder first

```bash
git fetch && git checkout main && git pull
bash build.sh && open dist/RunBot.app
```

