# Test results — 26 Oct 2026

Reference machine: MacBook with Apple M4, macOS 27.0.1, built-in notched display (1470×956 pt, notch 179×32 pt). Swift 6.4, Command Line Tools only.

## Automated tests: `Scripts/test.sh`

**67 tests in 12 suites. All pass in debug, and in release (`-O`, the configuration that ships).**

| Suite | Covers |
|---|---|
| ClaudeCodeConnector | Every hook to event mapping. Typed notifications only (no text guessing). Local build/test classification. Interrupt → stopped. Hostile session IDs. **Privacy: normalised events never contain prompts, commands, tool input or free-form error text.** |
| CodexConnector | Permission, stop, session start, exit-code failures, Interrupt, unavailable capabilities declared. |
| RealPayload | **Sanitised payloads captured from a real Claude Code 2.1.310 session**, replayed through connector and manager. |
| CommandClassifier | 13 build commands, 14 test commands, 6 negatives. |
| NotificationManager | Merge duplicates. A finished tool resolves only its own request. A prompt or end of turn resolves the session. Dismiss/click never resolves. Transient vs pending. Routine news never takes over a waiting request. Critical interrupts. Priority order. Envy for 2+ sessions. Compact when already in the source app. Quiet mode and Focus. Muted agents/categories. Expiry by age and by dead agent PID. Reminders. Copy never invents a project. |
| MotionStateMachine | Hidden → Entering → Reacting → Waiting → Interacting → Exiting. One character only. Re-entry during exit. Reminders. Nothing animates while hidden. |
| HookInstaller | Keeps the user's real ModelMatch hooks and key order. Idempotent. Uninstall restores the file byte for byte. Repairs stale entries. Codex `{}` and missing files. Invalid JSON never overwritten. Symlinked config stays a symlink and keeps its mode. User entries beside ours survive. |
| PayloadValidator | Bad token, oversize, malformed, stale, injected control and bidi characters. Ordinary names pass in every build configuration. Rate limiter. |
| Storage | SQLite round trip, prune, clear. Settings migration. Quiet hours across midnight. Spool. |
| Socket | Server and client round trip. Second instance refused. No listener. |

### Bugs the tests caught (all fixed)

1. **Privacy leak.** `StopFailure`'s free-text `error` field could pass through as "detail", for example an API key. Error types are now an allowlist.
2. **Release-only rejection of every real event.** The `CharacterSet.controlCharacters.contains` method-reference form rejected plain ASCII under `-O`. It's replaced with an explicit scalar check, which also blocks bidi-override characters. This is why the suite now runs in release too.
3. **Process-wide `umask` race.** Binding the socket under a temporary umask made directories created concurrently on other threads unusable. The socket is now bound normally and then `chmod`ed.
4. **Installer write path.** `replaceItemAt` failed intermittently under `-O`. It's replaced with stat, create with the original mode, then `rename(2)`, and it now writes through symlinks.

## Real agent integration

### Claude Code 2.1.310: verified

- **Setup:** the hooks were loaded with `claude -p … --settings <file>`, so the user's global config was not modified. They ran in a scratch git repo, and the task required Bash permission.
- **Hooks that fired, in order:** `SessionStart` → `UserPromptSubmit` → `PermissionRequest (Bash)` → `Stop` → `SessionEnd (reason: other)`. The payloads are saved, sanitised, at `Tests/NotchCoreTests/Fixtures/claude-code-2.1.310.jsonl`.
- **In the app:** the permission request appeared in the notch, with the host detected as **Warp** (pid and tty) and the project as the repo's folder name. `-p` mode declines the permission itself, so the request was then resolved by `Stop`, and the completion was recorded.
- **Approve path:** `PostToolUse` resolving a request is covered by `Scripts/qa-notch.sh` (real payloads through the real helper) and by unit tests. An interactive approve-in-terminal run still needs a human.

### Codex 0.163: not run against a live session

- Installing hooks into `~/.codex/hooks.json` for a live test was **blocked by this environment's safety policy** (a persistent change to global config). It is left for the user: click **Connect** in the app, or run `notch-hook install codex`.
- The connector follows the payload shape of the Warp Codex plugin's hooks and the hook names in the Codex 0.163 binary.
- Capabilities without proof are labelled Partial or Unavailable.

## Notch and character: visual QA in the real notch

| Captured | Result |
|---|---|
| `Scripts/qa-notch.sh` through the real hook → socket → app path | Anxiety entry, reaction and detail. Duplicate merged. Resolved → exit → collapsed. Embarrassment. Anger, Disgust, Fear, Sadness and Joy appeared compact, because Warp (the source) was in front. Ennui compact. Envy with two agents. Cleared. [Sequence](images/real-hook-sequence.png) |
| `--demo all` and `--demo envy` (full layout) | All nine emotions, distinct poses and motion, contained in the notch. [Sheet](images/notch-all-emotions.png) |
| Screens | [Connect Your Tools](images/screen-connect-tools.png), [Character Preview](images/screen-character-preview.png) |

## Performance and reliability

| Check | Result | Target |
|---|---|---|
| Hook → app latency, p95 (100-event burst) | **141 ms** (p50 139 ms) | < 2 s ✅ |
| Hook runtime with the app running | ≈ 29 ms | non-blocking ✅ |
| Hook runtime with the app killed (spool + wake) | ≈ 0.37 s | non-blocking ✅ |
| Idle CPU (notch collapsed, 5 samples over 10 s) | **0.00 %** | < 1 % ✅ |
| Idle memory (RSS) | **65.5 MB** | < 150 MB ✅ |
| Burst of 100 concurrent events | 100/100 processed, UI responsive, bad payload rejected | ✅ |
| App killed mid-request | Hook spooled the event and woke the app; spool drained; request restored (146 ms) | ✅ |
| Restart with pending requests | Restored from history; expired if the agent PID is gone | ✅ (unit tested) |
| App bundle size | 5.1 MB, assets 1.0 MB | — |

## Not yet verified (needs a person or hardware)

- **Clicking the notch to return.** The navigation code is in place, but no synthetic click was possible here. The Terminal/iTerm2 exact-tab path will show the macOS Automation prompt the first time.
- **Sleep/wake reconciliation and multi-display changes.** The handlers exist (`didWake`, screen-parameter changes) but weren't exercised physically.
- **Launch at login.** This uses `SMAppService`. It may need the app in `~/Applications` or `/Applications` and approval in System Settings.
- **macOS Focus.** `INFocusStatusCenter` needs the Communication Notifications capability, which an ad-hoc signed build can't carry. The app reports it as unavailable and offers Quiet Mode and Quiet Hours instead.
- **Codex live session.** See above.
- **VoiceOver.** Announcements and labels are implemented; the app hasn't been audited with VoiceOver running.
