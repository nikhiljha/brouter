# brouter

A tiny, JavaScript-configurable **browser router** for macOS. Set it as your
default browser and it decides — per URL — which **browser** or **Chrome
profile** opens the link, using rules you write in plain JavaScript. When you
can't decide up front, `route()` can pop a native **Ask** dialog to let you pick.

It runs as a background `launchd` agent (no Dock icon) so the config stays warm
and the Ask dialog appears instantly. A small **menu-bar icon** lets you open the
config, copy its path, see detected browsers, reload, or quit the daemon.

```
link clicked ──▶ brouter (default browser) ──▶ route(url, ctx) in config.js
                                                   │
                                  ┌────────────────┼─────────────────┐
                                  ▼                ▼                 ▼
                          Chrome "Work"      Safari            Ask dialog
                          (Profile 1)                          (pick one)
```

## Requirements

- macOS 13+
- Xcode / Swift toolchain (uses SwiftPM, AppKit, SwiftUI, JavaScriptCore — all built-in)

## Install

```sh
make install          # builds brouter.app, installs it, starts the launchd agent
make set-default      # make brouter your default http/https handler (macOS will confirm)
```

`make install` will:
1. build a release `brouter.app`,
2. copy it to `/Applications` (or `~/Applications` if that isn't writable),
3. register it with LaunchServices,
4. install + load a LaunchAgent at `~/Library/LaunchAgents/com.nikhiljha.brouter.plist`.

macOS will show a consent prompt — approve it. On recent macOS, `set-default`
may print a spurious `The file couldn't be opened` error even though the change
*succeeds* after you approve the prompt; verify in **System Settings → Desktop &
Dock → Default web browser** (you can also just set it there directly).

To uninstall:

```sh
make uninstall        # stops the agent, removes the app + LaunchAgent
```

## Configure

Your config lives at:

```
~/Library/Application Support/brouter/config.js
```

On first run brouter **auto-generates** this file, pre-populated with the
browsers and profiles detected on your Mac (run `brouter detect` to see them, or
`brouter init --force` to regenerate). Open it from the menu-bar icon → **Open
Config in Editor**, or `brouter edit`.

(Resolution order: `$BROUTER_CONFIG`, then the path above, then
`~/.config/brouter/config.js`. See `config.example.js` for a fully documented
template.)

Edit and save — brouter reloads automatically (it watches the file's mtime).

### `browsers`

```js
const browsers = {
  personal: { app: "Google Chrome", profile: "Default",   label: "Chrome — Personal" },
  work:     { app: "Google Chrome", profile: "Profile 1", label: "Chrome — Work" },
  safari:   { app: "Safari",                              label: "Safari" },
};
```

| field     | meaning |
|-----------|---------|
| `app`     | app name (`"Google Chrome"`), bundle id (`"com.google.Chrome"`), or full path |
| `profile` | *(optional)* Chromium `--profile-directory`, e.g. `"Default"`, `"Profile 1"` |
| `args`    | *(optional)* extra command-line args (e.g. Firefox `["-P", "work"]`) |
| `label`   | *(optional)* name shown in the Ask dialog |

> Find Chrome profile directory names at `chrome://version` → **Profile Path**
> (use the last path component, e.g. `Profile 1`).

### `route(url, ctx)`

`ctx` contains:

```
url, scheme, host, hostname, port, path, pathname, hash,
search, query {name: value}, sourceApp {name, bundleId, path}
```

Return any of:

| return value | behavior |
|--------------|----------|
| `"work"` | a key from `browsers` |
| `{ app: "Safari" }` | an inline target |
| `{ browser: "work" }` | reference a key explicitly |
| `{ ask: true }` | Ask dialog with **all** browsers |
| `{ ask: ["work", "personal"] }` | Ask dialog with these options |
| `{ ask: { options, message, default, timeout } }` | Ask dialog with full control |
| *(nothing)* | falls back to the first browser / Safari (so links are never lost) |

Example:

```js
function route(url, ctx) {
  const is = (d) => ctx.host === d || ctx.host.endsWith("." + d);

  if (is("github.com") || is("slack.com")) return "work";

  // Open links that came from Slack in the work profile.
  if (ctx.sourceApp && ctx.sourceApp.bundleId === "com.tinyspeck.slackmacgap") return "work";

  // Let me choose for meeting links, defaulting to work.
  if (is("zoom.us") || is("meet.google.com")) {
    return { ask: { options: ["work", "personal"], message: "Join meeting in…", default: "work" } };
  }

  return "personal";
}
```

`console.log(...)` from your config goes to the brouter log (see below).

## Menu bar

The agent shows a menu-bar icon (the branch glyph). **Click** for the menu;
**⌥-click** to also show the version and config status at the top.

- **Smart Config ▸** — *ask a coding agent to edit your config.* Lists whichever
  agents are available (hidden entirely if none are):
  - **Desktop apps** (no terminal): **Claude Code (app)** and **Codex (app)** —
    detected by `.app` presence and opened via their URL schemes
    (`claude://code/new`, `codex://threads/new`) with the config folder and a
    prompt prefilled.
  - **CLIs** (in a terminal): **Devin CLI**, **Claude Code (CLI)**, **Codex
    (CLI)** — detected on your `PATH`. Picking one opens it in a terminal `cd`'d
    to the config dir; if you have more than one terminal installed, brouter
    shows the same native picker to choose which. Devin runs with
    `--model swe-1.6-fast`.

  The prompt is also copied to your clipboard on launch, so if a deep-link
  prefill ever misses you can just paste it. **Copy Prompt** (always present,
  even if no agents are detected) puts the prompt on your clipboard so you can
  paste it into any tool you like.
- **Manual Config ▸** — Open in Editor · Reveal in Finder · Copy Config Path · Reload Config
- **Detected Browsers ▸** — every installed browser + profile; click one to copy
  its config key
- **Quit brouter** — stops the daemon (a clean quit won't be relaunched by
  launchd; clicking a link will still cold-launch it)

## Ask dialog

- Number keys **1–9** select an option
- **↩** picks the default (the highlighted one)
- **esc** (or clicking away) cancels

Preview it without being the default browser:

```sh
swift run brouter ask-demo
```

## CLI

The same binary is the agent and a small CLI:

```sh
brouter route <url>      # show where a URL would go (dry run, no launch)
brouter open <url>       # route and open a URL now
brouter validate         # load the config and report errors
brouter detect           # list autodetected browsers + profiles
brouter agents           # list detected coding agents + terminals
brouter init [--force]   # write a starter config (with detected browsers)
brouter edit             # open the config in your editor
brouter browsers         # list browsers defined in the config
brouter set-default      # set brouter as the default http/https handler
brouter config-path      # print the resolved config path
brouter help
```

During development:

```sh
make build               # debug build
make validate            # validate config
make route URL=https://github.com/x/y
make run                 # run the agent in the foreground
```

## How it works

- `brouter.app` declares `http`/`https` in `CFBundleURLTypes`, so it can be the
  default browser. macOS delivers clicked links via the standard `GetURL` Apple
  Event (`kInternetEventClass`/`kAEGetURL`).
- It's an `LSUIElement` agent (no Dock icon, just a menu-bar item). A LaunchAgent
  (`RunAtLoad` + `KeepAlive`/`SuccessfulExit=false`) keeps it running so config is
  preloaded and the Ask dialog is instant — but a clean **Quit** stays stopped.
- `config.js` is evaluated with JavaScriptCore. `route()` returns a target,
  which is launched via `/usr/bin/open` (Chromium profiles use
  `--profile-directory=...`).

## Logs & troubleshooting

- Log file: `~/Library/Logs/brouter.log`
- Restart the agent: `launchctl kickstart -k gui/$(id -u)/com.nikhiljha.brouter`
- If brouter doesn't appear in the default-browser list, re-register it:
  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/brouter.app
  ```
- After changing the bundle, run `make install` again to re-copy and reload.
- Config errors are printed to the log and to `brouter validate`; on a bad
  config, links fall back to the first browser / Safari.

## Repo layout

```
Package.swift
Sources/brouter/         Swift sources
  main.swift             entry point (CLI vs agent vs ask-demo)
  AppDelegate.swift      GetURL Apple Event handler + agent lifecycle
  Router.swift           JavaScriptCore config loading + route()
  BrowserLauncher.swift  launches apps / Chrome profiles via `open`
  BrowserDetector.swift  autodetect installed browsers + profiles
  ConfigGenerator.swift  build a starter config from detected browsers
  AgentLauncher.swift    detect coding agents/terminals + launch agent sessions
  StatusBar.swift        menu-bar (NSStatusItem) controller
  AskDialog.swift        native SwiftUI Ask picker (in an NSPanel)
  CLI.swift              route/open/validate/detect/init/set-default/...
  Config.swift           config path resolution + auto-create
  Models.swift           target / decision types
  Demo.swift             `ask-demo` preview
Resources/Info.plist     app bundle Info.plist (URL types, LSUIElement)
LaunchAgents/…plist       LaunchAgent template
scripts/                 bundle.sh, install.sh, uninstall.sh
config.example.js        documented config template
Makefile
```

Your live config is generated at `~/Library/Application Support/brouter/config.js`.
