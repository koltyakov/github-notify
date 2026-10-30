#!/usr/bin/env python3
"""Check signing selection without running the app or accessing its GitHub token."""

import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SIGN = ROOT / "scripts/sign-app.sh"
IDENTIFIER = "com.koltyakov.github-notify.signing-test"


def bundle(directory, revision):
    app = directory / f"Revision-{revision}.app"
    executable = app / "Contents/MacOS/test"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": IDENTIFIER,
        "CFBundleExecutable": "test",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(revision),
    }))
    subprocess.run(
        ["xcrun", "clang", "-x", "c", "-o", str(executable), "-"],
        input=f"int main(void) {{ return {revision}; }}\n", text=True, check=True,
    )
    return app


def details(app):
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(app)],
        text=True, capture_output=True, check=True,
    )
    output = result.stdout + result.stderr
    requirement = re.search(r"^(?:#\s*)?designated => (.+)$", output, re.MULTILINE)
    digest = re.search(r"^CDHash=(.+)$", output, re.MULTILINE)
    assert requirement and digest, output
    return requirement.group(1), digest.group(1)


def main():
    env = dict(os.environ)
    env.pop("CODESIGN_IDENTITY", None)
    env.pop("CODESIGN_KEYCHAIN", None)
    signing = Path(env.get("GITHUB_NOTIFY_SIGNING_DIR") or str(
        Path.home() / "Library/Application Support/github-notify/signing"
    ))
    with tempfile.TemporaryDirectory(prefix="github-notify-signing-test-") as temporary:
        directory = Path(temporary)
        first, second = bundle(directory, 1), bundle(directory, 2)
        fallback = {**env, "GITHUB_NOTIFY_SIGNING_DIR": str(directory / "not-configured")}
        subprocess.run(["/bin/bash", str(SIGN), str(first)], env=fallback, check=True)
        assert "cdhash" in details(first)[0]
        print("PASS: unconfigured/CI builds retain ad-hoc signing.", flush=True)

        incomplete = directory / "incomplete"
        incomplete.mkdir()
        configured = {**env, "GITHUB_NOTIFY_SIGNING_DIR": str(incomplete)}
        result = subprocess.run(["/bin/bash", str(SIGN), str(first)], env=configured, text=True, capture_output=True)
        assert result.returncode != 0 and "Refusing to fall back" in result.stderr
        print("PASS: incomplete setup cannot silently change signing identity.", flush=True)
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "scripts/setup-signing.sh")],
            env=configured, text=True, capture_output=True,
        )
        assert result.returncode != 0 and not list(incomplete.iterdir())
        print("PASS: setup does not repurpose an existing directory or create signing items there.", flush=True)
        subprocess.run(["/bin/bash", str(SIGN), str(first)], env={**configured, "CODESIGN_IDENTITY": "-"}, check=True)
        assert "cdhash" in details(first)[0]
        print("PASS: explicit ad-hoc override takes precedence.", flush=True)

        if (signing / "identity.sha1").is_file():
            fingerprint = (signing / "identity.sha1").read_text().strip().lower()
            for app in (first, second):
                subprocess.run(["/bin/bash", str(SIGN), str(app)], env=env, check=True)
            before, after = details(first), details(second)
            assert before[1] != after[1], "Fixtures must have different code hashes"
            assert before[0] == after[0], "Signing requirement changed across builds"
            assert "cdhash" not in before[0] and fingerprint in before[0].lower()
            print("PASS: different builds retain the same certificate-bound signing requirement.", flush=True)
        else:
            print("SKIP: stable-identity check needs make setup-signing.", flush=True)


if __name__ == "__main__":
    main()
