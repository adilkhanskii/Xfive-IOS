"""Fail-closed review secret checks; ephemeral simulator resources only.

No network, secret values in arguments, stdout or fallback to Git history.
Normal application/release builds do not require these test-only resources.
"""
import argparse
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = {"demo_user.txt": "X5_APP_REVIEW_EMAIL", "demo_password.txt": "X5_APP_REVIEW_PASSWORD"}


def credentials(environ=None):
    environ = os.environ if environ is None else environ
    result = {}
    for filename, name in NAMES.items():
        value = environ.get(name, "").strip()
        if not value or "\n" in value or "\r" in value:
            raise ValueError(f"Missing or invalid {name}; obtain it from protected secret storage")
        result[filename] = value
    return result


def paths(root):
    directory = root / ".secrets" / "review-test"
    targets = [directory / name for name in NAMES]
    if any(p.is_symlink() for p in [root / ".secrets", directory, *targets]):
        raise ValueError("Refusing symlink in test-only secret path")
    return directory, targets


def hydrate(root=ROOT, environ=None):
    values = credentials(environ)  # Validate both before any file write.
    if os.environ.get("GITHUB_ACTIONS") == "true":
        # Also register trimmed values: imported secrets may contain a final LF.
        # GitHub consumes this command, it must not be used in local output.
        for value in values.values():
            escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::add-mask::{escaped}", flush=True)
    directory, targets = paths(root)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    created = []
    try:
        for target in targets:
            with target.open("x", encoding="utf-8") as output:
                created.append(target)
                target.chmod(0o600)
                output.write(values[target.name])
    except Exception:
        for target in created:
            target.unlink(missing_ok=True)
        raise


def cleanup(root=ROOT):
    directory, targets = paths(root)
    for target in targets:
        target.unlink(missing_ok=True)
    if directory.exists() and not any(directory.iterdir()):
        directory.rmdir()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--hydrate", action="store_true")
    group.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    try:
        if args.cleanup:
            cleanup()
        elif args.hydrate:
            hydrate()
        else:
            credentials()
    except (ValueError, OSError) as error:
        # Do not print an OSError containing any credential-related data.
        parser.exit(1, "Review credentials unavailable or ephemeral resource operation refused.\n")
