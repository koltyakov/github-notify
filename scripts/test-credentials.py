#!/usr/bin/env python3
"""Exercise actual login-Keychain access using only disposable, isolated items."""

import os
import hashlib
import platform
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
PARENT_ID = "com.koltyakov.github-notify"


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, **kwargs)


def code_hash(path):
    result = run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)], capture_output=True)
    return re.search(r"^CDHash=(.+)$", result.stdout + result.stderr, re.MULTILINE).group(1)


def main():
    env = dict(os.environ)
    env.pop("CODESIGN_IDENTITY", None)
    env.pop("CODESIGN_KEYCHAIN", None)
    signing = Path(env.get("GITHUB_NOTIFY_SIGNING_DIR") or str(
        Path.home() / "Library/Application Support/github-notify/signing"
    ))
    if not (signing / "identity.sha1").is_file():
        raise SystemExit("Run make setup-signing before the isolated credential test.")

    service = "com.koltyakov.github-notify.isolated-credentials-" + str(uuid.uuid4())
    legacy = service + ".legacy"
    with tempfile.TemporaryDirectory(prefix="github-notify-credential-test-") as temporary:
        folder = Path(temporary)
        # Cold compiles must also be repeatable; never execute these production-
        # service binaries, only compare their bytes. Keychain tests below use a
        # separate compile-time fixture service.
        cold = []
        for name in ("cold-a", "cold-b"):
            output = folder / name / "github-notify-credentials"
            run(["/bin/bash", str(ROOT / "scripts/build-credential-helper.sh"), platform.machine(), str(output)],
                env={**env, "GITHUB_NOTIFY_CREDENTIAL_CACHE_ROOT": str(folder / (name + "-cache"))})
            cold.append(hashlib.sha256(output.read_bytes()).digest())
        assert cold[0] == cold[1], "Credential helper changes between identical cold builds"
        print("PASS: identical cold builds produce identical credential-helper binaries.", flush=True)
        parent_source = folder / "parent.swift"
        parent_source.write_text(r'''
import Foundation
import Darwin

@main
struct Parent {
    static func main() {
        let store = TokenStore(legacyService: "LEGACY_SERVICE")
        do {
            switch CommandLine.arguments[1] {
            case "save": try store.save("isolated-fixture-not-a-real-token"); print("saved")
            case "load":
                guard try store.load() == "isolated-fixture-not-a-real-token" else { exit(20) }
                print("loaded")
            case "empty":
                guard try store.load().isEmpty else { exit(25) }
                print("empty")
            case "delete": try store.save(""); print("deleted")
            case "reject-helper":
                do { _ = try store.load(); exit(21) }
                catch { print("rejected-helper") }
            case "raw":
                let process = Process()
                let input = Pipe(), output = Pipe()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/github-notify-credentials")
                process.standardInput = input
                process.standardOutput = output
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { exit(24) }
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(#"{"operation":"load"}"#.utf8))
                try input.fileHandleForWriting.close()
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (reply?["status"] as? Int) == -25293, reply?["token"] == nil else { exit(22) }
                print("rejected-parent")
            default: exit(23)
            }
        } catch {
            // Error descriptions never include credential data.
            fputs("Isolated credential test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
'''.replace("LEGACY_SERVICE", legacy))
        parent = folder / "parent"
        run(["swiftc", "-parse-as-library", str(ROOT / "Sources/GitHubNotify/Keychain.swift"), str(parent_source), "-o", str(parent)])
        helper = folder / "helper"
        helper_command = [
            "xcrun", "clang", "-mmacosx-version-min=13.0", "-Os", "-fobjc-arc", "-Wno-deprecated-declarations",
            "-Wl,-no_adhoc_codesign,-no_uuid",
            '-DGITHUB_NOTIFY_CREDENTIAL_SERVICE="' + service + '"',
            "-framework", "Foundation", "-framework", "Security",
            str(ROOT / "Sources/GitHubNotifyCredentials/main.m"), "-o", str(helper),
        ]
        run(helper_command)
        changed_helper = folder / "changed-helper"
        changed_command = ["-O0" if argument == "-Os" else argument for argument in helper_command]
        changed_command[-1] = str(changed_helper)
        run(changed_command)

        apps = []
        for revision in range(1, 7):
            app = folder / f"Parent-{revision}.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Helpers").mkdir()
            shutil.copy2(parent, app / "Contents/MacOS/parent")
            shutil.copy2(changed_helper if revision == 6 else helper, app / "Contents/Helpers/github-notify-credentials")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": PARENT_ID if revision != 3 else "com.example.untrusted",
                "CFBundleExecutable": "parent", "CFBundlePackageType": "APPL", "CFBundleVersion": str(revision),
            }))
            run(["/bin/bash", str(ROOT / "scripts/sign-app.sh"), str(app)], env=env)
            if revision == 5:
                run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
            apps.append(app)

        first = apps[0] / "Contents/MacOS/parent"
        second = apps[1] / "Contents/MacOS/parent"
        changed = apps[5] / "Contents/MacOS/parent"
        try:
            assert code_hash(apps[0]) != code_hash(apps[1])
            assert code_hash(apps[0] / "Contents/Helpers/github-notify-credentials") == code_hash(apps[1] / "Contents/Helpers/github-notify-credentials")
            assert run([str(first), "save"], capture_output=True).stdout.strip() == "saved"
            assert run([str(first), "load"], capture_output=True).stdout.strip() == "loaded"
            assert run([str(second), "load"], capture_output=True).stdout.strip() == "loaded"
            print("PASS: different parent app code hashes read the same isolated login-Keychain item without prompts.", flush=True)

            assert run([str(apps[2] / "Contents/MacOS/parent"), "raw"], capture_output=True).stdout.strip() == "rejected-parent"
            direct = subprocess.run([str(apps[0] / "Contents/Helpers/github-notify-credentials")], input='{"operation":"load"}', text=True, capture_output=True)
            assert direct.returncode != 0 and '"token"' not in direct.stdout
            assert run([str(apps[4] / "Contents/MacOS/parent"), "raw"], capture_output=True).stdout.strip() == "rejected-parent"
            print("PASS: another app identifier, an ad-hoc parent, and direct invocation cannot retrieve credentials.", flush=True)

            replaced = apps[3] / "Contents/Helpers/github-notify-credentials"
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.koltyakov.github-notify.credentials", str(replaced)])
            assert run([str(apps[3] / "Contents/MacOS/parent"), "reject-helper"], capture_output=True).stdout.strip() == "rejected-helper"
            print("PASS: the app rejects a helper signed by an untrusted identity before sending credentials.", flush=True)

            assert code_hash(apps[0] / "Contents/Helpers/github-notify-credentials") != code_hash(apps[5] / "Contents/Helpers/github-notify-credentials")
            assert run([str(changed), "empty"], capture_output=True).stdout.strip() == "empty"
            assert run([str(changed), "save"], capture_output=True).stdout.strip() == "saved"
            assert run([str(changed), "load"], capture_output=True).stdout.strip() == "loaded"
            assert run([str(first), "load"], capture_output=True).stdout.strip() == "loaded"
            print("PASS: a changed helper uses a fresh item without prompting or changing the old item.", flush=True)
        finally:
            run([str(first), "delete"], capture_output=True)
            run([str(changed), "delete"], capture_output=True)
            print("Isolated credential removed. The real GitHub-token items were never queried.", flush=True)


if __name__ == "__main__":
    main()
