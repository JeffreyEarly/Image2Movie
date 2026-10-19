#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_identity="${SIGNING_IDENTITY:-Apple Development}"
proof_dir="$(mktemp -d /tmp/image2movie-signed-proof.XXXXXX)"
app="$proof_dir/Image2Movie.app"
helper="$app/Contents/MacOS/image2movie-mcp"
other="$proof_dir/Other.app"
server_pid=""
trap 'if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi' EXIT

mkdir -p "$app/Contents/MacOS" "$other/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Image2Movie</string>
<key>CFBundleIdentifier</key><string>com.EarlyInnovations.Image2Movie</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$proof_dir/helper-info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>image2movie-mcp</string>
<key>CFBundleIdentifier</key><string>com.EarlyInnovations.Image2Movie.MCPBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
sources=("$project_dir/MCPPeerIdentity.swift" "$project_dir/MCPUnixSocket.swift"
         "$project_dir/Tests/BridgeIdentityProof.swift")
swiftc -swift-version 6 -target arm64-apple-macosx27.0 \
    -module-cache-path "$proof_dir/module-cache" "${sources[@]}" \
    -o "$proof_dir/unsigned-client" -lbsm
cp "$proof_dir/unsigned-client" "$app/Contents/MacOS/Image2Movie"
swiftc -swift-version 6 -target arm64-apple-macosx27.0 \
    -module-cache-path "$proof_dir/module-cache" "${sources[@]}" \
    -o "$helper" -lbsm \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$proof_dir/helper-info.plist"
codesign --force --sign "$signing_identity" \
    --identifier com.EarlyInnovations.Image2Movie.MCPBridge \
    --entitlements "$project_dir/MCPBridge.entitlements" --options runtime "$helper"
codesign --force --sign "$signing_identity" \
    --entitlements "$project_dir/Image2Movie.entitlements" --options runtime "$app"
codesign --verify --strict "$app"
rm -rf "$other"
cp -R "$app" "$other"
codesign --verify --strict "$other"

"$app/Contents/MacOS/Image2Movie" server 2> "$proof_dir/server.log" &
server_pid=$!
for _ in {1..50}; do
    socket_path="$(sed -n 's/^socket=//p' "$proof_dir/server.log" | head -1)"
    [[ -n "$socket_path" ]] && break
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.1
done
[[ -n "${socket_path:-}" ]] || { cat "$proof_dir/server.log"; exit 1; }
"$helper" client "$socket_path" 2> "$proof_dir/client.log"
"$proof_dir/unsigned-client" rogue "$socket_path" 2> "$proof_dir/unsigned.log"
"$other/Contents/MacOS/image2movie-mcp" rogue "$socket_path" \
    2> "$proof_dir/wrong-copy.log"
wait "$server_pid"
server_pid=""

"$proof_dir/unsigned-client" rogue-server "$socket_path" \
    2> "$proof_dir/rogue-server.log" &
server_pid=$!
for _ in {1..50}; do
    [[ -S "$socket_path" ]] && break
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.1
done
if "$helper" client "$socket_path" 2> "$proof_dir/rejected-client.log"; then
    echo "signed helper accepted unsigned server" >&2
    exit 1
fi
wait "$server_pid"
server_pid=""

rg -q '^client=verified$' "$proof_dir/client.log"
rg -q '^rogue=rejected$' "$proof_dir/unsigned.log"
rg -q '^rogue=rejected$' "$proof_dir/wrong-copy.log"
rg -q '^rogue-server=rejected$' "$proof_dir/rogue-server.log"
rg -q '^attempt0=accepted$' "$proof_dir/server.log"
rg -q '^attempt1=rejected$' "$proof_dir/server.log"
rg -q '^attempt2=rejected$' "$proof_dir/server.log"
printf 'Signed App Group peer proof passed: %s\n' "$proof_dir"
