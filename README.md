# Image2Movie

A macOS application for turning a sequence of images into a movie, written in
Objective-C with AppKit, Core Image, and AVFoundation. Requires **macOS 27 or later
on Apple silicon**; build with Xcode 27 or later. No third-party dependencies.

Fresh preferences select **HEVC 10-bit** and **High** quality. Existing remembered
codec choices are preserved. Choose H.264 or HEVC for MP4 output, or Apple ProRes
422 for MOV output. All codecs support dimensions up to UHD 3840 × 2160 at 1–30 fps.

| Codec | Encoder input | Automatic profile |
| --- | --- | --- |
| H.264 | 8-bit 4:2:0, with final-conversion dithering | High Auto Level |
| HEVC / H.265 | 10-bit 4:2:0 | Main10 Auto Level |
| ProRes 422 | 10-bit 4:2:2 | Native ProRes 422 |

All three share a renderer with 16-bit floating-point, extended linear sRGB
intermediates. Raster input retains its precision and embedded color profile;
untagged input is treated as sRGB. Orientation metadata and raster pixel dimensions
are honored. Vector images, including PDFs, are drawn at the output resolution.
Transparency is composited over black. Output is **SDR Rec.709**, with matching
color metadata; HDR-tagged input uses the system SDR representation or tone mapping.
Gain maps are not expanded, and HDR output is not supported.

**Standard** and **High** use the selected encoder's Consistent Quality preset at
quality factors 0.50 and 0.75. Bitrate displays **Automatic**: file size depends on
content and the encoder's preset constraints. **Custom Bitrate** uses the encoder's
High Quality variable-bitrate preset with a target of 0.1–50 Mb/s and a peak limit
of 1.5 times the target. It starts at 20 Mb/s. ProRes manages encoding automatically
and hides these controls. Profiles and bit depths are selected automatically.
Unsupported encoder configurations produce an error; the app does not silently
change codec or reduce HEVC precision.

Existing output files are replaced only after successful encoding. Cancellation
or failure preserves the previous movie. Unreadable images stop the export with a
filename-specific error. The original source archive is separate from this Git
checkout.

## Project contents

- `Image2Movie.xcodeproj`: Xcode project and shared `Image2Movie` scheme.
- `*.h`, `*.m`, and `Image2Movie_Prefix.pch`: application source.
- `PrimaryWindow.xib` and `English.lproj/MainMenu.xib`: editable interface
  and localization resources.
- `Image2MovieIcon.iconset`, `File-Movies-icon.png`, and `icon-license.txt`: icon
  assets and their original attribution/license notice.
- `Implementation Notes`: original movie-encoding design notes, kept as
  repository documentation rather than bundled with the app.
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
drag image files from Finder into the image list or choose **File → Add Images…**
(⌘O). Choose a codec, frame rate and size, then click **Save Movie** or choose
**File → Export Movie…** (⌘S). The Save dialog uses the codec's MP4 or MOV extension.
During export, the button becomes **Cancel**; the Export menu command is disabled.

Imports append supported, readable image files in the supplied order, including
duplicates. Folders, unsupported files, and missing or unreadable files are
skipped with one summary. Supported vector images such as PDF remain available.
Import checks use file metadata; damaged image contents are detected by the
first-frame loader or during export.

To remove images from the list, select one or more rows and press Delete/Backspace
or choose **Edit → Delete**. Command-click or Shift-click selects multiple rows;
Command-A selects all. This only removes entries from the movie's image list:
the source files stay on disk. **Edit → Undo** (⌘Z) and **Redo** (⇧⌘Z) restore
additions, removals, and reordering, including sorting and selection. The window
keeps up to 20 undo actions for the current session. Image-list edits and Undo/Redo
are disabled while exporting, and history remains available afterward.

Codec, frame rate, and Standard/High quality are remembered between launches,
alongside existing size preferences. Invalid saved values fall back to HEVC,
30 fps, and High. Custom bitrate edits remain available for the current session
across size and frame-rate changes; changing codec exits Custom and restores the
remembered Standard/High choice. The custom rate, image list, and undo history are
not saved between launches.

## MATLAB frame sequences

For dense, lit 3D MATLAB scenes, render lossless PNG frames at the intended output
resolution, then encode the sequence here. For UHD delivery, use **HEVC, High,
3840 × 2160, and 30 fps**. Keep the PNGs as the rendered master; they let you
compare encoding settings without repeating the MATLAB render. ProRes 422 is an
option for an editing intermediate. Avoid an initial MATLAB MP4 encode followed
by another lossy encode.

Import the numbered image files in ascending filename order and check the list
before exporting. MATLAB sidecars such as `frames.mat` are not imported as timing
metadata: set the intended playback frame rate in Image2Movie. Rendering at 4K
preserves more spatial detail than enlarging completed 1080p frames.

Source precision and encoded precision are distinct. MATLAB's `print` PNG output
is 24-bit RGB (8 bits per channel); floating-point plot data does not guarantee a
higher-precision exported image. HEVC Main10 retains precision during conversion
and compression but cannot reconstruct shades already lost in an 8-bit source.
Writing an 8-bit capture into a 16-bit container does not recover them. Supply
genuine 16-bit PNG/TIFF images when the source workflow supports them.

PDF can suit simple vector plots, but complex MATLAB 3D scenes need checks for
shading, face ordering, seams, and embedded raster images before adopting vector
output. See the [MathWorks print reference](https://www.mathworks.com/help/matlab/ref/print.html).

## Regression checks

Run the standalone regression checks from a terminal with Xcode selected:

```sh
bash Tests/run-regressions.sh
```

The script builds the Debug app, compiles a standalone harness against its sources,
and generates temporary fixtures. Checks cover export safety, cancellation and
retry, main-thread notifications, ordinary/UHD/vector movies, input orientation,
high-precision gradients, Rec.709 metadata, encoded profiles, and decoded precision.
It also loads the built menu/window to exercise imports, Undo/Redo, export guards,
panel types, and isolated preference restoration in a fresh process.

Quality comparisons use moving text, thin colored lines, gradients, and texture.
The harness writes `quality-comparison.csv` with file sizes, export times, and
luma error, plus representative decoded PNGs for inspection. These are comparisons
of one test sequence, not universal quality or file-size guarantees.

Temporary files are removed on exit; set `KEEP_TEST_OUTPUT=1` to retain them.
Set `APP_BUNDLE_PATH` to an already-built app to reuse it for the nib checks.
The encoder and renderer checks require access to macOS video/GPU services and
may fail in a restricted shell sandbox.

Validated on Apple silicon with macOS 27 and Xcode 27: Debug and Release builds,
static analysis, the full standalone suite, and a movie exported through the app.
The high-precision gradient checks verify retained detail before and after encoding;
encoded RGB checks cover both neutral gray and embedded P3 colors.

The unused QTKit operations and obsolete project settings have been removed;
their history remains in Git. Historical implementation notes are documentation
only and are not bundled into the application.

## Licensing

The original source copyright notices are preserved. No new source-code license
has been assigned by this import. The icon has a separate notice in
`icon-license.txt` specifying free non-commercial use.
