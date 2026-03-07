# AGENTS.md — mediatools

Coding-agent reference for the **mediatools** macOS app (Xcode 26.3, Swift 5.0).

---

## Project Overview

A native macOS media-tools suite built with SwiftUI. Features: image compression,
batch image compression, video compression, batch video compression, and video-to-
animated (GIF/WebP/APNG) conversion.

**Platform:** macOS 26.2+  
**Toolchain:** Xcode 26.3, Swift 5.0  
**Dependency:** 1 SPM package — `libwebp-Xcode 1.5.0` (WebP encoding only)

---

## Build & Run Commands

There is no Makefile, no shell scripts, and no CI configuration. All build and run
operations are done through `xcodebuild` or the Xcode GUI.

```bash
# Build (debug)
xcodebuild -project mediatools.xcodeproj -scheme mediatools -configuration Debug build

# Build (release)
xcodebuild -project mediatools.xcodeproj -scheme mediatools -configuration Release build

# Clean
xcodebuild -project mediatools.xcodeproj -scheme mediatools clean

# Resolve SPM packages
xcodebuild -resolvePackageDependencies -project mediatools.xcodeproj
```

### Tests

**There are currently no tests.** No test target exists in the project. Do not add
`XCTestCase` files or a test target unless explicitly asked to by the user.

### Lint / Format

**No linting or formatting tooling is configured** (no SwiftLint, no SwiftFormat,
no `.editorconfig`). Follow the style conventions below manually.

---

## Architecture

Strict **MVVM** with three layers. Never mix responsibilities across layers.

```
View (struct)
  └── ViewModel (@Observable final class)
        └── Model (struct Config/Result) + Service (final class singleton)
```

- **View** — SwiftUI `struct`. Owns the ViewModel via `@State private var vm = SomeViewModel()`. No business logic. Decomposed into private computed `var` properties (`leftPanel`, `rightPanel`, `dropArea`, `statusView`, etc.) rather than extracted child view types, except for batch row types which become `private struct`.
- **ViewModel** — `@Observable final class`. Owns all business logic: file picking, triggering compression, formatting output strings, exposing progress and errors.
- **Model / Service layer**:
  - **Config structs** — immutable value types that carry input parameters with sensible defaults.
  - **Result structs** — immutable value types that carry output data.
  - **Service singletons** — `final class` with `static let shared` and `private init()`. Stateless workers with `async`/`throws` methods.
- **Batch items** — `@Observable final class` (need identity + in-place mutation across async boundaries).

Each feature lives under `Features/<FeatureName>/` with `Model/`, `View/`, and
`ViewModel/` subdirectories.

---

## Code Style

### Naming

- Types, enums, protocols: `UpperCamelCase`
- Properties, methods, enum cases: `lowerCamelCase`
- ViewModel locals: always `vm` (`@State private var vm = SomeViewModel()`)
- App entry point: `mediatoolsApp` (lowercase `m`) — this is intentional, keep it

### Alignment

Align `=` in enum case raw-value declarations and `return` in switch bodies to the
same column within a block:

```swift
enum Tool: String, CaseIterable, Identifiable {
    case imageCompressor      = "图片压缩"
    case batchImageCompressor = "批量压缩"
    case videoCompressor      = "视频压缩"
}

var icon: String {
    switch self {
    case .imageCompressor:      return "photo.compress"
    case .batchImageCompressor: return "photo.stack"
    case .videoCompressor:      return "video.compress"
    }
}
```

### Imports

Import only what the file actually uses. Preferred import list by file type:

| File type | Typical imports |
|-----------|----------------|
| View      | `SwiftUI`, `UniformTypeIdentifiers` |
| ViewModel | `AppKit`, `Observation`, `UniformTypeIdentifiers` |
| Model/Service | `AppKit`, `AVFoundation`, `Foundation` |

Never import `UIKit`. Never add `import SwiftUI` to a pure model/service file.

### Types

- Services: `final class` + `static let shared` + `private init()`
- ViewModels: `@Observable final class`
- Views: `struct`
- Data containers (config, result): `struct`
- Enums used in `ForEach`/`List`: conform to `CaseIterable`, `Identifiable`, and
  `String` raw value

### Concurrency

The build setting `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is enabled — all
code is implicitly `@MainActor` unless explicitly annotated otherwise.

- Mark pure utility methods `nonisolated` so they can run off the main actor:
  ```swift
  nonisolated func thumbnail(for url: URL) async -> NSImage?
  ```
- Use `Task.detached(priority: .utility)` for background work; return to the main
  actor via `await MainActor.run { ... }`:
  ```swift
  Task.detached(priority: .utility) { [weak self] in
      let result = await SomeService.shared.process(url)
      await MainActor.run { self?.result = result }
  }
  ```
- Use `Task { }` (inherits `@MainActor`) for sequential async work that starts from
  a UI action.
- Use `Task.yield()` between batch items to keep the UI responsive.
- Always use `[weak self]` in closures that capture `self` across async boundaries.
- Poll progress with a child `Task` that calls `Task.sleep(nanoseconds:)` in a loop;
  cancel it with `progressTask.cancel()` after the export completes.
- Legacy `DispatchQueue.main.async` is acceptable only inside `NSItemProvider`
  completion handlers and `NSOpenPanel`/`NSSavePanel` callbacks, which return on
  arbitrary queues.

### Error Handling

Three patterns — choose based on context:

1. **Service errors** — define a `LocalizedError` enum with `errorDescription`; use
   `throws` on async service methods:
   ```swift
   enum VideoCompressionError: LocalizedError {
       case exportSessionFailed
       case exportError(String?)
       var errorDescription: String? { ... }
   }
   ```

2. **Fire-and-forget I/O** — use `try?` silently:
   ```swift
   try? FileManager.default.removeItem(at: dest)
   ```

3. **ViewModel error surfacing** — expose `var errorMessage: String?`; set it in
   `catch` blocks; display in the view as:
   ```swift
   if let error = vm.errorMessage {
       Text(error).foregroundStyle(.red).font(.caption)
   }
   ```

### Comments

- Section dividers: `// MARK: - SectionName`
- Inline notes: `//` on the same line or the line above (English or Chinese both OK)
- Doc comments: `///` on `nonisolated` or `public` methods only
- No `/* block */` comments, no `TODO:` / `FIXME:` markers

### File Headers

Every new `.swift` file starts with Xcode's standard header:

```swift
//
//  FileName.swift
//  mediatools
//
//  Created by <name> on <date>.
//
```

---

## UI Conventions

- **AppKit for file I/O only** — `NSOpenPanel`, `NSSavePanel`, `NSImage`,
  `NSBitmapImageRep`, `NSGraphicsContext`. All layout and navigation is SwiftUI.
- **No storyboards, no XIBs.**
- Use `NavigationSplitView` for top-level shell; `HSplitView` for two-pane tool
  layouts.
- Drag-and-drop via `.onDrop`; use `.contentShape(Rectangle())` on tap targets
  that would otherwise be transparent.
- Progress bars: `ProgressView(value:)` + `.progressViewStyle(.linear)` +
  `.controlSize(.small)`.
- `#Preview` macro (Xcode 15+ style) for all new views.
- UI strings are in **Simplified Chinese** — keep this consistent.

---

## Directory Layout

```
mediatools.xcodeproj/
mediatools/
├── mediatoolsApp.swift          # @main entry
├── ContentView.swift            # NavigationSplitView root
├── Core/
│   └── Tool.swift               # Master enum of all tools
└── Features/
    └── <FeatureName>/
        ├── Model/
        ├── View/
        └── ViewModel/
```

When adding a new feature, create a new directory under `Features/` following this
same `Model/View/ViewModel` structure. Register the feature in `Core/Tool.swift`.
