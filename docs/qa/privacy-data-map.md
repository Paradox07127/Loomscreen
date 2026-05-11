# LiveWallpaper Privacy And Data Map

## Product Position

LiveWallpaper has no account system, no advertising SDK, and no analytics SDK in the repository. The app uses local settings, user-selected local files, optional weather networking, optional CoreLocation, remote HTML chosen by the user, and app-owned caches.

## Local Storage

| Data | Storage | Purpose | User Visible | Removal |
|---|---|---|---|---|
| Screen wallpaper configuration | `UserDefaults.screenConfigurations` | Restore wallpapers across launches | Yes | Reset settings or delete app defaults |
| Global settings | `UserDefaults.globalSettings` | Restore app preferences | Yes | Reset settings or delete app defaults |
| Security-scoped bookmarks | UserDefaults encoded data | Persist access to selected videos/HTML/folders | Indirectly | Remove wallpaper/bookmark or reset settings |
| App-owned imported videos | `~/Library/Application Support/LiveWallpaper/ImportedVideos/` | Fallback when macOS cannot create app-scope bookmark | Yes | Cache cleanup UI or manual removal |
| WPE cache | `~/Library/Application Support/LiveWallpaper/wpe-cache/` | Extracted Wallpaper Engine packages | Yes | Cache management UI or manual removal |
| Trusted HTML hosts | `UserDefaults.TrustedHTMLHosts.v1` | Allow JavaScript for trusted origins | Yes | Remove trusted host/reset settings |
| WKWebView website data | WebKit data store or non-persistent store based on setting | Remote/local HTML wallpaper functionality | Yes | Enable private mode or clear website data |

## Network Requests

| Destination | Trigger | Data Sent | Data Received | User Control | Disclosure |
|---|---|---|---|---|---|
| `https://api.open-meteo.com` | Weather-reactive effects enabled | Latitude/longitude in query | Weather code, temperature, cloud cover | Disable weather or use manual/IP/CoreLocation settings | Weather functionality |
| `https://ipapi.co/json/` | Weather source set to IP geolocation or fallback | IP address as part of HTTPS request | Coarse latitude/longitude, city, country | Choose manual or CoreLocation source, disable weather | Coarse location via IP |
| User-entered remote HTML URL | User chooses remote HTML wallpaper | Normal WebKit request data for that URL | Web content | User controls URL; JS disabled until trusted | User-directed web content |

## Permission Prompts

| Permission | Info.plist Key | Trigger | Required For |
|---|---|---|---|
| Location | `NSLocationWhenInUseUsageDescription` | Weather source set to CoreLocation | Weather-reactive effects |
| User-selected files | Sandbox user-selected files/bookmarks | Video/HTML/WPE folder pickers | Wallpaper playback and persistence |
| Downloads/Movies folder read-only | Sandbox entitlement | User selects files from these folders | File playback |
| Startup items | `com.apple.security.automation.startup-items` | Launch at login toggle | Start app at login |

## Privacy Manifest Decisions To Verify

| Item | Expected Decision | Evidence Needed |
|---|---|---|
| Tracking | No tracking | Declared in `LiveWallpaper/PrivacyInfo.xcprivacy`; no ad SDK, no analytics SDK, no data broker sharing |
| Crash analytics | Not collected by app | No crash reporting SDK present |
| Precise location | Only if CoreLocation weather source is used and sent to Open-Meteo | Declared in `LiveWallpaper/PrivacyInfo.xcprivacy`; confirm final policy copy |
| Coarse location | IP geolocation weather source sends IP to ipapi.co and receives coarse coordinate | Declared in `LiveWallpaper/PrivacyInfo.xcprivacy`; confirm final policy copy |
| User content | User-selected local files stay local unless remote HTML itself loads network content | Confirm final policy copy |

## Release Artifacts

| Artifact | Status | Notes |
|---|---|---|
| `LiveWallpaper/PrivacyInfo.xcprivacy` | Added | `plutil -lint` passes; Release build bundles the manifest in `LiveWallpaper.app/Contents/Resources` |
| `docs/legal/privacy-policy-draft.md` | Draft | Product/legal review required before public release |
| `docs/legal/terms-of-use-draft.md` | Draft | Product/legal review required before public release |
