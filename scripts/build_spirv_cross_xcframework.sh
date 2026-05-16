#!/usr/bin/env bash
# Builds glslang + SPIRV-Tools + SPIRV-Cross + the LiveWallpaper bridge
# layer into a single Metal-friendly XCFramework.
#
# This script is human-run, not CI-run — building the C++ toolchain takes
# ~10 minutes and produces a 40-80 MB binary artifact. CI shouldn't burn
# that time on every PR. Run this manually when bumping a pinned version,
# then commit the produced `ThirdParty/WPEShaderToolchain.xcframework`
# (git LFS) along with the pinned tags.
#
# Required tools: cmake (>= 3.20), python3, git, xcodebuild, libtool, lipo.
# Install via: brew install cmake
#
# Pinned tags. Bumping these requires re-running this script and committing
# the new artifact under the `[xcframework-rebuild-approved]` PR label so
# `Scripts/release_candidate_check.sh` doesn't reject it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GLSLANG_TAG="${GLSLANG_TAG:-15.4.0}"
SPIRV_TOOLS_TAG="${SPIRV_TOOLS_TAG:-vulkan-sdk-1.4.313.0}"
SPIRV_CROSS_TAG="${SPIRV_CROSS_TAG:-vulkan-sdk-1.4.313.0}"

THIRD_PARTY_ROOT="$ROOT/ThirdParty"
SOURCES_ROOT="$THIRD_PARTY_ROOT/sources"
BUILD_ROOT="$THIRD_PARTY_ROOT/_build"
INSTALL_ROOT="$THIRD_PARTY_ROOT/_install"
OUT_XCFRAMEWORK="$THIRD_PARTY_ROOT/WPEShaderToolchain.xcframework"
OUT_CHECKSUM="$THIRD_PARTY_ROOT/WPEShaderToolchain.xcframework.checksum"

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

mkdir -p "$SOURCES_ROOT" "$BUILD_ROOT" "$INSTALL_ROOT"

echo "== Resolving dependencies =="

clone_or_update() {
  local url="$1" tag="$2" dir="$3"
  if [[ ! -d "$dir/.git" ]]; then
    git clone --depth 1 --branch "$tag" "$url" "$dir"
  else
    (cd "$dir" && git fetch --tags --depth 1 origin "$tag" && git checkout -f "$tag")
  fi
}

clone_or_update https://github.com/KhronosGroup/glslang.git       "$GLSLANG_TAG"      "$SOURCES_ROOT/glslang"
clone_or_update https://github.com/KhronosGroup/SPIRV-Tools.git   "$SPIRV_TOOLS_TAG"  "$SOURCES_ROOT/SPIRV-Tools"
clone_or_update https://github.com/KhronosGroup/SPIRV-Cross.git   "$SPIRV_CROSS_TAG"  "$SOURCES_ROOT/SPIRV-Cross"

# SPIRV-Tools needs SPIRV-Headers next to it for its CMake to find them.
clone_or_update https://github.com/KhronosGroup/SPIRV-Headers.git "$SPIRV_TOOLS_TAG"  "$SOURCES_ROOT/SPIRV-Tools/external/spirv-headers"

echo "== Building SPIRV-Tools (static, arm64) =="
cmake -S "$SOURCES_ROOT/SPIRV-Tools" -B "$BUILD_ROOT/spirv-tools" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DSPIRV_WERROR=OFF \
  -DSPIRV_SKIP_TESTS=ON \
  -DSPIRV_SKIP_EXECUTABLES=ON \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF
cmake --build "$BUILD_ROOT/spirv-tools" -j
cmake --install "$BUILD_ROOT/spirv-tools" --prefix "$INSTALL_ROOT"

echo "== Building glslang (static, arm64, with SPIR-V output) =="
cmake -S "$SOURCES_ROOT/glslang" -B "$BUILD_ROOT/glslang" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_OPT=ON \
  -DALLOW_EXTERNAL_SPIRV_TOOLS=ON \
  -DGLSLANG_TESTS=OFF \
  -DENABLE_GLSLANG_BINARIES=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$INSTALL_ROOT"
cmake --build "$BUILD_ROOT/glslang" -j
cmake --install "$BUILD_ROOT/glslang" --prefix "$INSTALL_ROOT"

echo "== Building SPIRV-Cross (static, arm64, MSL backend only) =="
cmake -S "$SOURCES_ROOT/SPIRV-Cross" -B "$BUILD_ROOT/spirv-cross" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_ROOT" \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF \
  -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_HLSL=OFF \
  -DSPIRV_CROSS_ENABLE_REFLECT=ON \
  -DSPIRV_CROSS_ENABLE_C_API=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build "$BUILD_ROOT/spirv-cross" -j
cmake --install "$BUILD_ROOT/spirv-cross" --prefix "$INSTALL_ROOT"

echo "== Building LiveWallpaper bridge layer (Objective-C++) =="
BRIDGE_SRC="$THIRD_PARTY_ROOT/bridge/wpe_shader_toolchain.cpp"
BRIDGE_HEADER="$THIRD_PARTY_ROOT/bridge/WPEShaderToolchain.h"
if [[ ! -f "$BRIDGE_SRC" || ! -f "$BRIDGE_HEADER" ]]; then
  echo "ERROR: bridge source files missing — see ThirdParty/bridge/ for the C wrappers." >&2
  exit 1
fi
BRIDGE_OBJ="$BUILD_ROOT/bridge.o"
clang++ \
  -std=c++17 -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -O2 -fPIC \
  -I "$INSTALL_ROOT/include" \
  -I "$INSTALL_ROOT/include/spirv_cross" \
  -c "$BRIDGE_SRC" -o "$BRIDGE_OBJ"

echo "== Combining static libs into single archive =="
COMBINED="$BUILD_ROOT/libWPEShaderToolchain.a"
rm -f "$COMBINED"
libtool -static -o "$COMBINED" \
  "$BRIDGE_OBJ" \
  $(find "$BUILD_ROOT/glslang"     -name 'lib*.a' -print) \
  $(find "$BUILD_ROOT/spirv-tools" -name 'lib*.a' -print) \
  $(find "$BUILD_ROOT/spirv-cross" -name 'lib*.a' -print)

echo "== Packaging XCFramework =="
FRAMEWORK_STAGING="$BUILD_ROOT/staging/WPEShaderToolchain.framework"
mkdir -p "$FRAMEWORK_STAGING/Headers" "$FRAMEWORK_STAGING/Modules"
cp "$BRIDGE_HEADER" "$FRAMEWORK_STAGING/Headers/"
cp "$COMBINED"     "$FRAMEWORK_STAGING/WPEShaderToolchain"
cat > "$FRAMEWORK_STAGING/Modules/module.modulemap" <<EOF
framework module WPEShaderToolchain {
    umbrella header "WPEShaderToolchain.h"
    export *
    module * { export * }
}
EOF
cat > "$FRAMEWORK_STAGING/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key>          <string>com.livewallpaper.WPEShaderToolchain</string>
<key>CFBundleName</key>                <string>WPEShaderToolchain</string>
<key>CFBundleExecutable</key>          <string>WPEShaderToolchain</string>
<key>CFBundlePackageType</key>         <string>FMWK</string>
<key>CFBundleShortVersionString</key>  <string>1.0</string>
<key>CFBundleVersion</key>             <string>1</string>
<key>MinimumOSVersion</key>            <string>$DEPLOYMENT_TARGET</string>
</dict></plist>
EOF

rm -rf "$OUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
  -framework "$FRAMEWORK_STAGING" \
  -output "$OUT_XCFRAMEWORK"

echo "== Recording checksum =="
{
  echo "glslang: $GLSLANG_TAG"
  echo "spirv-tools: $SPIRV_TOOLS_TAG"
  echo "spirv-cross: $SPIRV_CROSS_TAG"
  echo "deployment-target: $DEPLOYMENT_TARGET"
  echo "framework-sha256: $(find "$OUT_XCFRAMEWORK" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
} > "$OUT_CHECKSUM"

echo "OK — XCFramework: $OUT_XCFRAMEWORK"
echo "OK — Checksum:    $OUT_CHECKSUM"
echo
echo "Next: commit $OUT_XCFRAMEWORK via git lfs and bump the pinned tags in this script."
echo "Add '[xcframework-rebuild-approved]' to the PR description so release_candidate_check.sh allows the binary churn."
