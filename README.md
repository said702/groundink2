<p align="center">
  <img src="logo/groundink.png" alt="GroundInk" width="720">
</p>

<h1 align="center">groundInk</h1>

GroundInk is a Flutter app for handwritten English spelling feedback. It detects
words and characters in a photo, compares the recognized words with an English
dictionary, and grounds spelling feedback in the original handwriting.

## Highlights

- Runs on-device; no backend or network connection is required for analysis.
- Captures an image or selects one from the gallery.
- Uses ONNX Runtime for word detection and character recognition.
- Displays spelling suggestions and highlights the relevant handwritten
  character in the source image (in blue instead of red when the writing
  itself is red).
- Reviews one mistake at a time: swipe or use the arrows, tap a word on the
  photo or in the recognized text to jump to it, correct misread letters or
  enter the intended word, and remove mistakes you do not want to look at.
- Ranks suggestions by typical children's and recognition mistakes, word
  frequency, and the neighboring words.
- Includes Android and iOS project configurations.

## Models

The app bundles two ONNX models in `frontend/assets/models/`:

- YOLO26n Nano word detection (640 x 640 input).
- YOLO26n Nano character detection (256 x 256 input).

A spelling model is included for spelling lookup and correction
suggestions: an English word list with word frequencies and word-pair
statistics. See [`frontend/OFFLINE_MODELS.md`](frontend/OFFLINE_MODELS.md)
for how suggestions are ranked and for the data sources.

## Run the app

Install Flutter and the platform toolchain, then run from the `frontend`
directory:

```sh
cd frontend
flutter pub get
flutter devices
flutter run -d <device-id>
```

For Android, Android Studio and an Android SDK are required. For iOS, use a Mac
with Xcode installed and an iPad or iPhone configured for development.

### Performance on a physical iPad / iPhone

Flutter **Debug** builds are very slow on real iOS devices because Dart code is
not compiled ahead of time. The image processing in this app is pure Dart, so a
Debug build can take minutes for a single photo. Always run a Release (or
Profile) build on hardware:

```sh
cd frontend
flutter run --release -d <ipad-id>
```

When starting from Xcode (`frontend/ios/Runner.xcworkspace`), the shared
`Runner` scheme now runs the **Release** configuration. If it was changed
locally, select *Product > Scheme > Edit Scheme > Run > Build Configuration >
Release*. Run `flutter build ios --release` (or `flutter pub get`) once before
opening Xcode so the generated Flutter files exist.

Camera and gallery images are limited to 2048 px on the long side; the models
use 640 px and 256 px inputs, so full 12 MP photos only added processing time.

## Build

```sh
cd frontend
flutter build apk --release
flutter build ios --release
```

The iOS build command must be run on macOS with Xcode. Store distribution
requires platform-specific signing and release setup.

## Project layout

```text
frontend/                 Flutter application and platform projects
  lib/                    Dart implementation
  assets/models/          Runtime ONNX models and spelling model
  test/                   Flutter tests
  tool/                   Spelling model build and evaluation scripts
logo/                     Repository logo used above
```

See [`frontend/OFFLINE_MODELS.md`](frontend/OFFLINE_MODELS.md) for model and
runtime details.
