# Automation validation

Tested on September 19, 2026 with macOS 27, Xcode 27, and Apple silicon.
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
  busy behavior, exactly one terminal result, and preserved interactive state.
- File-access tests for canonical paths, traversal and symlink rejection, and
  grant roles. An unsigned harness cannot prove security-scoped bookmark behavior.
- Live loopback MCP tests using the official SDK and a fixture token:
  authentication, Host/Origin checks, isolated sessions, schema validation,
  bounded requests/results/sessions, port conflicts, and shutdown/reconnect.
  One session survives five completed requests on fresh connections; another
  performs 30 immediate sequential requests on a single persistent connection.

Run `bash Tests/run-regressions.sh`. Set `KEEP_TEST_OUTPUT=1` to retain generated
fixtures and `REGRESSION_BUILD_DIR` to reuse an Xcode package/build cache.

## Signed application checks

- Launched the final signed Debug and Release builds successfully.
- Launched the sandboxed app, authorized input/output fixture folders through
  Automation Settings, and verified both grants remained available after relaunch.
- Imported a 144-DPI raster outside those folder grants through Add Images and
  exported through Save. The selected-file permissions were sufficient.
- Quit the signed Release app during a 1,001-frame UHD HEVC export using
  **Cancel Export and Quit**. The process exited, the existing destination stayed
  byte-for-byte unchanged, and no extra output file appeared beside it. Relaunch
  succeeded; the original GUI size preference was restored after the check.
- Started and stopped the in-app MCP listener; Keychain token creation worked.
  No real token was logged or included in test fixtures.
- Verified all three actions appear in Shortcuts. A test Shortcut passed an
  externally selected image to an authorized output folder and exported in both
  foreground and background modes. Overwrite refusal returned a clear error and
  left the previous movie byte-for-byte unchanged.
- Shortcuts launched the app from a closed state. H.264, HEVC, and ProRes 422
  results appeared as playable movies in the Shortcuts editor. Each saved movie
  decoded as the intended codec, 320 × 180, one frame, and 1/30 second.

The native return-value check found that returning a security-scoped destination
directly yielded an empty Shortcuts result. The intent now supplies a separate
disk-backed file in app temporary storage with an explicit movie type and
`removedOnCompletion` cleanup. The user-selected movie remains the permanent
output. The command-line Shortcuts runner waited in its native result UI during
file-output tests; the editor's decoded movie preview established result access.
A following built-in Save File action also waited in ShortcutsViewService
while requesting native dialog presentation. It did not save the returned file;
that handoff remains unverified. The test was stopped rather than left running.

Use one running development build for Shortcuts checks. An older Xcode-launched
copy with the same bundle identifier caused Shortcuts to contact the wrong app;
quitting the stale copy and registering/relaunching the current build resolved it.

## Remaining acceptance checks

- Exercise a following Shortcut action that saves or shares the returned movie.
- Exercise long native Shortcut exports and cancellation from Shortcuts itself.
- Pair Codex desktop with the signed app's real token and complete inspection,
  export, status polling, reconnect, cancellation, and token rotation.
- Test a fresh sandbox container and revoked/stale authorization in the signed
  application. Test external-volume output when a writable external volume is
  available; none was mounted during this pass.

The standalone harness does not replace these checks. Keep the milestone open
until its signed-app and real-client acceptance criteria pass.
