# LiveWallpaper RC Sign-Off

## Candidate

| Field | Value |
|---|---|
| Version | 1.0 |
| Build | 1 |
| Git commit | ad03cb3 plus working tree QA/docs/packaging/code changes |
| Archive path | `/tmp/LiveWallpaperFullQA-RC.xcarchive` |
| Distribution artifact | `/tmp/LiveWallpaperFixQARelease/Build/Products/Release/LiveWallpaper.app` for local verification only |
| Notarization request ID | |
| macOS SDK | 26.4 |
| Xcode version | Xcode 26.4.1 (17E202) |
| Minimum runtime target | macOS 14.0 |
| Supported architectures | Apple Silicon only (`ARCHS = arm64`) |
| Compatibility floor smoke | macOS 14 Apple Silicon (ENV-09) |
| Liquid Glass path smoke | macOS 26 Apple Silicon (ENV-11) |

## Automated Gates

| Gate | Command | Result | Evidence |
|---|---|---|---|
| Release candidate script | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer DERIVED_DATA=/tmp/LiveWallpaperReleaseCandidateCheck scripts/release_candidate_check.sh` | Passed with warning | Script ended with `Release candidate checks passed.`; warning remains for missing Developer ID Application identity. Use `REQUIRE_DEVELOPER_ID=1` for the formal signing-machine gate |
| Release build settings | `xcodebuild -showBuildSettings -configuration Release` | Passed | `ENABLE_HARDENED_RUNTIME = YES` |
| Privacy manifest | `plutil -lint LiveWallpaper/PrivacyInfo.xcprivacy` | Passed | Manifest lints cleanly and declares required-reason APIs |
| Unit tests | `xcodebuild test -only-testing:LiveWallpaperTests` | Passed | 669 tests in 98 suites passed (includes `MacOSCompatibilityPolicyTests`) |
| i18n guard | `I18N_GUARD_SCOPE=all scripts/i18n_guard.sh` | Passed | No output, exit 0 |
| Static audit | `scripts/audit.sh static` | Passed | Audit files generated; broad `NSObject` NSSecureCoding decode allow-lists fail the gate |
| Whitespace | `git diff --check` | Passed | No output, exit 0 |
| Archive | `xcodebuild archive ...` | Passed | `/tmp/LiveWallpaperFullQA-RC.xcarchive` |
| Release build | `xcodebuild build -configuration Release` | Passed | Local Release app built under `/tmp/LiveWallpaperFixQARelease` |
| Codesign inspect | `codesign -dvvv ...` | Partial | Hardened Runtime is present, but authority is Apple Development |
| Notarization | `xcrun notarytool submit ... --wait` | Blocked | Developer ID Application signing identity is missing on this Mac |
| Gatekeeper | `spctl -a -vv --type execute ...` | Failed | Rejected; origin is Apple Development |

## Manual Gates

| Area | Matrix Rows | Result | Evidence |
|---|---|---|---|
| First run | F-001 | Partial Pass | App defaults were cleared and onboarding completed without prompts; still needs a separate clean macOS user account pass |
| Core video persistence | F-002, F-003, F-004 | Partial Pass | Picker and fallback unit coverage passed; drag/drop now shares picker type validation and rejects unsupported files, but live drag/drop still needs manual pass |
| Multi-display | F-005 | Passed | Two-display apply and independent video/HTML relaunch verified |
| Playlist and schedule | F-006, F-007 | Not Started | Needs focused playlist/schedule pass |
| HTML | F-008, F-009, F-010 | Partial Pass | Local HTML passed; remote trust scenarios not tested |
| Shader and WPE | F-011, F-012, F-013 | Partial Pass | Built-in Shader > Plasma persisted after relaunch; frame-rate measurement and WPE import not tested |
| Weather and power | F-016, F-017, F-018, F-019, F-020 | Not Started | Permission, offline, battery, and full-screen policies not exercised |
| Theme and window behavior | F-022, F-023 | Passed | Window drag regression passed; Dark and Light settings UI passed visual inspection |
| Install/upgrade/removal | I-001 through I-005 | Failed | Gatekeeper rejects current archive; other install rows not tested |
| Security/privacy | S-001 through S-008 | Partial | Hardened Runtime and privacy manifest fixed; Developer ID/notarization and NSSecureCoding warning remain |

## Open Issues

| ID | Severity | Decision |
|---|---|---|
| RB-003 | P0 | Product/legal approval and publication required before public release |
| RB-005 | P1 | Targeted runtime reproduction still needed; static audit now blocks broad app-owned `NSObject` secure-decode allow-lists |
| RB-006 | P0 | Must sign with Developer ID Application and notarize before RC |

## Sign-Off

| Role | Name | Decision | Date |
|---|---|---|---|
| Engineering | | | |
| Product | | | |
| Legal/Privacy | | | |
| Release Owner | | | |
