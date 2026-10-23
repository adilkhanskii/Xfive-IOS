"""Prepare an isolated main security PR without checking out old credentials.

Default is read-only. --create creates a NEW branch/PR, never updates main or
calls Apple. No credential blob is downloaded, decoded, printed or copied.
"""
import argparse
import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path

REPO = "tooyakov-art/x5"
BRANCH = "codex/x5-main-review-secret-cleanup-20260907"
ROOT = Path(__file__).resolve().parents[2]


def gh(*args, payload=None):
    result = subprocess.run(
        ["gh", *args], cwd=ROOT, text=True, encoding="utf-8",
        input=None if payload is None else json.dumps(payload),
        capture_output=True, check=False,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode:
        try:
            response = json.loads(result.stdout)
        except ValueError:
            response = {}
        raise RuntimeError(f"GitHub request failed: {response.get('message', result.stderr.strip())}; {response.get('errors', [])}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def api(path, payload=None):
    args = ["api", f"repos/{REPO}/{path}"]
    if payload is not None:
        args += ["--method", "POST", "--input", "-"]
    return gh(*args, payload=payload)


def public_source(path, ref):
    # Deliberately restrict reads to noncredential configuration files.
    assert path in {".gitignore", "fastlane/Deliverfile", ".github/workflows/asc-submit.yml"}
    item = api(f"contents/{path}?ref={ref}")
    assert item["encoding"] == "base64"
    return base64.b64decode(item["content"]).decode().replace("\r\n", "\n")


def replace_once(value, old, new):
    assert value.count(old) == 1, "Main configuration drifted; re-review before creating PR"
    return value.replace(old, new, 1)


def git(*args, data=None, env=None):
    result = subprocess.run(["git", *args], cwd=ROOT, input=data, text=True,
                            encoding="utf-8", capture_output=True, check=True,
                            env=env, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return result.stdout.strip()


def create_branch_from_index(base, removals, changes):
    # The Git-data write API is unavailable for this installation. Use the
    # existing authorized Git transport, without checking out credential blobs.
    # Main and the user's actual index/worktree are never changed.
    assert git("rev-parse", "--verify", base) == base
    with tempfile.TemporaryDirectory(prefix="x5-main-cleanup-index-") as temporary:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(Path(temporary) / "index")
        git("read-tree", base, env=env)
        git("update-index", "--force-remove", "--", *removals, env=env)
        for path, content in changes.items():
            blob = git("hash-object", "-w", "--stdin", data=content, env=env)
            git("update-index", "--add", "--cacheinfo", f"100644,{blob},{path}", env=env)
        tree = git("write-tree", env=env)
        sha = git("commit-tree", tree, "-p", base, "-m",
                  "security: remove tracked review login from main configuration [skip ci]", env=env)
    git("push", "origin", f"{sha}:refs/heads/{BRANCH}")
    return sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--create", action="store_true")
    args = parser.parse_args()
    base = api("git/ref/heads/main")["object"]["sha"]
    commit = api(f"git/commits/{base}")
    tree = api(f"git/trees/{commit['tree']['sha']}?recursive=1")
    assert not tree.get("truncated"), "Cannot verify complete main tree"
    indexed = {entry["path"]: entry for entry in tree["tree"]}
    removals = ["fastlane/metadata/review_information/demo_user.txt",
                "fastlane/metadata/review_information/demo_password.txt"]
    assert all(path in indexed and indexed[path]["type"] == "blob" for path in removals)
    assert "fastlane/review_credentials.rb" not in indexed, "Helper already present; re-review"

    ignore = public_source(".gitignore", base).rstrip() + "\n\n# Review login is supplied only by CI Secrets.\n"
    ignore += "\n".join(f"/{path}" for path in removals) + "\n"
    deliver = replace_once(
        public_source("fastlane/Deliverfile", base),
        'team_id "F8LA8PC4U6"\n',
        'team_id "F8LA8PC4U6"\n'
        'require File.expand_path("review_credentials", File.dirname(configfile_path))\n'
        '# Direct deliver also fails closed without both protected credentials.\n'
        'config.set(:app_review_information, required_review_credentials)\n',
    )
    workflow = replace_once(
        public_source(".github/workflows/asc-submit.yml", base),
        '      ASC_API_KEY_BASE64: ${{ secrets.ASC_API_KEY_BASE64 }}\n',
        '      ASC_API_KEY_BASE64: ${{ secrets.ASC_API_KEY_BASE64 }}\n'
        '      X5_APP_REVIEW_EMAIL: ${{ secrets.X5_APP_REVIEW_EMAIL }}\n'
        '      X5_APP_REVIEW_PASSWORD: ${{ secrets.X5_APP_REVIEW_PASSWORD }}\n',
    )
    workflow = replace_once(workflow, "gem install fastlane -N", "gem install fastlane -v 2.237.0 -N")
    workflow = replace_once(workflow, "fastlane ios ${{ inputs.action", "fastlane _2.237.0_ ios ${{ inputs.action")
    workflow = replace_once(
        workflow, "      - name: Run fastlane\n",
        '      - name: Verify synthetic parser contract without Apple\n'
        '        run: ruby -e "gem \'fastlane\', \'=2.237.0\'; load \'scripts/test_fastlane_review_secrets.rb\'"\n\n'
        '      - name: Require review credentials before Apple mutations\n'
        '        run: ruby -r ./fastlane/review_credentials.rb -e "required_review_credentials"\n\n'
        "      - name: Run fastlane\n",
    )
    changes = {
        ".gitignore": ignore,
        "fastlane/Deliverfile": deliver,
        "fastlane/review_credentials.rb": (ROOT / "fastlane/review_credentials.rb").read_text(encoding="utf-8"),
        ".github/workflows/asc-submit.yml": workflow,
        "scripts/test_fastlane_review_secrets.rb": (ROOT / "scripts/test_fastlane_review_secrets.rb").read_text(encoding="utf-8"),
    }
    print(json.dumps({"base": base, "branch": BRANCH, "deletes": removals,
                      "changes": list(changes), "create": args.create}))
    if not args.create:
        return
    assert api("git/ref/heads/main")["object"]["sha"] == base, "Main moved; stop"
    refs = api(f"git/matching-refs/heads/{BRANCH}")
    assert not refs, "Cleanup branch already exists; inspect it instead of retrying creation"
    new_sha = create_branch_from_index(base, removals, changes)
    assert api(f"git/ref/heads/{BRANCH}")["object"]["sha"] == new_sha
    pr = api("pulls", {
        "title": "Security: stop publishing App Review login in main",
        "head": BRANCH, "base": "main",
        "draft": True,
        "body": "Removes two tracked review-login files, ignores re-addition, and uses existing GitHub Secrets through an in-memory fail-closed Fastlane helper. Pins the manual metadata lane to the parser version already tested in run 34101572180. No credential blob was downloaded or copied to prepare this PR.\n\nThis is deliberately isolated from the payment release: no application code, build number, version, screenshots, or Apple state is changed. The old main workflow targets 1.1.1; do not use it to publish the current release. This PR has not been merged and does not rotate the compromised password or erase Git history. Rotation must be coordinated with the current App Review login.\n\nDo not include credentials in comments or CI artifacts. Main push currently triggers the old iOS upload; coordinate merge without dispatching that obsolete release.",
    })
    assert api("git/ref/heads/main")["object"]["sha"] == base, "Unexpected main movement"
    print(json.dumps({"pr": pr["html_url"], "commit": new_sha, "mainUnchanged": True}))


if __name__ == "__main__":
    main()
