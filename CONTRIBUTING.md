# Contributing to DockPup

Bug reports, documentation improvements, and focused pull requests are welcome.
Please discuss substantial behavior changes in an issue before implementing them.

## Development

Use macOS with Xcode or the Command Line Tools installed. DockPup has no
third-party dependencies or package installation step.

```sh
bash scripts/build.sh
open .build/DockPup.app
```

Quit a running development copy before rebuilding it. The script builds for the
host architecture and signs the resulting app ad hoc. A new build may need its
Accessibility permission refreshed; see the README.

## Project layout

- `Sources/DockPup/main.swift`: app lifecycle and menu bar controls.
- `Sources/DockPup/DockController.swift`: event tap, Dock movement, and recovery.
- `Sources/DockPup/Display.swift`: display geometry and exposed bottom edges.
- `Resources/AppIcon.png`: editable raster artwork; the build generates ICNS sizes.
- `Resources/Info.plist`: application metadata.
- `Resources/*.lproj/Localizable.strings`: localized interface text.
- `scripts/build.sh`: native build, icon generation, and local signing.

The bundle identifier `local.g.lockdog` is a stable system identity, independent
of the app's display name. The same identifier is used for application logging.

## Before opening a pull request

Run the packaging checks:

```sh
bash -n scripts/build.sh
bash scripts/build.sh
plutil -lint Resources/Info.plist .build/DockPup.app/Contents/Info.plist
codesign --verify --strict --verbose=2 .build/DockPup.app
git diff --check
```

GitHub Actions runs build and packaging checks. It does not verify Dock placement
or simulate a real multi-display session. There is no automated hardware test suite.

For changes to geometry, input handling, or recovery, report the macOS version,
CPU architecture, display arrangement, and results of these manual checks:

1. Start with the Dock on the built-in display. Retry and confirm that it moves
   to the external display after input becomes idle.
2. Push the pointer against the built-in display's exposed bottom edge. Confirm
   that the Dock stays on the external display and the blocked-move count rises.
3. Move or click during recovery. Confirm that automatic movement is interrupted
   and that the cursor is not pulled back to a stale position.
4. Unplug and reconnect the external display; then test sleep, wake, and unlock.
5. Pause and resume locking. Check cross-display movement, dragging, Hot Corners,
   and controls near guarded bottom edges.

## Scope and style

Keep changes small and preserve the dependency-free native implementation.
Use English for code comments, source message keys, issues, and pull requests. Keep
`README.zh-CN.md` consistent when changing documented behavior.
Keep interface translations in the `.strings` files, using matching keys and
format placeholders across languages. Controller messages stay in English for
diagnostics; their displayed translations use concise wording.

Do not include build outputs, profiler captures, personal paths, or unredacted
system logs in a pull request. Application status logs can be inspected with:

```sh
/usr/bin/log stream --style compact --predicate 'subsystem == "local.g.lockdog"'
```

For a bug report, include only the relevant interval and redact personal data.
For security issues, follow [SECURITY.md](SECURITY.md).

Contributions are licensed under the project's GPL-3.0-or-later terms. Keep
license notices intact and identify the source and license of any third-party material.
