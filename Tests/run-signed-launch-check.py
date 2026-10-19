#!/usr/bin/env python3
"""Check the production bridge against temporary signed, sandboxed fixture apps.

Requires an unlocked Mac session and an Early Innovations signing identity.
Creates no persistent grants, preferences, or MCP configuration.
"""

import argparse
import concurrent.futures
import json
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("--signing-identity", default="Apple Development")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    root = Path(tempfile.mkdtemp(prefix="i2m-launch-check-", dir="/tmp")).resolve()
    fixtures = []
    spec = importlib.util.spec_from_file_location("stdio_check", repo / "Tests/run-stdio-client-check.py")
    stdio = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stdio)

    def command(*argv):
        subprocess.run([str(x) for x in argv], check=True, stdout=subprocess.DEVNULL)

    def fixture(name, scenario="normal"):
        app = root / f"{name}.app"
        binaries = app / "Contents/MacOS"
        binaries.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.EarlyInnovations.Image2Movie",
            "CFBundleExecutable": "Image2Movie", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "LaunchProofScenario": scenario,
        }))
        shutil.copy2(root / "fixture", binaries / "Image2Movie")
        shutil.copy2(args.helper, binaries / "image2movie-mcp")
        command("codesign", "--force", "--sign", args.signing_identity,
                "--entitlements", repo / "Image2Movie.entitlements", "--options", "runtime", app)
        command("codesign", "--verify", "--strict", "--deep", app)
        fixtures.append(app)
        return binaries / "image2movie-mcp"

    def exchange(helper, succeeds=True):
        start = time.monotonic()
        result = subprocess.run([str(helper)], input=b'{"probe":true}\n', capture_output=True, timeout=11)
        elapsed = time.monotonic() - start
        if succeeds:
            check(result.returncode == 0, result.stderr.decode())
            report = json.loads(result.stdout)
            check(report["quiet"] and report["restorationDisabled"] and not report["active"],
                  f"Launch must be quiet and suppress restoration: {report}")
            check(elapsed < 8.5, f"Successful startup exceeded deadline: {elapsed:.2f}s")
            return report
        check(result.returncode == 1 and not result.stdout, f"Expected clean failure exit 1, got {result.returncode}")
        check(result.stderr, f"Failure needs a diagnostic (exit {result.returncode}, {elapsed:.2f}s)")
        check(elapsed < 9, f"Failure exceeded startup deadline: {elapsed:.2f}s")
        print(f"PASS {helper.parent.parent.parent.name}: {elapsed:.2f}s; {result.stderr.decode().strip()}")
        name = helper.parent.parent.parent.stem
        if name in ("disabled", "slow-start", "slow-handshake"):
            check(b"eight seconds" in result.stderr and b"Automation Settings" in result.stderr,
                  "Timeout lacks the actionable settings diagnostic")
        elif name == "wrong-version":
            check(b"version mismatch" in result.stderr, "Expected incompatible-version diagnostic")
        return elapsed

    def pids(app):
        executable = str(app / "Contents/MacOS/Image2Movie")
        rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines()
        return [int(row.split(None, 1)[0]) for row in rows
                if len(row.split(None, 1)) == 2 and Path(row.split(None, 1)[1]).resolve() == Path(executable).resolve()]

    try:
        command("swiftc", "-swift-version", "6", "-target", "arm64-apple-macosx27.0",
                "-module-cache-path", root / "cache", repo / "MCPPeerIdentity.swift",
                repo / "MCPUnixSocket.swift", repo / "MCPLaunchRequest.swift",
                repo / "Tests/BridgeLaunchProof.swift", "-o", root / "fixture", "-lbsm")
        first = fixture("First Image 2 Movie")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            reports = list(pool.map(exchange, [first] * 4))
        check(len({r["pid"] for r in reports}) == 1, "Concurrent launch created multiple app instances")
        check(exchange(first)["pid"] == reports[0]["pid"], "Warm connection replaced app")
        second = fixture("Second Image 2 Movie")
        check(exchange(second)["pid"] != reports[0]["pid"], "Bridge selected another installation")
        check(exchange(first)["pid"] == reports[0]["pid"], "Second app disturbed first app")
        held = stdio.Session(first)
        try:
            held.raw(b'{"probe":true}\n')
            check(held.read_message()["pid"] == reports[0]["pid"], "Held session selected wrong app")
            time.sleep(8.5)
            held.raw(b'{"probe":true}\n')
            check(held.read_message()["pid"] == reports[0]["pid"], "Watchdog killed successful session")
            os.kill(reports[0]["pid"], signal.SIGKILL)
            check(held.process.wait(timeout=3) == 0, "Old session did not exit on app loss")
            time.sleep(0.25)
            check(not pids(first.parent.parent.parent), "Old session relaunched the app")
        finally:
            held.close()
        check(exchange(first)["pid"] != reports[0]["pid"], "Fresh connection failed to relaunch after crash")
        print("PASS cold/warm launch, four concurrent clients, distinct app copies, and crash/relaunch")
        for scenario in ("disabled", "slow-start", "slow-handshake", "wrong-version"):
            elapsed = exchange(fixture(scenario, scenario), succeeds=False)
            if scenario in ("disabled", "slow-start"):
                check(elapsed >= 7.5, "Startup stopped before its eight-second deadline")
            if scenario == "wrong-version":
                check(elapsed < 4, "Protocol mismatch was retried")
        invalid = fixture("Invalid signature")
        (invalid.parent.parent / "Info.plist").write_bytes(b"tampered")
        exchange(invalid, succeeds=False)
        check(not pids(invalid.parent.parent.parent), "Invalid app was launched")
        print(f"Signed launch checks passed. Fixtures: {root}")
    finally:
        for app in fixtures:
            for pid in pids(app):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    main()
