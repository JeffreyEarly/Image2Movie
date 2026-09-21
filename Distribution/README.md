# Image2Movie distribution

The project uses automatic signing for Early Innovations, LLC (team
`BWNJC57N56`). `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project
build settings supply both executables' version and build number. The current
candidate is **4.0 (1)**. Before a later upload, choose a build number greater
than any previously uploaded Mac build; the export configuration leaves it
unchanged.

## Archive and local App Store export

With the Early Innovations account configured in Xcode:

```sh
xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/Automation \
  -archivePath build/ReleasePreparation/Image2Movie-4.0.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath build/ReleasePreparation/Image2Movie-4.0.xcarchive \
  -exportOptionsPlist Distribution/ExportOptions.plist \
  -exportPath build/ReleasePreparation/AppStore \
  -allowProvisioningUpdates
```

`ExportOptions.plist` produces a local package; it does not upload a build.
Xcode can use the team's cloud-managed distribution identities even when the
local keychain only contains a development identity. The archive is normally
development-signed; export re-signs the app and helper for distribution and
signs the installer package. Both executables keep their own sandbox entitlements.

The app installs under `/Applications`. The helper is embedded in the app, with
`SKIP_INSTALL=YES`, and both executables have matching dSYMs in the archive.

## Signature checks

The bridge accepts Apple's documented Mac App Store certificate case in addition
to Early Innovations development/distribution signatures. Both cases require an
Apple trust anchor and the exact code identifier. Connections additionally check
the kernel-provided user identity and the containing installation's canonical
path. See [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

`Tests/SigningRequirementCheck.swift` is a standalone read-only signature check.
Compile it with `MCPPeerIdentity.swift` and `-lbsm`; supply a signed Image2Movie
app, an installed Apple-re-signed Mac App Store app, and an ad-hoc executable
signed with Image2Movie's identifier. It verifies both signing cases and rejects
ad-hoc code, swapped app/helper identities, and unrelated Store apps. Continue to
run `Tests/run-signed-bridge-proof.sh` for mutual authentication and installation
isolation in independently sandboxed processes.

## September 21, 2026 validation

- The 4.0 (1) arm64/macOS 27 archive and local App Store package export succeeded.
- Xcode used **Cloud Managed Apple Distribution** for both executables and
  **3rd Party Mac Developer Installer: Early Innovations, LLC** for the package.
- Strict nested signature verification, version metadata, sandbox entitlements,
  the Store provisioning profile, and matching app/helper dSYMs passed.
- The production requirement accepted the actual development and exported
  distribution binaries. Its Store-certificate case passed against installed
  Numbers, and the negative identity/ad-hoc cases passed.
- Signed sandbox peer checks, the complete codec/UI/coordinator/MCP regression
  suite, and static analysis passed. An independent GPT-6 Astra review found no
  actionable production issue.
- Apple server-side validation was not run because this package is being kept
  local. It requires sending the package to Apple; local export and signature
  verification do not establish acceptance. No TestFlight or App Review build
  was uploaded.

Store-processed Image2Movie/helper runtime behavior still needs an installed
TestFlight/App Store build. The Numbers check establishes certificate-policy
compatibility, not that final integration result. Remaining sandbox, external
volume, and Shortcuts checks are recorded in
[AutomationValidation.md](../Tests/AutomationValidation.md).
