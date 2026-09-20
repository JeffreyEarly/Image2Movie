# Image2Movie automation

Image2Movie provides native Shortcuts actions and an optional local MCP server.
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

In Automation Settings, select **Start Server**. The app listens only on
`http://127.0.0.1:8765/mcp`, using Streamable HTTP. The endpoint requires a bearer
token stored in the app's Keychain entry. **Copy Token** and **Copy Codex
Configuration** provide the values needed by your client. No token is written to
application logs.

For Codex, the copied configuration is:

```toml
[mcp_servers.image2movie]
url = "http://127.0.0.1:8765/mcp"
bearer_token_env_var = "IMAGE2MOVIE_MCP_TOKEN"
```

Set `IMAGE2MOVIE_MCP_TOKEN` in the environment of the process that launches your
Codex client, then restart that client. A variable exported in a terminal is not
automatically available to an already-running desktop app. Alternatively,
configure the client's supported HTTP authorization-header setting with the
copied bearer token. Image2Movie never edits Codex configuration itself. See
[Codex MCP configuration](https://developers.openai.com/codex/mcp).

**Rotate Token** closes existing MCP sessions and invalidates the previous token.
Update the client's token and reconnect afterward. **Stop Server** closes the
listener; accepted exports continue and remain cancellable in the movie window.
Enabling the server is remembered for subsequent app launches. Nothing continues
listening after the app exits.

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

The server limits request bodies to 1 MiB, concurrent connections and sessions
to 16, and requests per session to 100. Sessions expire after 10 minutes idle or
one hour total; clients should reinitialize after a session-not-found response.
These limits do not cancel export jobs. Reconnect and poll the same job identifier.

## Troubleshooting

- **Busy:** wait for the active export or cancel it. Dismiss any open movie-window
  sheet before requesting an automated export.
- **Folder unavailable:** reconnect the drive and reauthorize the folder. A path
  string from another program cannot grant sandbox access.
- **Destination exists:** choose a new filename or explicitly enable overwrite.
- **Cannot listen on port 8765:** another application is using the port. Stop
  that listener before starting Image2Movie's server.
- **Unauthorized:** copy the current token, check the client's authorization
  configuration, and reconnect after rotation.
- **Session expired:** initialize a new MCP session; an accepted job keeps running.
- **Job not found:** jobs are session-local to the running app and only the latest
  20 terminal jobs are kept. Relaunching clears that history.

## Development checks

Run `bash Tests/run-regressions.sh` for the export/UI harness and native Swift/MCP
checks. The command generates temporary fixtures and does not use your image
library or live MCP token. Unsigned command-line tests cannot establish sandbox
bookmark behavior or real client pairing. See the [signed-app validation
record](Tests/AutomationValidation.md) for completed checks and remaining acceptance
tests.
