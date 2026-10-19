# Image2Movie

A macOS application for turning a sequence of images into a movie,
with controls for codec, frame rate, output size, and bit rate. Written in Objective-C
using Cocoa and AVFoundation.

Choose H.264 (the default) or HEVC / H.265 for MP4 output, or Apple ProRes 422
for MOV output. H.264 and HEVC use the existing size-based bitrate defaults,
including 36 Mb/s for UHD, with a 50 Mb/s maximum (lower for legacy H.264
profiles). ProRes manages its bitrate automatically. The profile controls apply
only to H.264; custom bitrate controls apply to H.264 and HEVC. All codecs use
the existing opaque, 8-bit RGB rendering pipeline and macOS encoders, with no
additional dependencies. Encoder availability is checked when exporting.

Exports support up to UHD 3840 x 2160 at 1–30 fps. The H.264 4K preset uses
Main AutoLevel. Existing output
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
drag image files from Finder into the image list, choose a codec, frame rate and
size, and click **Save Movie**. The Save dialog uses the codec's MP4 or MOV extension.

To remove images from the list, select one or more rows and press Delete/Backspace
or choose **Edit → Delete**. Command-click or Shift-click selects multiple rows;
Command-A selects all. This only removes entries from the movie's image list:
the source files stay on disk. Removal is disabled while exporting.

Run the standalone regression checks from a terminal with Xcode selected:

```sh
bash Tests/run-regressions.sh
```

The script compiles against the app sources, generates temporary fixtures, and
checks destination preservation, invalid settings and images, cancellation and
retry, main-thread notifications, pixel sizing, controller readiness, and decoded
ordinary/UHD/vector movies, plus HEVC and ProRes codec/container selection and
controller switching. It adds no test target or dependencies. Temporary
files are removed on exit; set `KEEP_TEST_OUTPUT=1` to retain them for inspection.
The encoder checks require access to macOS video services and may fail in a
restricted shell sandbox.

Validated on macOS 27.0 (Apple silicon) with Xcode 27.0: Debug and Release builds,
static analysis, the regression harness, and UI checks for UHD export, Cancel,
and corrupt-frame error presentation. The movie exported through the UI also
decoded to the expected ordered UHD frames. The original interface and legacy
encoding profiles remain available alongside the new UHD preset.
HEVC and ProRes 422 pass ordinary/UHD decoding and export safety checks, plus
checks against the built window for codec controls and MP4/MOV Save extensions.

The macOS 12.0 deployment target is the oldest supported by this Xcode version;
older systems have not been tested. Existing deprecation warnings and legacy
Interface Builder resources remain for a later modernization pass. The unused
QTKit operation source files are retained for historical reference and are not
part of the build.

## Licensing

The Image2Movie source code and documentation are licensed under [Creative Commons Attribution 3.0 Unported (CC BY 3.0)](LICENSE), consistent with the original website. Preserve the existing copyright and author notices and credit Jeffrey Early / Early Innovations, LLC.

The icon assets are excluded from that license. Their original attribution and separate terms are in [icon-license.txt](icon-license.txt). Early Innovations has permission to use the icon in Image2Movie; this does not grant additional rights to downstream users. Third-party dependencies retain their own licenses.
