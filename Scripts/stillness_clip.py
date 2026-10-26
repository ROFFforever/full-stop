"""Renders a demo clip: the drive's video on top, the "shake meter" (how much the phone shakes) underneath.

The meter is what StillnessMeter (Motion/SignalFilters.swift) looks at: RMS of user acceleration and of rotation rate over
the last 1 s, each divided by its limit (0.06 g, 0.06 rad/s), and the larger of the two plotted. Under the line = still.
With --gps it also shows GPS speed and the coach's rule: stillness counts only if GPS also reads <= 2.9 mph within 2 s.

  .venv/bin/python Scripts/stillness_clip.py DriveData/20261023-210028 550 559 Demo/stillness/1-full-stop.mp4 --title "Full stop"
  ... --preview  writes a PNG of the whole meter instead of a video (to pick start/end times).
Times are video seconds (as in the viewer).
"""
import argparse
import csv
import json
from pathlib import Path

import av
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

WINDOW, MAX_ACCEL, MAX_ROTATION = 1.0, 0.06, 0.06  # StillnessMeter
STILL_MAX_SPEED, STILL_CONFIRM = 1.3, 2.0  # CoachTuning.stillMaxSpeed (m/s), stillConfirmSeconds
MPH = 2.23694
FPS = 30
GREEN, RED, GRAY, INK, BG = "#2fbf71", "#e5484d", "#8a8f98", "#f2f2f2", "#111316"


def load(folder: Path):
    meta = json.loads((folder / "meta.json").read_text())
    t0 = meta["video_start_t"]
    motion, gps = [], []
    for r in csv.DictReader(open(folder / "sensors.csv")):
        if r["kind"] == "motion":
            motion.append([float(r["t"]) - t0] + [float(r[c]) for c in ("ax", "ay", "az", "rx", "ry", "rz")])
        elif r["kind"] == "gps" and r["speed"] != "":
            gps.append((float(r["t"]) - t0, float(r["speed"])))
    m = np.array(motion)
    t, a2, r2 = m[:, 0], (m[:, 1:4] ** 2).sum(1), (m[:, 4:7] ** 2).sum(1)
    # Trailing 1 s RMS at every sample, like StillnessMeter.
    first = np.searchsorted(t, t - WINDOW)
    n = np.arange(len(t)) - first + 1
    ca, cr = np.concatenate([[0], np.cumsum(a2)]), np.concatenate([[0], np.cumsum(r2)])
    accel = np.sqrt((ca[1:] - ca[first]) / n)
    rot = np.sqrt((cr[1:] - cr[first]) / n)
    full = (t - t[first] >= WINDOW * 0.9) & (n >= 10)
    shake = np.maximum(accel / MAX_ACCEL, rot / MAX_ROTATION)
    still = full & (shake < 1)
    g = np.array(gps)
    return t, shake, still, g[:, 0], g[:, 1]


def gps_at(gt, gs, t):
    """Latest GPS reading at time t (m/s), or None if there is none or it is invalid (-1 = no speed)."""
    i = np.searchsorted(gt, t, side="right") - 1
    return None if i < 0 or gs[i] < 0 or t - gt[i] > 2.0 else float(gs[i])


def counts_as_stop(gt, gs, t):
    """Stillness is confirmed if some GPS reading within the last 2 s is slow enough (or GPS has nothing usable)."""
    recent = gs[(gt > t - STILL_CONFIRM) & (gt <= t)]
    return len(recent) == 0 or bool((recent <= STILL_MAX_SPEED).any())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("folder", type=Path)
    p.add_argument("start", type=float)
    p.add_argument("end", type=float)
    p.add_argument("out", type=Path)
    p.add_argument("--title", default="")
    p.add_argument("--gps", action="store_true", help="show GPS speed and whether stillness counts as a stop")
    p.add_argument("--preview", action="store_true")
    args = p.parse_args()

    t, shake, still, gt, gs = load(args.folder)
    w = (t >= args.start) & (t <= args.end)
    top = 4.0  # Meter's y range is clipped here; bumps go far higher and would squash the part that matters.

    if args.preview:
        fig, (a1, a2) = plt.subplots(2, 1, figsize=(14, 5), sharex=True)
        a1.plot(t[w], np.minimum(shake[w], top)); a1.axhline(1, color="r"); a1.set_ylabel("shake / limit")
        a1.fill_between(t[w], 0, top, where=still[w], color="g", alpha=0.2)
        gw = (gt >= args.start) & (gt <= args.end)
        a2.plot(gt[gw], np.where(gs[gw] >= 0, gs[gw] * MPH, np.nan), "o-"); a2.set_ylabel("GPS mph"); a2.grid()
        fig.savefig(args.out, dpi=90)
        return

    vin = av.open(str(args.folder / "video.mov"))
    vs = vin.streams.video[0]
    vs.thread_type = "AUTO"
    vin.seek(int(args.start / vs.time_base), stream=vs, backward=True)
    frames = vin.decode(vs)

    W, VH, PH = 1280, 720, 330  # Output size: video on top, meter panel below.
    fig = plt.figure(figsize=(W / 100, (VH + PH) / 100), dpi=100, facecolor=BG)
    ax_v = fig.add_axes([0, PH / (VH + PH), 1, VH / (VH + PH)]); ax_v.axis("off")
    ax_m = fig.add_axes([0.07, 0.07, 0.62, (PH - 70) / (VH + PH)], facecolor=BG)
    img = ax_v.imshow(np.zeros((VH, W, 3), np.uint8))
    if args.title:
        ax_v.text(0.02, 0.95, args.title, transform=ax_v.transAxes, color="white", fontsize=26, weight="bold", va="top",
                  bbox=dict(facecolor="black", alpha=0.55, edgecolor="none", pad=8))

    ax_m.set_xlim(args.start, args.end); ax_m.set_ylim(0, top)
    ax_m.axhspan(0, 1, color=GREEN, alpha=0.12)
    ax_m.axhline(1, color=GREEN, lw=2, ls="--")
    ax_m.text(args.start + 0.2, 1.08, "still line", color=GREEN, fontsize=13)
    ax_m.set_yticks([]); ax_m.set_xticks([])
    for s in ax_m.spines.values():
        s.set_color("#333")
    ax_m.set_title("How much the phone is shaking", color=INK, fontsize=16, loc="left")
    line, = ax_m.plot([], [], color=INK, lw=2.2)
    cursor = ax_m.axvline(args.start, color=GRAY, lw=1)

    badge = fig.text(0.73, 0.23, "", fontsize=30, weight="bold", color=INK)
    gps_txt = fig.text(0.73, 0.15, "", fontsize=20, color=INK)
    verdict = fig.text(0.73, 0.07, "", fontsize=20, weight="bold")

    out = av.open(str(args.out), "w")
    os_ = out.add_stream("libx264", rate=FPS)
    os_.width, os_.height, os_.pix_fmt = W, VH + PH, "yuv420p"
    os_.options = {"crf": "18", "preset": "medium"}

    frame, upcoming = None, next(frames)
    for i in range(int((args.end - args.start) * FPS)):
        now = args.start + i / FPS
        # Variable frame rate: show the latest frame at or before now.
        while upcoming is not None and (frame is None or upcoming.time <= now):
            frame, upcoming = upcoming, next(frames, None)
        img.set_data(frame.to_ndarray(format="rgb24", width=W, height=VH))

        k = w & (t <= now)
        line.set_data(t[k], np.minimum(shake[k], top))
        cursor.set_xdata([now, now])
        j = np.searchsorted(t, now, side="right") - 1
        is_still = bool(still[j]) if j >= 0 else False
        badge.set_text("STILL" if is_still else "shaking")
        badge.set_color(GREEN if is_still else GRAY)
        if args.gps:
            sp = gps_at(gt, gs, now)
            gps_txt.set_text("GPS: no reading" if sp is None else f"GPS: {sp * MPH:.1f} mph")
            if is_still:
                ok = counts_as_stop(gt, gs, now)
                verdict.set_text("✓ counts as a stop" if ok else "✗ not a stop")
                verdict.set_color(GREEN if ok else RED)
            else:
                verdict.set_text("")

        fig.canvas.draw()
        rgb = np.asarray(fig.canvas.buffer_rgba())[:, :, :3]
        for pkt in os_.encode(av.VideoFrame.from_ndarray(np.ascontiguousarray(rgb), format="rgb24")):
            out.mux(pkt)
    for pkt in os_.encode():
        out.mux(pkt)
    out.close()
    vin.close()
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
