# Sendpoint

Select text in any app, annotate it by typing or speaking, collect notes in one of four stacks, paste a stack as Markdown. Nothing else.

## How it works

- All behavior lives in `step(&world, event) -> [Effect]` in `Sources/Core/World.swift`. It is pure (Foundation only) and the only place decisions are made.
- `Sources/App/main.swift` is the loop: a key or callback sends an `Event`, `step` updates `world`, `render()` redraws from `world`, and `perform` carries out each `Effect`.
- The App files only translate: `Keys` (Carbon hotkeys), `Selection` (Accessibility read, ⌘C fallback, ⌘V paste), `Speech` (mic + SpeechAnalyzer + level meter), `Panel` (the note card), `Readout` (the pill that flashes after a stack shortcut), `StatusMenu`.
- Speech results carry their `take`. `step` drops any result whose take doesn't match, so old or cancelled recordings can't land.
- Notes persist only as Markdown: `~/Library/Application Support/Sendpoint/stack-N.md`, one per stack, read at launch by `loadWorld` and written off the main thread on every change. The `open` shortcut opens that file in the user's editor. Edits saved there come back: `pollStacks` reads the files once a second on the disk queue and sends `.edited` when one differs from what the app last wrote, and `parseStackDocument` turns it back into notes. There is no stack viewer.
- Settings are `~/.config/sendpoint/config.toml` (or `$XDG_CONFIG_HOME`), a small TOML subset parsed by `parseConfig` in `Sources/Core/Config.swift` into `world.config`. `main.swift` polls its mtime once a second and sends `.configure`; a change to the keys yields `.bindKeys`. The file is written from `defaultConfigText` when missing. There is no settings window: the menu's "Edit Config…" opens the file, and mistakes in it show in the menu.

## Rules

- New behavior is a new `Event` or `Effect` case, a `step` branch, and a test in `Tests/CoreTests/StepTests.swift`. Views never decide; they `send`.
- Keep the hot path synchronous: hotkey → read selection → `send`. Build windows and load models at launch, never on a keypress.
- No SwiftUI, no macros, no dependencies. Code that is slow to type-check gets a compiler warning (see `Package.swift`); fix it.
- Main thread everywhere (`defaultIsolation(MainActor)`). Only `Tap` in `Speech.swift` runs on the audio thread.
- Shortcuts and card look come from the config file only. A new setting is a `Config` field, a `parseConfig` case and a line in `defaultConfigText`; `defaultConfigFileParsesToTheBuiltInDefaults` keeps the last two in step.
- Write the concrete code first and pull out a shared piece only once it is needed in a second place. No tables, protocols or helpers for a single use.

## Commands

- `./check.sh`: build and run Core tests.
- `./build.sh`: assemble, sign, and verify `dist/Sendpoint.app`. Use `CODESIGN_IDENTITY=- ./build.sh` for a local ad-hoc build without a signing identity.
- `scripts/check-app.sh [APP]`: verify an existing bundle without launching it. The default is `dist/Sendpoint.app`; relative paths are relative to the repository root.
- `scripts/smoke-app.sh [APP]`: verify a bundle, then run its executable with `--integration-smoke`. The app creates and removes a private temporary notes/config directory. Controlled selection and speech callbacks drive the real event/effect loop, Markdown persistence/loading/polling, config polling, and readout timer. Paste, editor opening, and key binding are recorded rather than performed. It creates no AppKit UI, audio engine, hotkeys, or permission requests. Both the app and runner enforce timeouts. This is not an interactive UI or hardware test.
- `./install.sh`: build, install to /Applications, relaunch. Run it only when asked.
- `scripts/package.sh VERSION`: the release DMG, ad-hoc signed unless Developer ID secrets are set (see the script).
- Releases are CI: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`; `nightly.yml` rebuilds the `nightly` prerelease from `main` each night. Push tags only when asked.

## Verify a change

1. Use macOS 26+ and Swift 6.2+ with the macOS 26 SDK. `Package.swift` declares these minimums.
2. Run `./check.sh` for every change. Tests use Swift Testing; read its final test count, not XCTest's preceding "Executed 0 tests" line.
3. For app, resource, or build changes, run `CODESIGN_IDENTITY=- ./build.sh`. The bundle check validates metadata, the executable format, bundled icon and fonts, the code signature, and the audio-input entitlement. It does not launch the app.
4. Run `scripts/smoke-app.sh` for app-loop changes. Never launch the normal app as an unattended test. No Core behavior is added by the smoke harness; Core transitions remain covered by `StepTests`.
5. Report the commands run and any unverified behavior. `.github/workflows/verify.yml` runs all three checks on pushes and pull requests with `macos-26`.

Core tests exercise state transitions, config parsing, and Markdown conversion. They do not exercise AppKit rendering, global hotkeys, Accessibility selection and paste, microphone capture, speech model availability, or disk polling in `main.swift`. A bundle check does not prove those integrations work. Launching the normal app requests permissions, prewarms speech, and reads real notes and config. Do not use it as an unattended smoke test or touch the user's notes, config, clipboard, or permission grants to manufacture a passing result.
