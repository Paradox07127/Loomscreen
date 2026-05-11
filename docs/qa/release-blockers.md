# LiveWallpaper Release Blockers

## Severity Definitions

- P0: Blocks release. Crash, data loss, install failure, privacy/security issue, broken first-run, or core wallpaper cannot persist.
- P1: Should block release unless explicitly deferred. Major feature broken, severe UX regression, high battery/performance risk.
- P2: Can ship with release note or follow-up issue. Non-core visual or convenience issue.

## Open Blockers

| ID | Severity | Area | Issue | Repro | Owner | Decision | Status |
|---|---|---|---|---|---|---|---|
| RB-003 | P0 | Legal | Privacy Policy and Terms drafts exist but are not approved release text | `docs/legal/privacy-policy-draft.md` and `docs/legal/terms-of-use-draft.md` are marked draft | Product/Legal | Review, approve, and publish before public release | Open |
| RB-005 | P1 | Security | Source of NSSecureCoding allowed-classes warning is not identified | User runtime log included `allowed classes list contains [NSObject class]`; source search and 2026-05-10 continued picker/onboarding run did not reproduce it; static audit now fails app/test code that introduces broad `NSObject` NSSecureCoding decode allow-lists | Engineering | Keep targeted log capture on file-picker/bookmark paths before RC; likely system/AppKit unless reproduced in app-owned decode path | Open |
| RB-006 | P0 | Packaging | Release app is Apple Development signed and Gatekeeper rejects it | `scripts/release_candidate_check.sh` warns no Developer ID Application identity is installed on this Mac and now supports `REQUIRE_DEVELOPER_ID=1` to fail formal release checks; prior `spctl -a -vv --type execute` rejected the Apple Development-signed app | Engineering | Sign exported RC with Developer ID Application and notarize | Open |

## Deferred Issues

| ID | Severity | Area | Issue | Why Deferrable | Owner Approval | Follow-up |
|---|---|---|---|---|---|---|

## Closed In Current QA Pass

| ID | Area | Resolution |
|---|---|---|
| RB-001 | Packaging | Release build settings now report `ENABLE_HARDENED_RUNTIME = YES`; Release app CodeDirectory flags include `0x10000(runtime)` |
| RB-002 | Privacy | Added `LiveWallpaper/PrivacyInfo.xcprivacy`; `plutil -lint` passes and Release build bundles it under `Contents/Resources` |
| RB-004 | Documentation | README test count was updated to 560 and Release Readiness links were added |
| RB-007 | HTML UX | File picker now persists `.file` source instead of switching to Folder mode; helper text now directs sibling-asset pages to Folder mode |
| RB-008 | Theme QA | Re-ran settings UI under system Light appearance; sidebar, empty state, video detail, controls, and shader view used light backgrounds and readable text |
