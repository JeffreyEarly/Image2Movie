# Image2Movie

A macOS application for turning a sequence of images into an H.264 MPEG-4 movie,
with controls for frame rate, output size, and bit rate. Written in Objective-C
using Cocoa and AVFoundation.

Exports support up to UHD 3840 x 2160 at 1–30 fps. The 4K preset uses H.264
Main AutoLevel at 36 Mb/s by default, with a 50 Mb/s maximum. Existing output
files are replaced only after successful encoding; cancellation or failure
preserves the previous movie. Unreadable images stop the export with an error.

This repository starts from the existing Image2Movie 3.0.1 source. The first
compatibility pass keeps the original interface and AVFoundation encoder, raises
the deployment target to macOS 12.0, removes an unused QTKit dependency, and adds
explicit types to two dictionary-controller calls required by the current compiler.

## Project contents

- `Image2Movie.xcodeproj`: Xcode project and shared `Image2Movie` scheme.
- `*.h`, `*.m`, and `Image2Movie_Prefix.pch`: application source, including the
  older operations retained in the project's "Old - Unused" group.
- `PrimaryWindow.xib` and `English.lproj`: interface and localization resources.
  The legacy `MainMenu.nib` directory contains both its editable representation
  and archived objects and is required by the project.
- `Image2MovieIcon.iconset`, `File-Movies-icon.png`, and `icon-license.txt`: icon
  assets and their original attribution/license notice.
- `Implementation Notes`: original movie-encoding design notes.
- `Matlab_Animation_Example.m`: example script that generates animation frames
  in `Animation_Example_Frames/` when run from the repository root with MATLAB.

Prebuilt applications, historical ZIP archives, generated example frames, movie
exports, build output, and personal Xcode settings are excluded from version
control.

## Opening and building

Open `Image2Movie.xcodeproj` in Xcode, select the `Image2Movie` scheme and `My Mac`,
and choose Run. The project can also be built from a terminal:

```sh
xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

The resulting app is at `build/Build/Products/Debug/Image2Movie.app`. To use it,
drag image files from Finder into the image list, choose a frame rate and size,
and click **Save Movie** to export an MP4.

Run the standalone regression checks from a terminal with Xcode selected:

```sh
bash Tests/run-regressions.sh
```

The script compiles against the app sources, generates temporary fixtures, and
checks destination preservation, invalid settings and images, cancellation and
retry, main-thread notifications, pixel sizing, controller readiness, and decoded
ordinary/UHD/vector movies. It adds no test target or dependencies. Temporary
files are removed on exit; set `KEEP_TEST_OUTPUT=1` to retain them for inspection.
The encoder checks require access to macOS video services and may fail in a
restricted shell sandbox.

Validated on macOS 27.0 (Apple silicon) with Xcode 27.0: Debug and Release builds,
static analysis, the regression harness, and UI checks for UHD export, Cancel,
and corrupt-frame error presentation. The movie exported through the UI also
decoded to the expected ordered UHD frames. The original interface and legacy
encoding profiles remain available alongside the new UHD preset.

The macOS 12.0 deployment target is the oldest supported by this Xcode version;
older systems have not been tested. Existing deprecation warnings and legacy
Interface Builder resources remain for a later modernization pass. The unused
QTKit operation source files are retained for historical reference and are not
part of the build.

## Licensing

The original source copyright notices are preserved. No new source-code license
has been assigned by this import. The icon has a separate notice in
`icon-license.txt` specifying free non-commercial use.
