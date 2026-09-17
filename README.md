# Thuban Study

A native macOS study app: import course documents, let a Claude agent build a question bank per class,
then work problems WebAssign-style next to a tutor that guides instead of answers. Math questions regenerate
with fresh numbers and any algebraically equivalent answer is accepted unless the question sets conditions.
Desmos-powered 2D/3D graphing and a calculator sit one toggle away. Everything is stored locally.

Design canvas: https://claude.ai/artifact/MbqgQgK5BeX9tkoCsXkV9X

## Requirements

- macOS 15 or newer, Xcode 26 (the project uses the Swift 6 toolchain in Swift 5 language mode).
- A Desmos API key in `ThubanStudy/Resources/Secrets.plist` (gitignored; copy `Secrets.example.plist`). The key can
  also be pasted later in Settings › Grapher.
- A Claude account (Settings › Claude account › Connect, a personal-use OAuth flow) or an Anthropic API key.

## Build and run

```sh
./scripts/build.sh          # Debug build into .build/DerivedData
open ".build/DerivedData/Build/Products/Debug/Thuban Study.app"
./scripts/test.sh           # ThubanCore package tests (grading, templates, store, theme, parsers, AI client)
./scripts/smoke.sh          # launches with seeded demo data and writes screenshots of every screen
```

Or open `ThubanStudy.xcodeproj` in Xcode and run the `ThubanStudy` scheme. The project file is generated from
`project.yml` with XcodeGen; regenerate it after adding source files.

## Layout

- `Packages/ThubanCore` — the engine: domain models, GRDB store, theme resolver (color schemes from Atlas),
  math engine (Cortex Compute Engine in JavaScriptCore: grading, equivalence, conditions, template
  instantiation), Claude client with OAuth and the tutor/import/figure agents, and document parsers
  (PDF, Word, PowerPoint, Excel, CSV, HTML, MHTML, Markdown, text, images with OCR).
- `ThubanStudy` — the SwiftUI app: shell with class tabs, Study (question form, tutor, graph, calculator,
  math keyboard), Question bank, Import with figure review, Settings, modals.
- `ThubanStudy/Resources/web` — the WKWebView pages: MathLive question form and keyboard, Desmos graph and
  scientific calculator, tutor transcript renderer. Vendored libraries live under `web/vendor`.
- `docs/` — design brief, color values, icon set, architecture contract, integration notes.

## Data

Everything lives under `~/Library/Application Support/Thuban Study` (SQLite database, imported documents,
clipped figures). Set `THUBAN_HOME` to relocate it. Settings › Data & storage exports a zip.
