#!/usr/bin/env python3
"""Verify packaged identity, localized names, architecture, and signature category."""

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import struct
import zipfile


BUNDLES = (
    ("Payload/NoteAssistant.app", "com.local.noteassistant", "NoteAssistant", "笔记问答"),
    ("Payload/NoteAssistant.app/PlugIns/AskAI.appex", "com.local.noteassistant.AskAI", "AskAI", "问 AI"),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_strings(data):
    try:
        value = plistlib.loads(data)
        require(isinstance(value, dict), "InfoPlist.strings must contain a dictionary.")
        return value
    except plistlib.InvalidFileException:
        pass
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    text = re.sub(r"/\*.*?\*/", "", data.decode(encoding), flags=re.S)
    pattern = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;')
    values = {}
    position = 0
    for match in pattern.finditer(text):
        require(not text[position:match.start()].strip(), "Unexpected InfoPlist.strings syntax.")
        key, value = map(json.loads, match.groups())
        require(key not in values, "Duplicate localized name key: " + key)
        values[key] = value
        position = match.end()
    require(not text[position:].strip(), "Unexpected trailing InfoPlist.strings syntax.")
    return values


def inspect_executable(data):
    require(len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe", "Expected a thin little-endian Mach-O 64 executable.")
    cpu_type = struct.unpack_from("<I", data, 4)[0]
    require(cpu_type == 0x0100000C, "Expected arm64 architecture.")
    command_count, command_bytes = struct.unpack_from("<II", data, 16)
    require(command_bytes <= len(data) - 32, "Truncated Mach-O load commands.")
    offset = 32
    signature_present = False
    for _ in range(command_count):
        require(offset + 8 <= 32 + command_bytes, "Truncated Mach-O load command.")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= 32 + command_bytes, "Invalid Mach-O load command size.")
        signature_present |= command == 0x1D
        offset += size
    require(offset == 32 + command_bytes, "Mach-O load command size mismatch.")
    return {"architecture": "arm64", "codeSignatureLoadCommand": signature_present}


def version_from_spec(path):
    text = path.read_text(encoding="utf-8")
    values = []
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        matches = re.findall(r'^\s*' + key + r':\s*"([0-9.]+)"\s*$', text, flags=re.M)
        require(len(matches) == 1, "Expected one quoted numeric " + key + " in project.yml.")
        values.append(matches[0])
    return values


def verify_package(path, expected_version, expected_build, signature_expected):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "IPA contains duplicate ZIP paths.")
        require(archive.testzip() is None, "IPA failed CRC validation.")
        require(not any(name.endswith("embedded.mobileprovision") for name in names), "Build artifact unexpectedly contains an Apple provisioning profile.")
        if not signature_expected:
            require(not any("/_CodeSignature/" in name for name in names), "Unsigned IPA unexpectedly contains a signature directory.")
        bundles = []
        for prefix, identifier, ascii_name, chinese_name in BUNDLES:
            info = plistlib.loads(archive.read(prefix + "/Info.plist"))
            require(info.get("CFBundleIdentifier") == identifier, "Bundle identifier changed: " + prefix)
            require(info.get("CFBundleDisplayName") == ascii_name, "Registration name must be ASCII: " + prefix)
            require(info.get("CFBundleName") == ascii_name, "Base bundle name changed: " + prefix)
            require(info.get("CFBundleDevelopmentRegion") == "zh-Hans", "Missing Chinese fallback region: " + prefix)
            require(info.get("CFBundleShortVersionString") == expected_version, "Unexpected version: " + prefix)
            require(info.get("CFBundleVersion") == expected_build, "Unexpected build number: " + prefix)
            localized_path = prefix + "/zh-Hans.lproj/InfoPlist.strings"
            localized = read_strings(archive.read(localized_path))
            for key in ("CFBundleDisplayName", "CFBundleName"):
                require(localized.get(key) == chinese_name, "Missing Chinese localized " + key + ": " + prefix)
            executable = info.get("CFBundleExecutable")
            require(executable == ascii_name, "Unexpected executable name: " + prefix)
            architecture = inspect_executable(archive.read(prefix + "/" + executable))
            require(architecture["codeSignatureLoadCommand"] == signature_expected, "Unexpected signature category: " + prefix)
            bundles.append({
                "identifier": identifier,
                "registrationName": ascii_name,
                "localizedDisplayName": chinese_name,
                "localizedResource": localized_path,
                "developmentRegion": info["CFBundleDevelopmentRegion"],
                "version": info["CFBundleShortVersionString"],
                "build": info["CFBundleVersion"],
                **architecture,
            })
    return {
        "filename": path.name,
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "crcValid": True,
        "signatureCategory": "ad-hoc re-signing input" if signature_expected else "unsigned",
        "bundles": bundles,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unsigned", required=True, type=pathlib.Path)
    parser.add_argument("--resign-input", required=True, type=pathlib.Path)
    parser.add_argument("--project-spec", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    version, build = version_from_spec(args.project_spec)
    report = {
        "scope": "Packaged artifacts only; Apple signing and real-device launch require separate verification.",
        "expectedVersion": version,
        "expectedBuild": build,
        "artifacts": [
            verify_package(args.unsigned, version, build, False),
            verify_package(args.resign_input, version, build, True),
        ],
    }
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Verified both arm64 packages, unchanged bundle identifiers, ASCII registration names, and packaged Chinese names.")


if __name__ == "__main__":
    main()
