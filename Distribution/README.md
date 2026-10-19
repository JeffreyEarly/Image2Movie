# Image2Movie 3.1 website distribution

Version **3.1 (1)** preserves the classic Objective-C app on `release/3.x`, with a macOS 12 minimum and both Intel and Apple-silicon code. This release changes version metadata and signing/packaging only. The original source copy is untouched. The owner confirmed permission to retain the existing icon for these releases; the original notice remains in the repository.

Archive a hardened-runtime build signed by Early Innovations:

```sh
xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/WebsiteRelease/DerivedData \
  -archivePath build/WebsiteRelease/Image2Movie-3.1.xcarchive \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES \
  INSTALL_PATH=/Applications CODE_SIGN_STYLE=Manual \
  'CODE_SIGN_IDENTITY=Developer ID Application: Early Innovations, LLC (BWNJC57N56)' \
  DEVELOPMENT_TEAM=BWNJC57N56 archive
```

`DeveloperIDExportOptions.plist` exports locally for inspection. **`NotarizationOptions.plist` sends the build to Apple.** The owner authorized notarization for the October 19, 2026 candidate. It does not publish the app or submit it to App Review.

```sh
xcodebuild -exportArchive \
  -archivePath build/WebsiteRelease/Image2Movie-3.1.xcarchive \
  -exportOptionsPlist Distribution/NotarizationOptions.plist \
  -exportPath build/WebsiteRelease/Notarization -allowProvisioningUpdates

# After Apple finishes processing, export the application with its ticket.
xcodebuild -exportNotarizedApp \
  -archivePath build/WebsiteRelease/Image2Movie-3.1.xcarchive \
  -exportPath build/WebsiteRelease/Notarized

xcrun stapler validate build/WebsiteRelease/Notarized/Image2Movie.app
codesign --verify --deep --strict build/WebsiteRelease/Notarized/Image2Movie.app
spctl --assess --type execute --verbose=2 build/WebsiteRelease/Notarized/Image2Movie.app
mkdir -p build/WebsiteRelease/downloads
ditto -c -k --sequesterRsrc --keepParent \
  build/WebsiteRelease/Notarized/Image2Movie.app \
  build/WebsiteRelease/downloads/Image2Movie-3.1.zip
```

A processing result means to wait and retry the notarized export, not resubmit. Keep build products, logs, and archives under ignored `build/`.

## October 19, 2026 candidate

Archive and export succeeded with Xcode 27.1. Apple notarization, ticket validation, strict signature verification, and Gatekeeper acceptance passed. The full existing regression suite passed. The local WordPress preview's ZIP download matched the prepared bytes; extracted signatures/tickets remained valid. A downloaded, Gatekeeper-translocated copy launched and displayed **Image2Movie Version 3.1 (1)** in About.

Runtime verification was on Apple silicon/macOS 27. Intel and older macOS runtime testing remain outstanding. These validation limits remain in the release notes. Website publication remains pending owner review.
