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

Installs via Terminal.app directly from GitHub releases. Updates arrive automatically with Ed25519 signature via [AppUpdater](https://github.com/runbot-hq/AppUpdater), ensuring secure delivery.

```bash
curl -fsSL https://runbot-hq.github.io/install.sh | bash
```
--- 

 is used to distribute updates via GitHub Releases with Ed25519 signature verification

## Test a branch

Requires cloning the repo to a local folder first

```bash
git fetch && git checkout main && git pull
bash build.sh && open dist/RunBot.app
```

**Logging:**

```bash
 log stream --level debug --style compact \
  --predicate 'process == "RunBot" AND subsystem == "com.eoncode.run-bot" AND category == "mbk"'
```

Reset build artifacts

```bash
rm -rf .build && swift package clean && swift package purge-cache
```


## Security

> [!WARNING]
> **CI/CD Security**
>
> 1. **Fork PR attacks** — GitHub blocks workflows from first-time outside
>    contributors by default, requiring maintainer approval before CI runs.
>    For self-hosted runners, harden this further by requiring approval for
>    all outside collaborators, and add a fork guard to every workflow:
>    ```yaml
>    if: |
>      github.event_name != 'pull_request' ||
>      github.event.pull_request.head.repo.full_name == github.repository
>    ```
>
> 2. **Audit your actions** — every `uses:` action runs arbitrary code with
>    access to your secrets and `GITHUB_TOKEN`. Only use actions you trust,
>    including anything they call downstream. This applies equally to
>    self-hosted and cloud runners.
>
> 3. **Pin actions to a SHA** — version tags can be silently force-pushed to
>    malicious code. A SHA is immutable. This applies equally to self-hosted
>    and cloud runners.
>    ```yaml
>    # ❌ uses: some-org/action@v1
>    # ✅ uses: some-org/action@abc123def456...
>    ```
