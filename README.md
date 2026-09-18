# Image2Movie

A macOS application for turning a sequence of images into an H.264 MPEG-4 movie,
with controls for frame rate, output size, and bit rate. Written in Objective-C
using Cocoa and AVFoundation.

This repository preserves the existing Image2Movie 3.0.1 source as a baseline for
future updates. Application source and project build settings are unchanged from
the local project; its existing Xcode scheme is now shared.

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

Open `Image2Movie.xcodeproj` in Xcode and select the `Image2Movie` scheme.
The project can also be invoked from a terminal:

```sh
xcodebuild -project Image2Movie.xcodeproj -scheme Image2Movie \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

This is a legacy project with a macOS 10.8 deployment target, QTKit framework
references, and older Interface Builder resources. Compatibility with modern
Xcode and macOS SDKs needs to be addressed as part of the upcoming update.

Import validation with Xcode 27.0 recognized the project, target, and shared
scheme. All local project file references resolve. The build stops because
Xcode 27.0 supports deployment targets starting at macOS 12.0, while this project
targets 10.8; further build compatibility issues have not yet been assessed.

## Licensing

The original source copyright notices are preserved. No new source-code license
has been assigned by this import. The icon has a separate notice in
`icon-license.txt` specifying free non-commercial use.
