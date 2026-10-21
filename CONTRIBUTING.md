# Contributing to Airy

Thanks for helping! Issues and pull requests are welcome.

## Getting started

```bash
git clone https://github.com/luis-guillen/airy.git && cd airy
swift build
swift test --no-parallel
AIRY_SUPPORT_DIR=$(mktemp -d) AIRY_SCAN_ROOTS=$HOME/Downloads .build/debug/Airy   # safe dev run
```

You need macOS 15+ and the Xcode Command Line Tools (Swift 6.3+).

## Ground rules (safety first)

1. Every destructive action must go through `ConfirmSheet → AppModel → CleanupExecutor` (quitting apps
   goes through `QuitExecutor`). No shortcuts, not even in DEBUG.
2. Never weaken `HardProtections` or `CommandPolicy`. New cleanup targets go into `catalog.json` with the
   lowest risk that is honest.
3. AI and MCP can only *raise* risk. They never receive file contents.
4. Tests use temporary folders and fakes. They never touch the real disk, never run real cleanup
   commands and never quit real apps.
5. Keep Airy light: no work at rest, and animations must pause when the window isn't visible.

## Workflow

1. Open an issue for anything non-trivial, so we can agree on the approach first.
2. Branch from `main`: `feat/…`, `fix/…`, `docs/…`.
3. Add or update tests in `Tests/DiskMapCoreTests`.
4. Run `swift build` and `swift test --no-parallel`.
5. Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `perf:`…) and
   add a line to `CHANGELOG.md` under **Unreleased**.
6. Open the PR; CI must be green.

## Translations

The UI is localized with String Catalogs: English is the base language and Spanish is a translation.
To add a language, add it to `Resources/Localizable.xcstrings` (app) and
`Sources/DiskMapCore/Resources/Localizable.xcstrings` (core), plus the localized fields in `catalog.json`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
