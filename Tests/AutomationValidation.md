# Automation validation

Tested on September 19–20, 2026 with macOS 27, Xcode 27, and Apple silicon.
The application uses Early Innovations, LLC's Apple Development identity,
team `BWNJC57N56`. This is development signing, not an App Store submission.

## Automated checks

- Debug and Release arm64 builds; static analysis; strict code-signature
  verification. App Intents metadata and third-party notices are bundled.
  Release includes the sandbox entitlements and hardened runtime, with debugger
  access disabled.
- Existing export and UI harness, including all three codecs, UHD, vector and
  high-precision input, color metadata, decoded precision, frame order/duration,
  cancellation, retry, imports, Undo/Redo, and preferences.
- Destination preservation on invalid settings, corrupt frames, write errors,
  cancellation, and refused overwrite. A deterministic finalization test creates
  a destination after preflight and verifies its bytes survive for each codec.
- Swift coordinator tests for stable automation defaults, duplicate inputs,
  busy behavior, failure/cancellation results, concurrent waiters, the latest-20
  history limit, and preserved interactive state.
- File-access tests for canonical paths, traversal and symlink rejection, and
  grant roles. An unsigned harness cannot prove security-scoped bookmark behavior.
- Official SDK client/server tests over Unix socket pairs: six-tool discovery,
  isolated sessions with overlapping request IDs, strict argument validation,
  notification bursts, 1 MiB inbound boundary, oversized input/output, invalid
  batches and fractional IDs, stopped-socket rejection, and awaited cleanup.
- Isolated defaults and TOML checks: the new opt-in defaults off, HTTP enablement
  does not carry forward, explicit enablement persists, and paths are escaped.
- An independent GPT-6 Astra review found and verified fixes for descriptor reuse,
  unbounded admission before actor dispatch, notification buffering, request-ID
  matching, shutdown during registration, and inherited nonblocking socket flags.
  No further actionable production issue remained in the final source review.

Run `bash Tests/run-regressions.sh`. Set `KEEP_TEST_OUTPUT=1` to retain generated
fixtures and `REGRESSION_BUILD_DIR` to reuse an Xcode package/build cache.

## Signed bridge checks (September 20)

- Debug and Release app/helper builds pass, along with static analysis and strict
  nested signature verification. Both binaries have their own App Sandbox and
  shared App Group entitlements. The helper has no file grants, inherited sandbox,
  networking, or debugger entitlement; Release removes debugger access throughout.
- `bash Tests/run-signed-bridge-proof.sh` runs independently signed, sandboxed
  processes using the production identity code. Mutual authentication succeeds.
  An unsigned same-user client, an identical signed app copy at another path,
  and an unsigned rogue server are rejected. This proves the design is feasible;
  it does not substitute for testing the production MCP listener in the app.
- Launching the actual Release bridge with access unavailable returns a clear
  instruction to open Image2Movie and enable AI-tool access. Stdout is empty.
- The HTTP listener and network entitlement are removed. Direct NIO products and
  their notices are removed; dependencies used by the official MCP SDK remain.

The signed proof needs an Early Innovations development identity. Override
`SIGNING_IDENTITY` if the default `Apple Development` name is ambiguous.

## Signed Release runtime checks (September 20, unlocked session)

- The production bundled stdio bridge initializes, discovers all six tools, and
  returns capabilities and authorized folders. Overlapping request IDs in
  simultaneous sessions remain isolated. Malformed and oversized messages are
  rejected, the 16-connection limit is enforced, and disconnected slots are reused.
- Generated images are inspected and exported through the signed app. An accepted
  export survives bridge EOF, remains running after reconnect, and completes.
  Another survives bridge termination, then cancels through a replacement session;
  the pre-existing destination bytes remain unchanged. The fixture is cleaned up.
- Disabling AI access during a 2,000-frame UHD HEVC export disconnects the client
  and rejects new bridges. The app still shows progress and Cancel. Re-enabling
  access and reconnecting finds the same job completed with all 2,000 frames.
- Native Shortcuts file handoff now passes: a following **Get Details of Files**
  reads the returned ProRes movie's size, and a separate **Save File** action writes
  its nonempty contents into another selected folder. Only the current Release
  app was running for these checks. The temporary transfer copy currently gives
  the saved file a UUID-based basename.
- Codex's `image2movie` entry is enabled and points to the correct Release helper.
  Its initial desktop connection failed during SDK parameter decoding; this was
  diagnosed and fixed in the follow-up below.

## Codex initialization compatibility (September 20)

The desktop log reported JSON-RPC error `-32603` during initialization. Capturing
the MCP request from the desktop-bundled Codex client (`0.155.0-alpha.9.2`) in an
ephemeral diagnostic session established the cause: its valid object-valued
`experimental.codex/auth-change` capability hits [Swift MCP SDK issue
#287](https://github.com/modelcontextprotocol/swift-sdk/issues/287). SDK 0.12.1
incorrectly decodes that map as string values. Omitting it succeeds; including it
reproduces the desktop error against the signed app.

- The transport now omits unused, valid object-valued experimental capabilities
  only from `initialize` before passing the request to the SDK. It preserves all
  other fields and existing request limits. The upstream SDK still handles MCP.
- Socketpair tests include the captured `2025-06-18` request, its elicitation and
  extension fields, unknown nested capabilities, empty and legacy maps, and
  malformed capability rejection. The signed-app client check also uses the
  current Codex capability shape instead of an empty capability object.
- Signed Debug/Release builds, static analysis, signature verification, and the
  complete regression suite pass. An independent GPT-6 Astra review found no
  production issue; the requested exact-wire-shape test was added.
- The desktop-bundled Codex MCP client passes six-tool discovery, capabilities,
  authorized-folder and sequence inspection, a real HEVC export with completion
  polling, and UHD cancellation with exact destination-byte preservation. These
  calls used an ephemeral diagnostic app-server session, with no saved task or
  configuration changes.
- Codex then refreshed its tools in the existing desktop conversation without
  another user restart. Direct `mcp__image2movie__` calls passed all six tools:
  capabilities and folder discovery, sequence inspection, a 13-frame HEVC export
  at 12 fps (including a duplicate input), completion polling, and cancellation of
  a separate 2,000-frame UHD job. The cancelled overwrite preserved the sentinel
  destination bytes exactly. This establishes real Codex desktop export and
  cancellation acceptance, in addition to the diagnostic client checks.

Image2Movie was rebuilt and relaunched at the configured Release path. Its AI
opt-in and folder grants remained available. Setup instructions now say to quit
and reopen Codex, rather than assuming a separate Restart button is present.

## Earlier signed application checks (September 19)

These checks establish the pre-stdio foundation. They do not establish the new
transport's signed-app runtime acceptance.

- Launched the final signed Debug and Release builds successfully.
- Launched the sandboxed app, authorized input/output fixture folders through
  Automation Settings, and verified both grants remained available after relaunch.
- Imported a 144-DPI raster outside those folder grants through Add Images and
  exported through Save. The selected-file permissions were sufficient.
- Quit the signed Release app during a 1,001-frame UHD HEVC export using
  **Cancel Export and Quit**. The process exited, the existing destination stayed
  byte-for-byte unchanged, and no extra output file appeared beside it. Relaunch
  succeeded; the original GUI size preference was restored after the check.
- Verified all three actions appear in Shortcuts. A test Shortcut passed an
  externally selected image to an authorized output folder and exported in both
  foreground and background modes. Overwrite refusal returned a clear error and
  left the previous movie byte-for-byte unchanged.
- Shortcuts launched the app from a closed state. H.264, HEVC, and ProRes 422
  results appeared as playable movies in the Shortcuts editor. Each saved movie
  decoded as the intended codec, 320 × 180, one frame, and 1/30 second.

The native return-value check initially found that returning a security-scoped
destination directly yielded an empty Shortcuts result. The intent now supplies
a separate disk-backed file in app temporary storage with an explicit movie type
and `removedOnCompletion` cleanup. The user-selected movie remains the permanent
output. The subsequent-action handoff checks passed in the September 20 session
described above.

Use one running development build for Shortcuts checks. An older Xcode-launched
copy with the same bundle identifier caused Shortcuts to contact the wrong app;
quitting the stale copy and registering/relaunching the current build resolved it.

## Remaining acceptance checks

- Exercise long native Shortcut exports and cancellation from Shortcuts itself.
- Complete the remaining signed bridge lifecycle checks: Debug runtime, two app
  copies, restart/update, production-listener unauthorized peers, incompatible
  versions, app quitting, and stale socket cleanup. Release sessions, protocol
  bounds, disconnect/reconnect, disable during export, and bridge termination pass.
- Pair Codex desktop using the generated command configuration and complete
  inspection, export, status polling, reconnect, and cancellation. No token is
  required; Codex configuration remains user-managed.
- Test a fresh sandbox container and revoked/stale authorization in the signed
  application. Test external-volume output when a writable external volume is
  available; none was mounted during this pass.

For a running signed app with AI-tool access enabled, use:

```sh
python3 Tests/run-stdio-client-check.py /path/to/Image2Movie.app/Contents/MacOS/image2movie-mcp
```

The script checks real stdio sessions, isolation, message limits, connection bounds,
and reconnect. Supply `--input-id`, `--input-root`, `--output-id`, and
`--output-root` for generated fixture inspection, export, polling, bridge loss,
cancellation, and destination preservation.
Those folders must already be authorized through the app. It does not edit app
preferences, folder grants, or Codex settings. These checks have passed against
the production signed Release app.

The standalone harness does not replace these checks. Keep the milestone open
until its signed-app and real-client acceptance criteria pass.
