// `LiveWallpaperCore` houses the SKU-neutral schemas + capability surface
// (see `Packages/LiveWallpaperCore/`). Re-export it from one place so every
// file in the main target gets the public types for free — adding
// `import LiveWallpaperCore` to ~hundreds of source files purely to access
// a leaf enum is a worse trade than this single re-export shim.
//
// When Phase 4–5 split out `LiveWallpaperVideoWeb` / `LiveWallpaperSharedUI`
// / `LiveWallpaperProFeatures` / `LiveWallpaperProWPE`, add their
// `@_exported import` here too. Once the main target shrinks to a thin
// app-glue layer, this file disappears and each app target imports the
// packages it actually needs directly.
@_exported import LiveWallpaperCore
@_exported import LiveWallpaperVideoWeb
@_exported import LiveWallpaperSharedUI
@_exported import LiveWallpaperProWPE
@_exported import LiveWallpaperProFeatures
