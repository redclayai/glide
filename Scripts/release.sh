#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, and publish a Glide release as a DMG on GitHub.
#
#     Scripts/release.sh [--skip-notarize] [--no-publish]
#
# Prerequisites (one-time):
#   - The "Developer ID Application: Red Clay AI, Inc (3RPG92BQ9C)" certificate in the login keychain.
#   - A notarytool keychain profile named by NOTARY_PROFILE below. Create it once with:
#
#       xcrun notarytool store-credentials glide-notary \
#         --apple-id <your-apple-id> --team-id 3RPG92BQ9C --password <app-specific-password>
#
#     The app-specific password comes from appleid.apple.com → Sign-In and Security.
#   - gh (GitHub CLI) authenticated against redclayai/glide.
#
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project before releasing; the
# script refuses to reuse a version that already has a tag.

APP_NAME="Glide"
SCHEME="KeyType"                      # the Xcode scheme still carries the upstream name
TEAM_ID="3RPG92BQ9C"
SIGN_IDENTITY="Developer ID Application: Red Clay AI, Inc (${TEAM_ID})"
# Any notarytool profile on this machine for team 3RPG92BQ9C works; millie-notary is the one that
# already exists, since both apps ship under the same Developer ID.
NOTARY_PROFILE="${GLIDE_NOTARY_PROFILE:-}"
REPO="redclayai/glide"
PAGES_URL="https://redclayai.github.io/glide"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$ROOT_DIR/KeyType.xcworkspace"
BUILD_DIR="$ROOT_DIR/.build/release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGE="$BUILD_DIR/dmg"
APPCAST_DIR="$BUILD_DIR/appcast"
APPCAST_PATH="$ROOT_DIR/docs/appcast.xml"
SPARKLE_BIN="$ROOT_DIR/.build/DerivedData-dev/SourcePackages/artifacts/sparkle/Sparkle/bin"

SKIP_NOTARIZE=0
PUBLISH=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --no-publish)    PUBLISH=0 ;;
    -h|--help)       sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# MARK: - Version

read -r VERSION BUILD_NUMBER <<<"$(
  perl -ne '
    if (!$b && /CURRENT_PROJECT_VERSION = ([^;]+);/) { $b = $1; $b =~ s/^"|"$//g }
    if (!$v && /MARKETING_VERSION = "?([^";]+)"?;/)  { $v = $1 }
    if ($v && $b) { print "$v $b\n"; exit }
  ' "$ROOT_DIR/KeyType.xcodeproj/project.pbxproj"
)"
[ -n "$VERSION" ] && [ -n "$BUILD_NUMBER" ] || fail "could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION"

TAG="v$VERSION"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

step "Releasing $APP_NAME $VERSION (build $BUILD_NUMBER)"

if git -C "$ROOT_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists — bump MARKETING_VERSION before releasing"
fi

security find-identity -v -p codesigning | grep -q "$TEAM_ID" \
  || fail "no Developer ID certificate for team $TEAM_ID in the keychain"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  if [ -z "$NOTARY_PROFILE" ]; then
    for candidate in glide-notary millie-notary; do
      if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
        NOTARY_PROFILE="$candidate"
        break
      fi
    done
  fi
  [ -n "$NOTARY_PROFILE" ] || fail \
"no notarytool keychain profile found (tried glide-notary, millie-notary). Create one with:

  xcrun notarytool store-credentials glide-notary \\
    --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>

or re-run with --skip-notarize to produce a signed but un-notarized DMG (Gatekeeper will warn on
any Mac other than this one)."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool profile '$NOTARY_PROFILE' exists but is not usable"
  step "Notarizing with profile '$NOTARY_PROFILE'"
fi

# MARK: - Build

step "Archiving"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_STAGE"
mkdir -p "$BUILD_DIR"

# Manual signing on purpose: this machine has two identically-named Apple Development certificates,
# which makes automatic selection ambiguous and fails the build. Naming the Developer ID identity
# outright sidesteps it — and is what a distribution build should use anyway.
xcodebuild archive \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  KEYTYPE_SKIP_DEV_APP_INSTALL=1 \
  | grep -E "error:|warning: (co|si)|ARCHIVE (SUCCEEDED|FAILED)" || true

[ -d "$ARCHIVE_PATH" ] || fail "archive failed"

step "Exporting"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP_PATH" ] || fail "export produced no $APP_NAME.app"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -2

# MARK: - Notarize the app

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  step "Notarizing the app"
  ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  rm -f "$ZIP_PATH"
fi

# MARK: - DMG

step "Building the disk image"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
# MIT obligation: the license notice travels with every distributed copy, upstream's included.
cp "$ROOT_DIR/LICENSE" "$DMG_STAGE/LICENSE.txt"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  step "Notarizing the disk image"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 | tail -2
fi

step "Built $(basename "$DMG_PATH") ($(du -h "$DMG_PATH" | cut -f1))"

# MARK: - Appcast

# Sparkle checks this feed to find updates, and verifies each download against the EdDSA signature
# generate_appcast writes here. The existing feed is copied in first so past releases survive:
# generate_appcast reuses an appcast it finds in the archives directory rather than starting over.
step "Updating the appcast"
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/"
if [ -f "$APPCAST_PATH" ]; then cp "$APPCAST_PATH" "$APPCAST_DIR/appcast.xml"; fi

[ -x "$SPARKLE_BIN/generate_appcast" ] || fail \
"Sparkle's generate_appcast is missing at $SPARKLE_BIN — build the app once so SwiftPM fetches it"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  "$APPCAST_DIR"

cp "$APPCAST_DIR/appcast.xml" "$APPCAST_PATH"
grep -q "$TAG/$(basename "$DMG_PATH")" "$APPCAST_PATH" \
  || fail "the appcast does not reference $TAG — Sparkle would not see this release"

# MARK: - Publish

if [ "$PUBLISH" -eq 1 ]; then
  step "Publishing $TAG to $REPO"
  # The appcast has to be on the default branch *before* the tag is cut, so GitHub Pages serves a
  # feed that matches the release the tag points at.
  git -C "$ROOT_DIR" add "$APPCAST_PATH"
  if ! git -C "$ROOT_DIR" diff --cached --quiet; then
    git -C "$ROOT_DIR" commit -q -m "Appcast: $APP_NAME $VERSION"
    git -C "$ROOT_DIR" push -q origin HEAD
  fi

  git -C "$ROOT_DIR" tag -a "$TAG" -m "$APP_NAME $VERSION"
  git -C "$ROOT_DIR" push origin "$TAG"

  # Notes live in the repo, so they are written and reviewed with the change rather than typed into
  # the GitHub UI afterwards and forgotten. A release without them is a release nobody can read.
  NOTES_FILE="$ROOT_DIR/docs/release-notes/$VERSION.md"
  [ -f "$NOTES_FILE" ] || fail "No release notes at docs/release-notes/$VERSION.md — write them first."
  NOTES="$(cat "$NOTES_FILE")"
  [ "$SKIP_NOTARIZE" -eq 1 ] && NOTES="$NOTES

⚠️ This build is signed but **not notarized** — macOS will refuse to open it on first launch.
Right-click the app → Open, or run \`xattr -dr com.apple.quarantine /Applications/Glide.app\`."

  gh release create "$TAG" "$DMG_PATH" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes "$NOTES"
  step "Published: https://github.com/$REPO/releases/tag/$TAG"
  step "Appcast: $PAGES_URL/appcast.xml"
else
  step "Skipped publishing (--no-publish). DMG at: $DMG_PATH"
fi
