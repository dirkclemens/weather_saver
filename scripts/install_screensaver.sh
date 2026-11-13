#!/bin/bash
#
# install_screensaver.sh
#
# Builds the WeatherSaver screensaver and installs it to
# ~/Library/Screen Savers/ so it appears in System Settings.
#
# Usage:
#   ./scripts/install_screensaver.sh [--build-only|--install-only]
#
# Options:
#   --build-only   Only build, do not install
#   --install-only Only install from an existing build (skip xcodebuild)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="WeatherSaver"
SCHEME_NAME="WeatherSaver"
CONFIGURATION="Release" # optimised build – the procedural textures are much faster

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
BUILD=true
INSTALL=true

for arg in "$@"; do
  case "$arg" in
    --build-only) INSTALL=false ;;
    --install-only) BUILD=false ;;
    --help|-h)
      echo "Usage: $0 [--build-only|--install-only]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Use --help for usage information."
      exit 1
      ;;
  esac
done

DEST_DIR="$HOME/Library/Screen Savers"
DERIVED_DATA="$PROJECT_DIR/.DerivedData"

echo "=============================================="
echo "  WeatherSaver Installer"
echo "=============================================="
echo "Project dir: $PROJECT_DIR"
echo "Destination: $DEST_DIR"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Build (optional)
# -----------------------------------------------------------------------------
if $BUILD; then
  echo "[1/2] Building WeatherSaver ($CONFIGURATION)..."

  mkdir -p "$DERIVED_DATA"

  xcodebuild \
    -project "$PROJECT_DIR/WeatherSaver.xcodeproj" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    build

  echo "Build succeeded."
  echo ""
fi

# -----------------------------------------------------------------------------
# Step 2: Locate and install the .saver bundle
# -----------------------------------------------------------------------------
if $INSTALL; then
  echo "[2/2] Installing to $DEST_DIR ..."

  # Find the built .saver bundle in DerivedData products
  SAVER_PATH=$(find "$DERIVED_DATA/Build/Products" -name "WeatherSaver.saver" -type d 2>/dev/null | head -n 1 || true)

  if [[ -z "$SAVER_PATH" ]]; then
    echo "ERROR: Could not find WeatherSaver.saver in DerivedData products."
    echo "       Searched: $DERIVED_DATA/Build/Products"
    exit 1
  fi

  echo "Found: $SAVER_PATH"

  # Ensure destination exists
  mkdir -p "$DEST_DIR"

  # Remove any previous installation
  if [[ -e "$DEST_DIR/WeatherSaver.saver" ]]; then
    echo "Removing previous installation..."
    rm -rf "$DEST_DIR/WeatherSaver.saver"
  fi

  # Copy the bundle
  cp -a "$SAVER_PATH" "$DEST_DIR/"

  echo "Installed: $DEST_DIR/WeatherSaver.saver"
  echo ""
  echo "Done! Open System Settings > Desktop & Screen Saver to enable WeatherSaver."
fi
