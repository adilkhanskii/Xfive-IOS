"""Check exported IPA metadata and exclusion of acceptance-only resources.

This is not a full binary secret scanner or a signature verifier.
Only names and non-secret Info.plist metadata are reported.
"""
import argparse
from pathlib import PurePosixPath
import plistlib
from zipfile import ZipFile


def verify(path, version, build):
    with ZipFile(path) as archive:
        names = archive.namelist()
        roots = [name for name in names if len(PurePosixPath(name).parts) == 3
                 and name.startswith("Payload/") and name.endswith(".app/Info.plist")]
        if len(roots) != 1:
            raise ValueError("Expected one main application Info.plist")
        info = plistlib.loads(archive.read(roots[0]))
        expected = {
            "CFBundleIdentifier": "com.x5studio.app",
            "CFBundleDisplayName": "Xfive marketing",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        }
        for key, value in expected.items():
            if str(info.get(key, "")) != value:
                raise ValueError(f"IPA metadata mismatch: {key}")
        for name in names:
            lower = name.lower()
            if (PurePosixPath(lower).name in {"demo_user.txt", "demo_password.txt"}
                    or ".xctest/" in lower or lower.endswith(".xctest")
                    or "x5acceptanceuitests" in lower):
                raise ValueError("Test-only bundle or review-login resource found in IPA")
        return {"bundle": expected["CFBundleIdentifier"], "version": version,
                "build": build, "test_resources": 0}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    print(verify(args.ipa, args.version, args.build))
