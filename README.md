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
  character in the source image.
- Includes Android and iOS project configurations.

## Models

The app bundles two ONNX models in `frontend/assets/models/`:

- YOLO26n Nano word detection (640 x 640 input).
- YOLO26n-Seg Nano character recognition (256 x 256 input).

An English word list is included for spelling lookup and correction
suggestions.

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
  assets/models/          Runtime ONNX models and dictionary
  test/                   Flutter tests
logo/                     Repository logo used above
```

See [`frontend/OFFLINE_MODELS.md`](frontend/OFFLINE_MODELS.md) for model and
runtime details.
