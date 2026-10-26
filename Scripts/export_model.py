"""Run from the project root: .venv/bin/python Scripts/export_model.py [weights imgsz ...]

With no arguments, exports every variant in VARIANTS. Otherwise pass one variant
as `weights imgsz`, e.g. `yolo11n.pt 960`. Output is Congressional App Challenge/<name>_<imgsz>.mlpackage
(the 640 nano model keeps its original name, yolo11n.mlpackage).
"""
from pathlib import Path
import shutil
import sys
from ultralytics import YOLO

root = Path(__file__).resolve().parents[1]
VARIANTS = [(w, size) for w in ('yolo11n.pt', 'yolo11s.pt') for size in (640, 960, 1280)]

def export(weights, imgsz):
    path = root / weights
    model = YOLO(str(path if path.exists() else weights))  # Downloads pretrained weights if missing.
    assert model.names[11] == 'stop sign', model.names
    exported = Path(model.export(format='coreml', nms=True, imgsz=imgsz))
    stem = Path(weights).stem
    name = stem if (stem, imgsz) == ('yolo11n', 640) else f'{stem}_{imgsz}'
    target = root / 'Congressional App Challenge' / f'{name}.mlpackage'
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(exported, target)
    print(f'Installed model: {target}')

if len(sys.argv) == 3:
    export(sys.argv[1], int(sys.argv[2]))
else:
    for weights, imgsz in VARIANTS:
        export(weights, imgsz)
