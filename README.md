# SuperNotch

SuperNotch turns the MacBook notch into a dynamic island for **media, calendar, files — and your AI coding agents**.

It is [boring.notch](https://github.com/TheBoredTeam/boring.notch) with the AI-agent features of [Code Island](https://github.com/rifqiakrm/code-island) built in as a new **AI** tab.

## Features

**From boring.notch**
- Now Playing controls with album art and visualizer (Apple Music, Spotify, YouTube Music, …)
- Calendar & reminders, battery, HUD replacement, webcam mirror
- Shelf: drop files onto the notch, AirDrop them

**AI tab (from Code Island)** — currently **Claude Code** and **Codex**
- Live list of running agent sessions with status, last prompt and reply
- **Pops up automatically** when an agent needs you:
  - permission requests (Allow once · Allow all · Auto mode · Deny)
  - plan review (`ExitPlanMode`)
  - questions (`AskUserQuestion`) — answer right in the notch
- "Finished" card when a task completes, auto-closes after a few seconds
- 5-hour / 7-day usage limits (used or remaining — your choice in Settings)
- 8-bit sound cues
- Hover a tab to switch; hover the AI list to expand it

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon (arm64)

## Install

**Homebrew** (clears the Gatekeeper quarantine for you):

```bash
brew tap tjimmy0113/tap
brew trust tjimmy0113/tap
brew install --cask supernotch
```

**Manual:**

1. Download `SuperNotch-<version>-arm64.dmg` from [Releases](../../releases) and drag **SuperNotch** to Applications.
2. The app is **not notarized** (no paid Apple Developer ID yet), so macOS blocks the first launch. Either
   - run `xattr -dr com.apple.quarantine /Applications/SuperNotch.app`, or
   - open SuperNotch once, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** (on macOS 15 and later, right-click → Open no longer works)
3. Allow Calendar / Accessibility access when asked (needed for calendar and HUD features).

## What SuperNotch changes on your Mac

To receive agent events, SuperNotch (like Code Island) installs hooks on launch:

| File | Change |
|---|---|
| `~/.claude/settings.json` | adds `code-island-bridge` hook entries (a `.bak` backup is written first) |
| `~/.codex/hooks.json`, `~/.codex/config.toml` | adds the Codex hook + enables hooks |
| `~/.code-island/bin/` | small launcher scripts that run the bridge inside SuperNotch.app |

Events travel over the local Unix socket `/tmp/code-island.sock`. Nothing leaves your Mac except the usage-limit lookups to Anthropic / OpenAI with your existing login.

You can turn off automatic hook installation in **Settings → AI Agents**.

> **Don't run SuperNotch and the Code Island app at the same time** — they share the same hooks and socket. SuperNotch will not take the socket from a running Code Island and shows a warning in the AI tab instead.

## Build from source

```bash
git clone <this repo>
cd <repo>
xcodebuild -scheme boringNotch -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY="-" build
open build/Build/Products/Release/SuperNotch.app
```

Xcode 16+ is required. The `Embed AI Bridge` build phase compiles the hook bridge (`AIBridge/`, a Swift package) and embeds it at `SuperNotch.app/Contents/Helpers/CodeIslandBridge`.

New code lives in `boringNotch/AI/` (ported Code Island core + views, AI tab integration) and `AIBridge/`.

## Credits & license

SuperNotch is a derivative work of:

- **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** by TheBoredTeam — GPL-3.0. The original README is kept as [README.boring-notch.md](README.boring-notch.md); third-party notices are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
- **[Code Island](https://github.com/rifqiakrm/code-island)** by rifqiakrm — GPL-3.0. The session store, hook bridge, installers and AI views are ported from it.
- **[Vibe Notch](https://github.com/farouqaldori/vibe-notch)** by farouqaldori — the pixel mascots used by Code Island.

**Modifications (2026):** merged Code Island into boring.notch as an AI tab, renamed the app to SuperNotch, disabled the App Sandbox and Sparkle auto-updates, and changed the notch sizing, popups and settings accordingly.

SuperNotch is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).
