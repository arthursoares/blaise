# Shared toolchain resolution for Blaise scripts. Sourced, not executed.
#
# Invoke the toolchain directly with an explicit SDKROOT and DEVELOPER_DIR
# pinned to the same Xcode so every lookup agrees.

# Prefer the canonical /Applications/Xcode.app, then any versioned install
# (Xcode_26.3.app, …). Prefer a macOS 26 SDK when one is installed; otherwise
# use the first installed macOS SDK newer than 26. First match wins.
XCODE_DEV=""
SDKROOT=""
for v in 26 '2[7-9]' '[3-9][0-9]'; do
    for candidate in /Applications/Xcode.app /Applications/Xcode*.app; do
        dev="$candidate/Contents/Developer"
        for sdk in "$dev"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX$v*.sdk; do
            [ -e "$sdk" ] && { XCODE_DEV="$dev"; SDKROOT="$sdk"; break 3; }
        done
    done
done

if [ -z "$XCODE_DEV" ]; then
    echo "error: no Xcode with a macOS 26 or newer SDK found under /Applications" >&2
    return 1 2>/dev/null || exit 1
fi

PLAT="$XCODE_DEV/Platforms/MacOSX.platform/Developer"
# Pin every toolchain lookup (swift-testing macros, xcrun) to the same Xcode the
# compiler comes from; the machine default may be a newer Xcode.
export DEVELOPER_DIR="$XCODE_DEV"
SWIFT="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

export SDKROOT

if [[ ! -x "$SWIFT" ]]; then
    echo "error: Xcode toolchain swift not found at $SWIFT (Xcode 26 required)" >&2
    exit 1
fi

# c15: local build defaults (bundle id + signing identity) live in a gitignored
# scripts/blaise.env so they are never committed. An explicit command
# environment wins over that file; this is essential for isolated QA builds,
# which must never accidentally inherit the production bundle identifier.
_BLAISE_BUNDLE_ID_OVERRIDE="${BLAISE_BUNDLE_ID:-}"
_BLAISE_SIGN_IDENTITY_OVERRIDE="${BLAISE_SIGN_IDENTITY:-}"
_BLAISE_APP_DISPLAY_NAME_OVERRIDE="${BLAISE_APP_DISPLAY_NAME:-}"
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/blaise.env" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/blaise.env"
fi
if [[ -n "$_BLAISE_BUNDLE_ID_OVERRIDE" ]]; then
    BLAISE_BUNDLE_ID="$_BLAISE_BUNDLE_ID_OVERRIDE"
fi
if [[ -n "$_BLAISE_SIGN_IDENTITY_OVERRIDE" ]]; then
    BLAISE_SIGN_IDENTITY="$_BLAISE_SIGN_IDENTITY_OVERRIDE"
fi
if [[ -n "$_BLAISE_APP_DISPLAY_NAME_OVERRIDE" ]]; then
    BLAISE_APP_DISPLAY_NAME="$_BLAISE_APP_DISPLAY_NAME_OVERRIDE"
fi
unset _BLAISE_BUNDLE_ID_OVERRIDE _BLAISE_SIGN_IDENTITY_OVERRIDE _BLAISE_APP_DISPLAY_NAME_OVERRIDE
export BLAISE_BUNDLE_ID="${BLAISE_BUNDLE_ID:-app.blaise.mac}"
export BLAISE_APP_DISPLAY_NAME="${BLAISE_APP_DISPLAY_NAME:-Blaise}"
