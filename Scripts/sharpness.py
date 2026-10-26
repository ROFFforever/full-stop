# How sharp a recording is: median edge sharpness of the scene above the hood, on frames taken while moving.
# Usage: .venv/bin/python Scripts/sharpness.py "<drive folder>" [more folders...]
# Reference (Oct 2026): autofocus drives 47-81; the focus-locked drives of Oct 21 ~10 (blurry). Lighting changes it
# somewhat, so compare drives in similar light.
import csv, json, sys
import cv2, numpy as np

for folder in sys.argv[1:]:
    meta = json.load(open(folder + "/meta.json"))
    t0 = meta["video_start_t"]
    gps = [(float(r["t"]) - t0, float(r["speed"])) for r in csv.DictReader(open(folder + "/sensors.csv"))
           if r["kind"] == "gps" and r["speed"]]
    moving_only = any(s >= 6 for _, s in gps)  # A parked test clip has no fast GPS: use every frame.
    def speed(t):
        before = [s for tt, s in gps if tt <= t]
        return before[-1] if before else -1
    video = cv2.VideoCapture(folder + "/video.mov")
    next_t, scores = 1.0, []
    while len(scores) < 120:
        ok, frame = video.read()
        if not ok: break
        t = video.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if t < next_t: continue
        next_t = t + 2.0
        if moving_only and speed(t) < 6: continue  # 13+ mph.
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        h, w = gray.shape
        scene = gray[int(h * .15):int(h * .55), int(w * .2):int(w * .8)]
        scores.append(cv2.Laplacian(scene, cv2.CV_64F).var() / (scene.std() ** 2 + 1e-6) * 1000)  # Contrast-normalized.
    print(f"{folder}: sharpness {np.median(scores):.0f} ({len(scores)} frames) | camera: {meta.get('camera_settings', 'not recorded')[:60]}")
