# Privacy

RunBot is a local macOS application. It has no RunBot-operated backend and
does not collect analytics, telemetry, crash reports, or advertising data.

RunBot communicates directly with GitHub to monitor workflows and runners.

---

## Data stored on your Mac

RunBot stores:

- Your GitHub OAuth token in the macOS Keychain.
- Application settings in macOS `UserDefaults`.
- Current workflow, job, and runner state in memory.
- GitHub Actions log archives under
  `~/Library/Application Support/RunBot/ZIPCache/`.

Log archives may contain anything emitted by your workflows, including build
output and diagnostic information. RunBot keeps up to ten workflow-group cache
directories and removes the oldest as new groups are added.

Cached logs are used to display step logs and avoid repeatedly downloading
archives from GitHub. They are never uploaded to a RunBot-operated server.

---

## GitHub access

RunBot requests the following GitHub OAuth scopes:

| Scope | Purpose |
|---|---|
| `repo` | Read workflow runs, jobs, steps, and logs for private repositories; generate repo-level runner registration tokens. |
| `read:org` | List organisations the user belongs to and their workflow runs. |
| `admin:org` | List and manage self-hosted runners on organisations where the user is an owner. |
| `manage_runners:org` | Fine-grained runner-management scope; requested alongside `admin:org` for forward-compatibility. |
| `workflow` | Re-run, re-run failed, and cancel workflow runs. |

RunBot does not:

- Read or modify repository source files.
- Create issues or pull requests.
- Send your token anywhere except `api.github.com` and `github.com`.
- Sell or share your data.

---

## Network access

RunBot makes encrypted requests to `api.github.com` and `github.com`.
Workflow log archives are downloaded through temporary URLs provided by GitHub;
your OAuth token is not included in those requests.
Notifications are optional and generated locally by macOS.

---

## Removing local data

Signing out removes the stored GitHub credentials from the Keychain.
To remove application settings:

```
defaults delete io.github.runbot-hq
```

To remove cached workflow logs, quit RunBot and delete:

```
~/Library/Application Support/RunBot/ZIPCache/
```
