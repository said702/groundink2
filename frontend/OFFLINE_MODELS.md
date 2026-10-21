# On-device recognition

GroundInk performs image processing, word detection, character recognition, and
spelling feedback locally. It does not require a backend connection. ONNX
inference runs in a worker isolate so the interface can report progress while
the page is processed.

The app bundles these runtime assets in `assets/models/`:

- `word_detection_model.onnx`: YOLO26n Nano word detection (input size:
  `640 x 640` pixels).
- `char_model_nano_256.onnx`: YOLO26n-Seg Nano character recognition
  (input size: `256 x 256` pixels).
- `english_words.json` for local spelling lookup and correction candidates.

Character regions are mapped back to the source image so spelling feedback can
highlight the corresponding handwritten character.
