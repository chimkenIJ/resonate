# YOLO11s (Core ML)

Object detection for obstacle alerts. Exported from Ultralytics YOLO11s (COCO, 80 classes):

```sh
python3 -m venv venv && ./venv/bin/pip install ultralytics coremltools "torch==2.7.1" "torchvision==0.22.1"
./venv/bin/yolo export model=yolo11s.pt format=coreml nms=True imgsz=640 half=True
```

`nms=True` builds a pipeline whose outputs Vision returns as `VNRecognizedObjectObservation`.
Pin torch 2.7.x; coremltools 9 fails on newer torch.

License: Ultralytics YOLO is AGPL-3.0. That's fine for a public hackathon repo; shipping a closed-source
App Store app needs an Ultralytics Enterprise license or a differently licensed model.
