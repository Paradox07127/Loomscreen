# LiveWallpaper Privacy Policy Draft

Status: Draft for product/legal review before public release.

## Overview

LiveWallpaper is a macOS app that plays user-selected video, HTML, shader, and Wallpaper Engine-style content as desktop wallpaper. The app does not include an account system, advertising SDK, or analytics SDK in this repository.

## Data Stored On This Mac

LiveWallpaper stores app settings locally so wallpapers and preferences can restore across launches:

- Display wallpaper configuration and global preferences in macOS user defaults.
- Security-scoped bookmarks for user-selected videos, HTML files, folders, Apple Aerials folders, and Workshop folders.
- Trusted remote HTML origins chosen by the user.
- Optional app-owned imported video copies when macOS cannot create a persistent app-scope bookmark for a selected video.
- Extracted Wallpaper Engine package cache files in Application Support.
- WebKit website data for HTML wallpapers unless private/ephemeral browsing mode is enabled.

## Network Use

LiveWallpaper may make network requests only for features the user enables or content the user chooses:

- Weather effects request weather data from Open-Meteo using the selected or resolved coordinate.
- IP geolocation weather mode requests approximate location from ipapi.co.
- Remote HTML wallpapers load the URL chosen by the user through WebKit.

Remote HTML content may make its own network requests according to the page the user selected. JavaScript for remote HTML is disabled until the user trusts the exact origin.

## Location

Weather effects can use one of three location sources:

- Core Location, when the user grants macOS location permission.
- Manual city/location entry.
- IP geolocation, which estimates coarse location from the network IP address.

Location is used for weather-reactive wallpaper effects. LiveWallpaper does not use location for advertising or tracking.

## User Files

Selected local videos, HTML files, folders, Apple Aerials folders, and Workshop folders remain on the user's Mac unless the user-selected remote HTML page itself uploads or requests content. LiveWallpaper uses macOS security-scoped bookmarks to regain access after relaunch.

If app-scope bookmark creation fails for a selected video, LiveWallpaper may copy that video into its Application Support folder so the wallpaper keeps working after relaunch. The app reuses the same app-owned copy for the same source file when possible.

## Tracking And Advertising

LiveWallpaper does not use data for tracking, does not include advertising SDKs, and does not sell user data.

## Removal

Users can remove wallpapers, clear trusted hosts, clear caches, reset settings, or delete the app and its Application Support data. Removing app-owned imported videos or WPE caches may require reselecting or reimporting the wallpaper source.

## Contact

Add the release support contact before publication.
