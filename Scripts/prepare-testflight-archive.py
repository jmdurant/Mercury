#!/usr/bin/env python3
"""Repair TDLib's Watch framework metadata before App Store export.

Xcode links the packaged static library into an arm64 framework requiring
watchOS 26+, but copies TDLib's original watchOS 4 Info.plist. ASC rejects this
mismatch (90208). Match the metadata to the binary, then restore signatures.
Only the archive is changed; downloaded package artifacts remain untouched.
"""

import argparse
import hashlib
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


def version(value):
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def prepare(archive):
    metadata = plistlib.loads((archive / "Info.plist").read_bytes())
    properties = metadata["ApplicationProperties"]
    app = archive / "Products" / properties["ApplicationPath"]
    # A certificate name can match multiple renewed identities in the keychain.
    # Use the fingerprint of the certificate that actually signed this archive.
    with tempfile.TemporaryDirectory(prefix=".archive-cert-", dir=archive.parent) as temp:
        prefix = Path(temp) / "certificate"
        subprocess.run([
            "codesign", "--display", f"--extract-certificates={prefix}", str(app),
        ], check=True, capture_output=True)
        identity = hashlib.sha1(Path(str(prefix) + "0").read_bytes()).hexdigest()
    frameworks = list(app.glob("Watch/*.app/Frameworks/TDLibFramework.framework"))
    if not frameworks:
        raise RuntimeError("The archive has no embedded Watch TDLib framework")

    signing_bundles = set()
    for framework in frameworks:
        plist_path = framework / "Info.plist"
        original = plist_path.read_bytes()
        info = plistlib.loads(original)
        binary = framework / info["CFBundleExecutable"]
        load_commands = subprocess.check_output(
            ["xcrun", "vtool", "-show-build", str(binary)], text=True
        )
        minimums = re.findall(r"^\s*minos\s+([0-9.]+)\s*$", load_commands, re.MULTILINE)
        if not minimums:
            raise RuntimeError(f"Cannot determine the minimum OS for {binary}")
        required = max(minimums, key=version)
        watch_app = framework.parent.parent
        watch_info = plistlib.loads((watch_app / "Info.plist").read_bytes())
        if version(required) > version(watch_info["MinimumOSVersion"]):
            raise RuntimeError(f"TDLib requires watchOS {required}, above the app deployment target")
        # Always restore these signatures, including after an interrupted run.
        signing_bundles.update((framework, watch_app, app))
        if version(info["MinimumOSVersion"]) >= version(required):
            print(f"TDLib minimum OS already valid: {info['MinimumOSVersion']}")
            continue

        print(f"TDLib MinimumOSVersion: {info['MinimumOSVersion']} -> {required}")
        info["MinimumOSVersion"] = required
        fmt = plistlib.FMT_BINARY if original.startswith(b"bplist") else plistlib.FMT_XML
        plist_path.write_bytes(plistlib.dumps(info, fmt=fmt, sort_keys=False))

    # Sign from the inside out; exportArchive will apply distribution signing.
    for bundle in sorted(signing_bundles, key=lambda path: len(path.parts), reverse=True):
        subprocess.run([
            "codesign", "--force", "--sign", identity,
            "--preserve-metadata=identifier,entitlements,flags,runtime",
            "--generate-entitlement-der", str(bundle),
        ], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Path to the .xcarchive to prepare")
    prepare(parser.parse_args().archive.resolve())
