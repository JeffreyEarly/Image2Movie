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

## Website downloads (October 19, 2026)

The local website candidates are **4.0 (1)** and **3.1 (1)**. The latter is built from the separate `release/3.x` checkout with version metadata updated to 3.1; its rendering/export code is unchanged. The owner confirmed permission to retain the current icon for these releases. Its original attribution notice is retained.

Website distribution uses Developer ID, separately from the App Store export above. `DeveloperIDExportOptions.plist` exports a local signed application. `NotarizationOptions.plist` **uploads the build to Apple for notarization**; it does not publish to the website or submit to App Review. The owner authorized notarization for both candidates.

For 4.0, archive with the existing project signing settings:

```sh
xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/Automation \
  -archivePath build/WebsiteRelease/Image2Movie-4.0.xcarchive \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath build/WebsiteRelease/Image2Movie-4.0.xcarchive \
  -exportOptionsPlist Distribution/NotarizationOptions.plist \
  -exportPath build/WebsiteRelease/Notarization -allowProvisioningUpdates

# Run after Apple has completed processing the upload.
xcodebuild -exportNotarizedApp \
  -archivePath build/WebsiteRelease/Image2Movie-4.0.xcarchive \
  -exportPath build/WebsiteRelease/Notarized

xcrun stapler validate build/WebsiteRelease/Notarized/Image2Movie.app
codesign --verify --deep --strict build/WebsiteRelease/Notarized/Image2Movie.app
spctl --assess --type execute --verbose=2 build/WebsiteRelease/Notarized/Image2Movie.app
mkdir -p build/WebsiteRelease/downloads
ditto -c -k --sequesterRsrc --keepParent \
  build/WebsiteRelease/Notarized/Image2Movie.app \
  build/WebsiteRelease/downloads/Image2Movie-4.0.zip
```

If `-exportNotarizedApp` reports processing, wait for Apple and retry that export, rather than submitting another build. Never package an unsigned or unstapled fallback as the finished download. For 3.1, use the distribution instructions in its own checkout.

### Candidate verification

Both applications and the 4.0 helper are signed by `Developer ID Application: Early Innovations, LLC (BWNJC57N56)`, with hardened runtime. Both tickets validate, and Gatekeeper reports `accepted` / `Notarized Developer ID`. The 3.1 app contains `x86_64` and `arm64` code with minimum macOS 12; 4.0 is `arm64` with minimum macOS 27.

Both standalone regression suites passed with Xcode 27.1. The actual notarized 4.0 app passed six-tool discovery, concurrent sessions, malformed/oversized rejection, connection limits, a real export, bridge disconnect/reconnect, cancellation, and destination preservation using existing folder grants. Both ZIPs were uploaded only to the isolated DDEV Media Library, downloaded through the local preview, compared byte-for-byte, extracted, and validated again. Both downloaded apps launched through Gatekeeper; the 3.1 About window reports 3.1 (1).

Local artifacts and evidence are under ignored `build/WebsiteRelease/`: `downloads/`, `release-manifest.json`, archives, notarization/export logs, and regression/client logs. `downloads/SHA256SUMS.txt` identifies the exact review ZIPs. No website publication, GitHub release, App Store submission, or TestFlight upload was performed.

The local website preview is `https://jeffreyearly-wp.ddev.site/programming/image2movie/`. Publication requires review of that page and the exact ZIPs. Older macOS/Intel runtime testing and the previously listed fresh/revoked authorization, external-volume, and extended Shortcuts acceptance checks remain outstanding. These candidates do not establish those untested cases.
