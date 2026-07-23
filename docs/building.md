# Build from source

## Requirements

- macOS 14.0+ on an **Apple Silicon** Mac
- Xcode 16.2 or later
- The **Metal Toolchain** component (Xcode 26+ ships it as a separate download):
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
  Without it, compiling the `.metal` shaders fails with
  `cannot execute tool 'metal' due to missing Metal Toolchain`.

## Clone & open

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

## Schemes

| Scheme | Edition | Notes |
|---|---|---|
| `LiveWallpaperLite` | Lite | Sets `LITE_BUILD`; Pro-only sources (`#if !LITE_BUILD`) are excluded. Produces `Loomscreen.app` (`com.loomscreen`). |
| `LiveWallpaper` | Pro | Full build. Produces `LiveWallpaper.app` (`Taijia.LiveWallpaper`). |

Pick a scheme and `⌘R`.

> **Don't build both schemes in parallel** — they share the same
> `XCBuildData/build.db`.

## Before opening a PR

```bash
scripts/release_candidate_check.sh
```

The release-candidate gate runs the Core, ProWPE, and VideoWeb Swift package
tests first, then the signed Pro app tests, then the Lite build. These checks are
intentionally sequential; do not start Pro and Lite separately in parallel.
The suites enforce runtime invariants (localization coverage, particle/render
behavior, etc.); if a change needs to diverge from one, call it out in the PR
description.

## Test workflows

Use the smallest gate that answers the current question, then run the complete
release-candidate gate before integration.

```bash
# One or more affected Swift Testing suites; verifies every requested suite ran.
scripts/app_tests.sh suites LocalizationCoverageTests EntitlementAuditTests

# Complete signed Pro app test target. The current count floor prevents false-green runs.
scripts/app_tests.sh full

# Repeat either command without rebuilding after a successful build on the same DerivedData.
scripts/app_tests.sh suites LocalizationCoverageTests --without-building
scripts/app_tests.sh full --without-building

# Hardware-free architecture and security shard used for fast PR feedback.
scripts/fast_app_contract_tests.sh

# Complete package, Pro, Lite, archive, signing, and entitlement gate.
scripts/release_candidate_check.sh
```

The app-test scripts keep verbose `xcodebuild` output in a raw log and use the
generated `.xcresult` for the terminal summary, non-zero test-count assertion,
required-suite assertion, failures, and slowest-test list. The artifact paths
are printed after every run. Set `DERIVED_DATA` to reuse a build location, and
set a fresh `RESULT_BUNDLE` path when an external job needs deterministic
artifact placement.

Swift Testing already runs independent tests concurrently in-process. Keep
shared mutable state isolated per test and use `.serialized` only for suites
that cannot be isolated; globally increasing Xcode worker processes can make
the app tests less reliable because several suites exercise process-wide state.
The fast contracts intentionally disable Xcode multi-worker parallelization;
those suites have filesystem and process-lifecycle contracts that are not
isolated between runner processes.

## Packaging a release

See [`RELEASING.md`](../RELEASING.md) for the maintainer-only ad-hoc DMG
packaging flow, 0.2.3 preflight checklist, and current updater status.
