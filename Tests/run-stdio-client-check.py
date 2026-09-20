#!/usr/bin/env python3
"""Exercise a running Image2Movie app through its bundled MCP stdio helper.

The app must already be open with “Allow AI tools to use Image2Movie” enabled.
This script does not change app settings, grants, or Codex configuration.
"""

import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import struct
import subprocess
import sys
import time
import uuid
import zlib


TOOLS = {
    "get_capabilities", "list_authorized_folders", "inspect_sequence",
    "export_movie", "get_export_status", "cancel_export",
}
PROTOCOL = "2025-06-18"  # Version requested by the current Codex desktop client.


class CheckFailure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise CheckFailure(message)


class Session:
    def __init__(self, helper):
        self.process = subprocess.Popen(
            [str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ, "stdout")
        self.selector.register(self.process.stderr, selectors.EVENT_READ, "stderr")
        self.output = bytearray()
        self.diagnostics = bytearray()
        self.next_id = 1

    def send(self, value):
        data = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
        try:
            self.write_bytes(data)
        except (BrokenPipeError, OSError) as error:
            raise CheckFailure("bridge closed its input: " + self.error_text()) from error

    def raw(self, data):
        try:
            self.write_bytes(data)
        except (BrokenPipeError, OSError):
            pass

    def write_bytes(self, data):
        view = memoryview(data)
        while view:
            written = os.write(self.process.stdin.fileno(), view)
            if written <= 0:
                raise BrokenPipeError("bridge input closed")
            view = view[written:]

    def error_text(self):
        return self.diagnostics.decode("utf-8", "replace")[-1000:].strip()

    def read_message(self, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            newline = self.output.find(b"\n")
            if newline >= 0:
                line = bytes(self.output[:newline])
                del self.output[:newline + 1]
                try:
                    return json.loads(line)
                except json.JSONDecodeError as error:
                    raise CheckFailure("non-JSON stdout from bridge") from error
            for key, _ in self.selector.select(max(0, min(0.25, deadline - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    self.selector.unregister(key.fileobj)
                    continue
                if key.data == "stdout":
                    self.output.extend(chunk)
                    check(len(self.output) <= 262_145, "bridge stdout exceeded the line limit")
                else:
                    self.diagnostics.extend(chunk)
                    if len(self.diagnostics) > 4096:
                        del self.diagnostics[:-4096]
            if self.process.poll() is not None and not self.selector.get_map():
                break
        raise CheckFailure("no MCP response from bridge: " + self.error_text())

    def request(self, method, params=None, timeout=10):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method,
                   "params": params if params is not None else {}})
        deadline = time.monotonic() + timeout
        while True:
            reply = self.read_message(max(0, deadline - time.monotonic()))
            if reply.get("id") == request_id:
                check("error" not in reply, f"{method} returned JSON-RPC error: {reply.get('error')}")
                return reply.get("result", {})

    def initialize(self):
        result = self.request("initialize", {
            "protocolVersion": PROTOCOL,
            # Current Codex advertises this object-valued extension. Keep it in
            # the signed-app check: empty capabilities missed SDK issue #287.
            "capabilities": {
                "elicitation": {"form": {}, "url": {}},
                "experimental": {"codex/auth-change": {}},
                "extensions": {"openai/form": {}},
            },
            "clientInfo": {"name": "Image2MovieStdioCheck", "version": "1.0"},
        }, timeout=15)
        check("serverInfo" in result, "initialize returned no serverInfo")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(0.1)  # Exercise an idle socket before the first tool request.
        return result

    def tool(self, name, arguments=None, timeout=15):
        result = self.request("tools/call", {
            "name": name, "arguments": arguments or {},
        }, timeout=timeout)
        check(not result.get("isError"), f"{name} returned tool error: {result.get('structuredContent')}")
        return result.get("structuredContent", {})

    def close(self):
        was_running = self.process.poll() is None
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        graceful = True
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            graceful = False
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()
        self.process.stdout.close()
        self.process.stderr.close()
        return was_running and graceful and self.process.returncode == 0


def png(path):
    width, height = 64, 64
    pixels = b"".join(b"\x00" + bytes((40, 120, 210)) * width for _ in range(height))

    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))

    path.write_bytes(b"\x89PNG\r\n\x1a\n" +
                     chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def optional_export(session, args, folders, sessions):
    fields = (args.input_id, args.input_root, args.output_id, args.output_root)
    if not any(fields):
        return session
    check(all(fields), "export check needs both folder IDs and both local root paths")
    input_id = str(uuid.UUID(args.input_id)).upper()
    output_id = str(uuid.UUID(args.output_id)).upper()
    known = {item["id"].upper(): item for item in folders.get("folders", [])}
    check(input_id in known, "input folder ID is not authorized in the running app")
    check(output_id in known and known[output_id]["writable"],
          "output folder ID is not writable in the running app")
    check(args.input_root.is_dir() and args.output_root.is_dir(),
          "both local folder roots must already exist")
    check(os.access(args.input_root, os.W_OK) and os.access(args.output_root, os.W_OK),
          "both local folder roots must be writable for the fixture")

    name = ".image2movie-stdio-check-" + uuid.uuid4().hex
    fixture_dir = args.input_root / name
    short_output = args.output_root / (name + "-short.mp4")
    survival_output = args.output_root / (name + "-survival.mp4")
    cancel_output = args.output_root / (name + "-cancel.mp4")
    fixture_dir.mkdir()
    jobs = {}
    passed = False

    def start_export(reference, frames, output, width, height, overwrite=False):
        export = session.tool("export_movie", {
            "inputs": [reference] * frames,
            "output": {"folder_id": output_id, "relative_path": output.name},
            "width": width, "height": height, "frame_rate": 30,
            "codec": "h264", "quality": "standard", "overwrite": overwrite,
        }, timeout=20)
        job_id = export.get("job_id")
        check(job_id, "export_movie returned no job ID")
        check(export.get("state") == "running", "export_movie was not accepted as running")
        jobs[job_id] = None
        return job_id

    def terminal_status(job_id, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = session.tool("get_export_status", {"job_id": job_id})
            if status.get("state") in ("cancelled", "completed", "failed"):
                jobs[job_id] = status["state"]
                return status
            time.sleep(0.2)
        raise CheckFailure("export did not reach a terminal state")

    def reconnect(abrupt=False):
        nonlocal session
        old = session
        check(old.process.poll() is None, "bridge exited before disconnect test")
        if abrupt:
            old.process.terminate()
            try:
                exit_code = old.process.wait(timeout=3)
            except subprocess.TimeoutExpired as error:
                raise CheckFailure("bridge did not terminate promptly") from error
            old.close()
            check(exit_code == -signal.SIGTERM,
                  f"terminated bridge exited with unexpected status {exit_code}")
        else:
            check(old.close(), "bridge did not exit cleanly on stdin EOF")
        sessions.remove(old)
        session = None
        replacement = Session(args.helper)
        sessions.append(replacement)
        session = replacement
        replacement.initialize()

    try:
        png(fixture_dir / "frame.png")
        reference = {"folder_id": input_id, "relative_path": name + "/frame.png"}
        inspected = session.tool("inspect_sequence", {
            "folder_id": input_id, "relative_path": name,
        })
        check(inspected.get("accepted") == [reference],
              "inspect_sequence did not find the generated PNG")

        short_id = start_export(reference, 3, short_output, 64, 64)
        short_status = terminal_status(short_id, 30)
        check(short_status["state"] == "completed", "tiny export did not complete")
        check(short_output.is_file() and short_output.stat().st_size > 0,
              "completed export has no nonempty output file")
        print("generated fixture inspection and completed export: passed")

        survival_id = start_export(reference, 900, survival_output, 960, 540)
        reconnect()  # EOF closes only this bridge, not the accepted export.
        survival_running = session.tool("get_export_status", {"job_id": survival_id})
        check(survival_running.get("state") == "running",
              "accepted export finished before its bridge disconnect was verified")
        survival_status = terminal_status(survival_id, 60)
        check(survival_status["state"] == "completed",
              "accepted export did not survive bridge EOF")
        check(survival_output.is_file() and survival_output.stat().st_size > 0,
              "surviving export has no nonempty output file")
        print("accepted export survived bridge EOF and reconnect: passed")

        sentinel = b"Image2Movie overwrite preservation fixture\n"
        cancel_output.write_bytes(sentinel)
        cancel_id = start_export(reference, 1000, cancel_output, 1920, 1080,
                                 overwrite=True)
        reconnect(abrupt=True)  # A terminated helper must not cancel the job.
        cancellation = session.tool("cancel_export", {"job_id": cancel_id})
        check(cancellation.get("cancelled") is True, "cancel_export did not acknowledge cancellation")
        cancel_status = terminal_status(cancel_id, 20)
        check(cancel_status["state"] == "cancelled",
              "long export finished before cancellation: " + str(cancel_status["state"]))
        check(cancel_output.read_bytes() == sentinel,
              "cancelled overwrite changed the existing destination")
        print("terminated bridge, cancellation, and overwrite preservation: passed")
        passed = True
    finally:
        for job_id, state in list(jobs.items()):
            if state is not None:
                continue
            if session is None or session.process.poll() is not None:
                continue
            try:
                session.tool("cancel_export", {"job_id": job_id})
                terminal_status(job_id, 5)
            except (CheckFailure, ValueError, OSError):
                pass
        if passed and all(state is not None for state in jobs.values()):
            shutil.rmtree(fixture_dir)
            for output in (short_output, survival_output, cancel_output):
                if output.exists():
                    output.unlink()
        else:
            print("Fixture retained after incomplete export check: " + str(fixture_dir),
                  file=sys.stderr)
    return session


def expect_rejected(helper, raw):
    session = Session(helper)
    try:
        session.raw(raw)
        deadline = time.monotonic() + 5
        while session.process.poll() is None and time.monotonic() < deadline:
            for key, _ in session.selector.select(0.1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    session.selector.unregister(key.fileobj)
                elif key.data == "stdout":
                    session.output.extend(chunk)
                else:
                    session.diagnostics.extend(chunk)
        check(session.process.poll() is not None,
              "malformed or oversized input left bridge running")
        session.output.extend(session.process.stdout.read() or b"")
        check(not session.output, "malformed input produced stdout MCP bytes")
    finally:
        session.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path, help="signed Image2Movie.app/Contents/MacOS/image2movie-mcp")
    parser.add_argument("--input-id")
    parser.add_argument("--input-root", type=Path)
    parser.add_argument("--output-id")
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()
    check(args.helper.is_file(), "helper executable does not exist")
    sessions = []
    try:
        first = Session(args.helper)
        sessions.append(first)
        first.initialize()
        names = {item["name"] for item in first.request("tools/list").get("tools", [])}
        check(names == TOOLS, f"unexpected tool names: {sorted(names)}")
        capabilities = first.tool("get_capabilities")
        check("defaults" in capabilities and "limits" in capabilities,
              "get_capabilities returned incomplete data")
        folders = first.tool("list_authorized_folders")
        second = Session(args.helper)
        sessions.append(second)
        second.initialize()
        check(len(second.request("tools/list").get("tools", [])) == 6,
              "overlapping session lost tools")
        check(first.close(), "first session needed forced termination")
        sessions.remove(first)
        second.tool("get_capabilities")
        check(second.close(), "second session needed forced termination")
        sessions.remove(second)
        print("initialize, six tools, capabilities, overlapping sessions: passed")

        reconnect = Session(args.helper)
        sessions.append(reconnect)
        reconnect.initialize()
        reconnect.tool("get_capabilities")
        reconnect = optional_export(reconnect, args, folders, sessions)
        check(reconnect.close(), "reconnected session needed forced termination")
        sessions.remove(reconnect)
        print("reconnect: passed")

        expect_rejected(args.helper, b"{broken json\n")
        expect_rejected(args.helper, b" " * (1_048_576 + 1) + b"\n")
        print("malformed and oversized frames: rejected")

        for _ in range(16):
            session = Session(args.helper)
            sessions.append(session)
            session.initialize()
        overflow = Session(args.helper)
        try:
            try:
                overflow.initialize()
            except CheckFailure:
                pass
            else:
                raise CheckFailure("17th simultaneous MCP session was accepted")
        finally:
            overflow.close()
        freed = sessions.pop(0)
        check(freed.close(), "freed session needed forced termination")
        deadline = time.monotonic() + 5
        while True:
            retry = Session(args.helper)
            try:
                retry.initialize()
                sessions.append(retry)
                break
            except CheckFailure:
                retry.close()
                if time.monotonic() >= deadline:
                    raise CheckFailure("connection slot did not reopen after disconnect")
                time.sleep(0.1)
        print("16-session limit and slot cleanup: passed")
    finally:
        for session in sessions:
            session.close()


if __name__ == "__main__":
    try:
        main()
    except (CheckFailure, ValueError, OSError) as error:
        print("stdio MCP check failed: " + str(error), file=sys.stderr)
        sys.exit(1)
