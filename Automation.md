# Image2Movie automation

Image2Movie provides native Shortcuts actions and an optional bundled MCP bridge.
Both use the same exporter as the window. There is one active export at a time;
additional requests receive a busy error. Automation does not replace your image
list, change your saved settings, or consume Undo history.

## Authorize folders

Choose **Image2Movie → Automation Settings…** (⌘,). Add an input folder and an
output folder with **Authorize Folder…**. Inputs can be read; outputs can be read
and written. Folder grants are stored as security-scoped bookmarks. A remembered
path by itself does not give the app access.

Use **Reauthorize…** when a drive is disconnected, a bookmark is unavailable, or
access has changed. **Remove** prevents new automation requests from using that
grant. An export that already acquired access can finish. Source files, previews,
Undo snapshots, and active exports retain only the access they still need.

MCP can list existing grants but cannot create grants. Folder-relative paths
reject absolute paths, traversal, and symlinks leaving the authorized folder.
Resolved paths are canonicalized before use. Keep source folders stable during an
export; this is not a snapshot of their contents or a filesystem isolation service
against other local processes modifying those folders concurrently.

## Shortcuts

Create a Shortcut with **Image2Movie → Export Movie**:

1. Supply an ordered list of image files, such as files from a numbered sequence
   or the Shortcut's file input. Duplicates are preserved.
2. Choose an authorized output folder and filename.
3. Set Width and Height. The defaults for the remaining settings are HEVC, High
   quality, 30 fps, and Overwrite Existing Movie off.
4. Use the returned movie file in the next action.

The permanent movie stays in the chosen output folder. Shortcuts receives a
temporary file for the handoff and manages its removal after the run; returning
a large movie may require temporary disk space in addition to the saved output.

H.264 and HEVC use `.mp4`; ProRes 422 uses `.mov`. The action adds the extension
when it is absent. Custom Bit Rate accepts 0.1–50 Mb/s for H.264/HEVC. ProRes uses
its native automatic settings. The action reports progress and supports
cancellation. **Get Export Status** and **Cancel Export** accept a selected job
or use the active job when omitted.

Only the latest 20 completed jobs are retained, in memory. Jobs do not resume
after quitting. Quitting during an export offers to keep exporting or cancel
and wait for temporary-output cleanup.

## Connect an MCP client

1. Install and open Image2Movie for initial setup. A signed Xcode Debug build also
   works; configure the bridge bundled in that particular copy.
2. In Automation Settings, enable **Allow AI tools to use Image2Movie**.
3. Authorize input and output folders.
4. Choose **Copy Codex Configuration** and add the copied block to your Codex
   configuration. Codex supports command-based STDIO servers in `config.toml`;
   see the [official MCP setup documentation](https://developers.openai.com/codex/mcp).
5. Reconnect Codex (or quit and reopen it), then request an export. Image2Movie
   does not need to be open after initial setup: the bridge starts it when needed.

You can also use **Codex → Settings → MCP servers → Add server**. Name it
`image2movie`, choose **STDIO**, and put the executable path from the copied
configuration in **Command**. This field takes the actual filesystem path, not
TOML: omit the surrounding quotes and decode any escaped quotes or backslashes.
Leave arguments and environment variables empty. Save, then quit and reopen
Codex. No token is needed.

For an app installed in `/Applications`, the configuration is:

```toml
[mcp_servers.image2movie]
command = "/Applications/Image2Movie.app/Contents/MacOS/image2movie-mcp"
```

The app generates the actual path, including TOML escaping. Image2Movie never
edits Codex settings. If the app moves, copy its configuration again. After
restarting or updating Image2Movie, reconnect the client.

Codex launches the bundled executable automatically. If its containing app is
closed, the bridge starts that exact signed copy in the background. It waits up
to eight seconds for an authenticated connection, without opening a movie window
or taking focus. An already-running app keeps its current window state. Codex may
connect when loading tools, before your first export request.

Image2Movie remains running in the Dock until you quit it, even after clients
disconnect. Click its Dock icon to show the existing window, inspect progress,
or cancel an export. Quitting during an export retains the normal cancellation
confirmation. Existing bridge sessions exit when the app exits; they do not
relaunch it or replay requests. A fresh connection can start it again. Recent
jobs remain available while the app runs and are cleared on app relaunch.

The bridge relays standard MCP
messages over stdin/stdout to a private Unix-domain socket in the shared App
Group. The app and bridge verify the same user, Early Innovations code signatures,
and the containing app installation before exchanging MCP messages. A bridge
from one build cannot silently connect to another copy. Diagnostics use stderr.

Enabling access authorizes local tools that launch the signed bridge; it does
not authenticate Codex specifically. The bridge has its own sandbox and receives
no folder grants. All file authorization and exports remain in the main app.

Access is disabled by default and remembered after explicit enablement. Disabling
it closes connections; accepted exports continue and remain visible and
cancellable in Image2Movie. Automatic launch never enables access or authorizes
folders. When access is disabled, a connection may start the app quietly but will
fail within the startup deadline; open Automation Settings to enable it. There is
no TCP listener, bearer token, additional installation, or login item.

This stdio design supersedes the earlier HTTP prototype. Its old enablement
preference and app-owned Keychain token are removed without carrying enablement
forward. Folder grants and export preferences are preserved.

## Tools and export requests

| Tool | Purpose |
| --- | --- |
| `get_capabilities` | Supported codecs, quality modes, limits, defaults, and file types |
| `list_authorized_folders` | Folder identifiers, names, and read/write roles |
| `inspect_sequence` | Supported files in numeric filename order and rejected entries |
| `export_movie` | Start a job from an explicit ordered list and return its identifier |
| `get_export_status` | Progress, effective settings, destination, and terminal result |
| `cancel_export` | Cancel an active job |

Always use the identifiers returned by `list_authorized_folders`. Inspecting a
folder does not automatically choose the export's input order. Width and height
are required; frame rate, codec, and quality have stable defaults independent of
the window's preferences. Read the tool's advertised schema for exact field
names and units.

No destination is overwritten unless the request explicitly allows it. Encoding
uses temporary output on the destination volume; successful publication is
atomic. Failed or accepted-cancelled exports preserve the existing destination.
Corrupt frames stop the export and identify the filename.

`inspect_sequence` returns pages: `offset` defaults to 0 and `limit` defaults to
100 (maximum 500). Use `next_offset` for the next page; `total_entries` includes
entries that may be rejected as unsupported. Inspection stops with an actionable
error above 10,000 directory entries; export itself accepts an explicit list and
does not require inspection. Tool results are limited to 128 KiB; reduce the page
size if unusually long filenames exceed that limit.

Requests are limited to 1 MiB and at most 16 connections. Each connection owns
an independent MCP session and processes requests sequentially with backpressure.
Responses allow room for the 128 KiB tool result and its protocol envelope. JSON-RPC
batches are not supported. These transport limits do not cancel accepted export
jobs. After reconnecting, poll the same job identifier.

## Troubleshooting

- **Busy:** wait for the active export or cancel it. Dismiss any open movie-window
  sheet before requesting an automated export.
- **Folder unavailable:** reconnect the drive and reauthorize the folder. A path
  string from another program cannot grant sandbox access.
- **Destination exists:** choose a new filename or explicitly enable overwrite.
- **Startup timeout:** the bridge could not establish a connection within eight
  seconds. Open the same app copy named in the configuration, check Automation
  Settings and AI-tool access, then reconnect. It will not automatically enable
  access, grant folders, or repeatedly restart a failing app.
- **Peer verification failed:** use the executable inside the signed app bundle.
  Rebuild/reinstall both pieces together; do not copy the helper out of the app.
- **Version mismatch:** update the app and use its bundled bridge, then reconnect.
- **Connection limit:** close unused clients and reconnect.
- **Job not found:** jobs are session-local to the running app and only the latest
  20 terminal jobs are kept. Relaunching clears that history.

## Development checks

The sandboxed bridge uses a standard open-application Apple event containing a
private `I2MA` display hint and `keyAERestoreAppState = kAENo`. macOS discards
`NSWorkspace` launch arguments from sandboxed callers, so the originally planned
command-line flag cannot carry the production startup hint. The direct
`--image2movie-automation-launch` argument remains available for development.
Neither mechanism grants access; the main app's existing preference remains the
authority. No extra Apple Events or other sandbox entitlement is required.

Run `python3 Tests/run-signed-launch-check.py /path/to/image2movie-mcp` to exercise
the production bridge against temporary signed sandbox fixtures: background
launch, concurrent starts, exact-copy selection, crash/relaunch, disabled access,
slow startup/handshake, invalid signatures, and incompatible versions. The test
needs an unlocked session and an Early Innovations signing identity. It does not
change user preferences, folder grants, or Codex settings.

Run `bash Tests/run-regressions.sh` for the export/UI harness and native Swift/MCP
checks. The command generates temporary fixtures and does not use your image
library. Unsigned command-line tests cannot establish sandbox
bookmark behavior or real client pairing. See the [signed-app validation
record](Tests/AutomationValidation.md) for completed checks and remaining acceptance
tests.
