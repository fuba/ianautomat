#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# != 3 || ! "$2" =~ ^[A-Z0-9]{10}$ || ! "$3" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 {prepare|upload} TEAM_ID BUILD_NUMBER" >&2
    exit 2
fi
action=$1
team=$2
number=$3
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
umask 077
out="$PWD/build/ios-distribution/$number"
archive="$out/ianautomat.xcarchive"
options="$out/ExportOptions.plist"
app="$out/Verified/Payload/ianautomat.app"

case "$action" in
    prepare)
        mkdir -p "$(dirname "$out")"
        mkdir "$out"
        xcodegen generate
        xcodebuild -project ianautomat.xcodeproj -scheme ianautomat -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath build/ios-release -archivePath "$archive" \
            DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$number" CODE_SIGNING_ALLOWED=NO \
            archive >"$out/archive.log" 2>&1 || { tail -60 "$out/archive.log" >&2; exit 1; }
        /usr/bin/plutil -create xml1 "$options"
        /usr/bin/plutil -insert method -string app-store-connect "$options"
        /usr/bin/plutil -insert teamID -string "$team" "$options"
        /usr/bin/plutil -insert destination -string export "$options"
        /usr/bin/plutil -insert signingStyle -string automatic "$options"
        /usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool NO "$options"
        /usr/bin/plutil -insert testFlightInternalTestingOnly -bool YES "$options"
        /usr/bin/plutil -insert uploadSymbols -bool YES "$options"
        xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/Export" \
            -exportOptionsPlist "$options" -allowProvisioningUpdates \
            >"$out/export.log" 2>&1 || { cat "$out/export.log" >&2; exit 1; }
        ditto -x -k "$out/Export/ianautomat.ipa" "$out/Verified"
        ;;
    upload)
        test -f "$out/archive.sha256"
        ;;
    *)
        echo "Unknown action: $action" >&2
        exit 2
        ;;
esac

requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and certificate leaf[field.1.2.840.113635.100.6.1.4] exists"
codesign --verify --deep --strict "-R=$requirement" "$app"
codesign -d --xml --entitlements - "$app" >"$out/entitlements.plist"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Info.plist")" = dev.fuba.ianautomat
test "$(/usr/bin/plutil -extract CFBundleVersion raw "$app/Info.plist")" = "$number"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$out/entitlements.plist")" = "$team"
test "$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$out/entitlements.plist")" = "$team.dev.fuba.ianautomat"
test "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$out/entitlements.plist")" = false
test "$(/usr/libexec/PlistBuddy -c 'Print :beta-reports-active' "$out/entitlements.plist")" = true
test -f "$app/PrivacyInfo.xcprivacy"

# Hash the archive files without a temporary ZIP, so repeat uploads verify the same contents.
digest_archive() {
    (
        cd "$archive"
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
    )
}

if [[ "$action" == prepare ]]; then
    digest_archive >"$out/archive.sha256"
    echo "Verified IPA: $out/Export/ianautomat.ipa"
else
    test "$(digest_archive)" = "$(cat "$out/archive.sha256")"
    upload_options="$out/UploadOptions.plist"
    cp "$options" "$upload_options"
    /usr/bin/plutil -replace destination -string upload "$upload_options"
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/Upload" \
        -exportOptionsPlist "$upload_options" -allowProvisioningUpdates \
        >"$out/upload.log" 2>&1 || { cat "$out/upload.log" >&2; exit 1; }
    cat "$out/upload.log"
fi
