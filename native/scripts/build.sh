#!/usr/bin/env bash
set -euo pipefail

# Run on macOS with Xcode and XcodeGen; never requires an Apple account.
task_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_dir"
task_mode="${1:-all}"
task_build="$task_dir/build"
task_artifacts="$task_build/artifacts"
task_previous="$task_build/previous/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$task_artifacts"
command -v xcodegen >/dev/null || { echo "Install XcodeGen before building." >&2; exit 1; }
xcodebuild -version
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project NoteAssistant.xcodeproj -scheme NoteAssistant

preserve_previous_outputs() {
    local -a task_output_names
    local task_output_name
    local task_preserved=0
    # Only these script-owned names may be moved. Never accept an output path
    # from the caller, and keep the other build mode's current artifacts intact.
    case "$1" in
        simulator)
            task_output_names=(SimulatorTests.xcresult UIAttachments Screenshots NoteAssistant-simulator.zip)
            ;;
        device)
            task_output_names=(NoteAssistant-unsigned.ipa NoteAssistant-resign-input.ipa \
                App-requested.entitlements Extension-requested.entitlements \
                App-source.entitlements Extension-source.entitlements SHA256SUMS.txt INSTALL-NOTES.txt \
                PackageVerification.json)
            ;;
        *) echo "Unknown artifact mode." >&2; return 2 ;;
    esac
    for task_output_name in "${task_output_names[@]}"; do
        if test -e "$task_artifacts/$task_output_name" || test -L "$task_artifacts/$task_output_name"; then
            mkdir -p "$task_previous"
            if test -e "$task_previous/$task_output_name" || test -L "$task_previous/$task_output_name"; then
                echo "Refuse to overwrite previous artifact: $task_previous/$task_output_name" >&2
                return 1
            fi
            mv "$task_artifacts/$task_output_name" "$task_previous/$task_output_name"
            task_preserved=1
        fi
    done
    if test "$task_preserved" = 1; then echo "Preserved previous $1 artifacts: $task_previous"; fi
}

build_simulator() {
    preserve_previous_outputs simulator
    task_simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = [d for runtime, values in data["devices"].items() if ".iOS-" in runtime for d in values if d.get("isAvailable") and "iPad" in d["name"]]
if not devices:
    raise SystemExit("No available iPad simulator runtime. Install an iOS simulator in Xcode.")
print(devices[0]["udid"])
')"
    xcodebuild build -project NoteAssistant.xcodeproj -scheme NoteAssistant \
        -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$task_simulator_id" \
        -derivedDataPath "$task_build/simulator" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    task_test_status=0
    xcodebuild test -project NoteAssistant.xcodeproj -scheme NoteAssistant \
        -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$task_simulator_id" \
        -derivedDataPath "$task_build/simulator" -resultBundlePath "$task_artifacts/SimulatorTests.xcresult" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO || task_test_status=$?
    if test -d "$task_artifacts/SimulatorTests.xcresult"; then
        xcrun xcresulttool export attachments --path "$task_artifacts/SimulatorTests.xcresult" \
            --output-path "$task_artifacts/UIAttachments"
    fi
    task_simulator_app="$task_build/simulator/Build/Products/Debug-iphonesimulator/NoteAssistant.app"
    task_boot_state="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for values in json.load(sys.stdin)["devices"].values():
    for device in values:
        if device["udid"] == sys.argv[1]:
            print(device["state"])
' "$task_simulator_id")"
    if test "$task_boot_state" != "Booted"; then xcrun simctl boot "$task_simulator_id"; fi
    xcrun simctl bootstatus "$task_simulator_id" -b
    xcrun simctl install "$task_simulator_id" "$task_simulator_app"
    xcrun simctl launch "$task_simulator_id" com.local.noteassistant
    sleep 3
    mkdir -p "$task_artifacts/Screenshots"
    xcrun simctl io "$task_simulator_id" screenshot "$task_artifacts/Screenshots/overview.png"
    ditto -c -k --sequesterRsrc --keepParent \
        "$task_simulator_app" \
        "$task_artifacts/NoteAssistant-simulator.zip"
    return "$task_test_status"
}

build_device() {
    preserve_previous_outputs device
    xcodebuild build -project NoteAssistant.xcodeproj -scheme NoteAssistant \
        -configuration Release -sdk iphoneos -destination "generic/platform=iOS" \
        -derivedDataPath "$task_build/device" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
    task_app="$task_build/device/Build/Products/Release-iphoneos/NoteAssistant.app"
    test -d "$task_app/PlugIns/AskAI.appex" || { echo "Ask AI extension is missing; refuse to package." >&2; exit 1; }
    test "$(lipo -archs "$task_app/NoteAssistant")" = "arm64" || { echo "Expected an arm64 device executable." >&2; exit 1; }
    task_unsigned="$(mktemp -d "$task_build/unsigned.XXXXXX")"
    mkdir -p "$task_unsigned/Payload"
    ditto "$task_app" "$task_unsigned/Payload/NoteAssistant.app"
    (cd "$task_unsigned" && /usr/bin/zip -q -r "$task_artifacts/NoteAssistant-unsigned.ipa" Payload)

    # Preserve requested capabilities in an ad-hoc signature for re-signing tools.
    # LOCALTEAM0 is a placeholder, not a real Apple team or installable signature.
    task_resign="$(mktemp -d "$task_build/resign.XXXXXX")"
    mkdir -p "$task_resign/Payload"
    ditto "$task_app" "$task_resign/Payload/NoteAssistant.app"
    python3 - "$task_dir" "$task_artifacts" <<'PY'
import pathlib, plistlib, sys
source, output = map(pathlib.Path, sys.argv[1:])
for filename, bundle_id in [("App", "com.local.noteassistant"), ("Extension", "com.local.noteassistant.AskAI")]:
    text = (source / "Config" / (filename + ".entitlements")).read_text(encoding="utf-8")
    entitlements = plistlib.loads(text.replace("$(AppIdentifierPrefix)", "LOCALTEAM0.").encode())
    entitlements["application-identifier"] = "LOCALTEAM0." + bundle_id
    entitlements["com.apple.developer.team-identifier"] = "LOCALTEAM0"
    with (output / (filename + "-requested.entitlements")).open("wb") as stream:
        plistlib.dump(entitlements, stream)
PY
    task_resign_app="$task_resign/Payload/NoteAssistant.app"
    while IFS= read -r -d '' task_library; do
        codesign --force --sign - "$task_library"
    done < <(find "$task_resign_app" -name '*.dylib' -type f -print0)
    while IFS= read -r -d '' task_framework; do
        codesign --force --sign - "$task_framework"
    done < <(find "$task_resign_app" -name '*.framework' -type d -print0)
    codesign --force --sign - --entitlements "$task_artifacts/Extension-requested.entitlements" \
        "$task_resign_app/PlugIns/AskAI.appex"
    codesign --force --sign - --entitlements "$task_artifacts/App-requested.entitlements" "$task_resign_app"
    codesign --verify --deep --strict "$task_resign_app"
    (cd "$task_resign" && /usr/bin/zip -q -r "$task_artifacts/NoteAssistant-resign-input.ipa" Payload)
    python3 "$task_dir/scripts/verify_device_package.py" \
        --unsigned "$task_artifacts/NoteAssistant-unsigned.ipa" \
        --resign-input "$task_artifacts/NoteAssistant-resign-input.ipa" \
        --project-spec "$task_dir/project.yml" \
        --output "$task_artifacts/PackageVerification.json"
    cp "$task_dir/Config/App.entitlements" "$task_artifacts/App-source.entitlements"
    cp "$task_dir/Config/Extension.entitlements" "$task_artifacts/Extension-source.entitlements"
    (cd "$task_artifacts" && shasum -a 256 NoteAssistant-unsigned.ipa NoteAssistant-resign-input.ipa > SHA256SUMS.txt)
    cat > "$task_artifacts/INSTALL-NOTES.txt" <<'NOTES'
Both device IPAs need Apple signing before installation. The simulator ZIP cannot run on an iPad.
NoteAssistant-unsigned.ipa: pure unsigned arm64 app plus AskAI extension.
NoteAssistant-resign-input.ipa: ad-hoc signed with placeholder LOCALTEAM0 capabilities, intended for Sideloadly re-signing. It is NOT an Apple distribution-signed package.
Use the same Apple ID and app identifiers for USB renewal. Preserve extensions; do not uninstall the app.
Before relying on this build, verify App Group + shared Keychain in the installed provisioning profiles and perform a real Goodnotes share, standalone API request, and overwrite renewal test.
Signing failures, stripped capabilities, or retained data have not been proven merely by this build.
NOTES
}

case "$task_mode" in
    simulator) build_simulator ;;
    device) build_device ;;
    all) build_simulator; build_device ;;
    *) echo "Usage: bash scripts/build.sh [all|simulator|device]" >&2; exit 2 ;;
esac
echo "Artifacts: $task_artifacts"
