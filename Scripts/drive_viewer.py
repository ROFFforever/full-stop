"""Play back a recorded test drive: video with detection boxes, and synced sensor plots.

    .venv/bin/python Scripts/drive_viewer.py "/path/to/10:19 Data"
    .venv/bin/python Scripts/drive_viewer.py "/path/to/10:19 Data" --start 120
    MPLBACKEND=Agg .venv/bin/python Scripts/drive_viewer.py "/path/to/10:19 Data" --snapshot 64 out.png

Folder must contain video.mov, sensors.csv and meta.json from the app's RECORD TEST DRIVE.
The real Swift StopSignCoach is replayed over the recording (Scripts/run_coach_replay.sh, needs Xcode) and drawn as a
phase strip under the plots, with its spoken alerts and results; --no-coach skips that. The replay is cached in
<folder>/coach.json and redone automatically when the coach code or the recording changes.
Time axis = seconds of video. Keys: space play/pause, left/right +-1 s (shift: +-10 s), up/down playback speed,
n/p jump to next/previous stop-sign sighting, click a plot to seek.
"""
import argparse
import csv
import json
import subprocess
import time
from pathlib import Path

import av  # PyAV (pip install av). OpenCV can't seek these iPhone HEVC videos: it lands at ~2x the time asked, slowly.
import matplotlib
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Rectangle
from matplotlib.widgets import Slider

MPS_TO_MPH = 2.23694
APP_MAX_SPEED_ACC = 3.0  # GPSSpeed.maxAccuracy / MotionTuning.maxSpeedAccuracy; worse speeds are not used as speeds by the app.
PHASE_COLORS = {"signCandidate": "gold", "approaching": "orange", "stopping": "tomato", "stopped": "mediumseagreen",
                "departing": "mediumpurple", "evaluate": "gray"}
SIGN_COLORS = {"stop sign": "lime", "person": "red", "car": "deepskyblue", "truck": "deepskyblue", "bus": "deepskyblue",
               "traffic light": "yellow", "bicycle": "orange", "motorcycle": "orange"}


def num(text):
    return float(text) if text != "" else np.nan


class Drive:
    def __init__(self, folder: Path, model: str | None = None):
        self.meta = json.loads((folder / "meta.json").read_text())
        self.t0 = self.meta["video_start_t"]  # sensor clock value of video second 0
        sensors, coach_file = data_files(folder, model)
        self.model = model or self.meta.get("detector_model", "?")  # Whose detections are shown.
        rows = list(csv.DictReader(open(folder / sensors)))

        def col(kind, name):
            return np.array([num(r[name]) for r in rows if r["kind"] == kind])

        def vt(kind):  # video seconds
            return col(kind, "t") - self.t0

        self.mt, self.fwd_raw, self.fwd = vt("motion"), col("motion", "fwd_raw"), col("motion", "fwd")
        if "fwd_convention" not in self.meta:  # Older recordings logged forward acceleration with the sign inverted.
            self.fwd_raw, self.fwd = -self.fwd_raw, -self.fwd
        gps_all = {n: col("gps", n) for n in ("speed", "speed_acc", "course")}
        gt = vt("gps")
        ok = gps_all["speed"] >= 0  # -1 means "no fix" in Core Location
        self.gt, self.gspeed, self.gacc = gt[ok], gps_all["speed"][ok], gps_all["speed_acc"][ok]
        self.gcourse = gps_all["course"][ok]

        self.marks = [(float(r["t"]) - self.t0, r["note"]) for r in rows if r["kind"] == "mark"]
        self.events = [(float(r["t"]) - self.t0, r["note"]) for r in rows if r["kind"] == "event"]

        # Detections grouped per analyzed frame (they share the frame's timestamp).
        self.frame_t = np.sort(vt("frame"))
        self.dets = {}
        for r in rows:
            if r["kind"] == "det":
                self.dets.setdefault(round(float(r["t"]) - self.t0, 4), []).append(
                    (r["label"], float(r["conf"]), float(r["bx"]), float(r["by"]), float(r["bw"]), float(r["bh"]),
                     round(float(r["t"]) - self.t0, 4)))
        self.det_keys = np.array(sorted(self.dets))

        # Per-frame series for plotting: tallest stop sign and tallest person box height.
        def series(label):
            xs, ys = [], []
            for k in self.det_keys:
                hs = [d[5] for d in self.dets[k] if d[0] == label]
                if hs:
                    xs.append(k); ys.append(max(hs))
            return np.array(xs), np.array(ys)

        self.sign_t, self.sign_h = series("stop sign")
        self.person_t, self.person_h = series("person")

        # What the coach did on this drive (coach.json from Scripts/run_coach_replay.sh); empty if it wasn't run.
        self.coach_frames, self.coach_events = [], []
        if (folder / coach_file).exists():
            coach = json.loads((folder / coach_file).read_text())
            self.coach_frames, self.coach_events = coach["frames"], coach["events"]
        self.coach_t = np.array([f["t"] for f in self.coach_frames])
        # Color verdict per stop-sign box: (time, box x) -> (red share or None, is a front). Backs are shown differently.
        self.sign_info = {}
        self.sign_left = {}  # Boxes ignored for being on the left side of the frame (signs for other traffic).
        if (folder / coach_file).exists():
            for sgn in coach.get("signs", []):
                self.sign_info[(round(sgn["t"], 4), round(sgn["bx"], 4))] = (sgn["red"], sgn["front"])
                self.sign_left[(round(sgn["t"], 4), round(sgn["bx"], 4))] = not sgn.get("yourSide", True)
        self.back_t = np.array([k[0] for k, (red, front) in self.sign_info.items() if not front])
        self.back_h = np.array([d[5] for k in self.det_keys for d in self.dets[k]
                                if d[0] == "stop sign" and not self.sign_info.get((d[6], round(d[2], 4)), (None, True))[1]])

    def phase_at(self, t):
        i = np.searchsorted(self.coach_t, t, side="right") - 1
        if i < 0 or t - self.coach_t[i] > 0.5:
            return None
        return self.coach_frames[i]["phase"]

    def speech_at(self, t):  # The most recent spoken alert, kept on screen for 3 s.
        said = [e["text"] for e in self.coach_events if e["kind"] == "speak" and 0 <= t - e["t"] < 3.0]
        return said[-1] if said else None

    def detections_at(self, t):
        if len(self.frame_t) == 0:
            return []
        i = np.searchsorted(self.frame_t, t)
        best = min((j for j in (i - 1, i) if 0 <= j < len(self.frame_t)), key=lambda j: abs(self.frame_t[j] - t))
        if abs(self.frame_t[best] - t) > 0.4:
            return []
        key = round(self.frame_t[best], 4)
        return self.dets.get(key, [])

    def speed_at(self, t):
        return float(np.interp(t, self.gt, self.gspeed)) if len(self.gt) else np.nan

    def fwd_at(self, t):
        ok = ~np.isnan(self.fwd)
        if not ok.any():
            return np.nan
        i = np.argmin(np.abs(self.mt[ok] - t))
        return float(self.fwd[ok][i]) if abs(self.mt[ok][i] - t) < 0.2 else np.nan


def load_frame_times(video: Path):
    """Real presentation time (video seconds) of every frame, in order. The recording is variable-frame-rate, so frame N
    is NOT at N / 30 s: that guess drifts by up to ~0.25 s and puts boxes beside the signs. Reads only the file's index
    (no decoding): ~0.2 s for a 16-minute drive."""
    with av.open(str(video)) as container:
        stream = container.streams.video[0]
        return np.array(sorted(float(p.pts * stream.time_base) for p in container.demux(stream) if p.pts is not None))


class Viewer:
    def __init__(self, folder: Path, start: float, model: str | None = None):
        self.d = Drive(folder, model)
        self.container = av.open(str(folder / "video.mov"))
        self.stream = self.container.streams.video[0]
        self.stream.thread_type = "AUTO"  # Decode on several cores.
        self.frames = None  # Decoder positioned just after frame last_idx (an iterator of av.VideoFrame).
        self.frame_times = load_frame_times(folder / "video.mov")
        self.duration = float(self.frame_times[-1])
        self.t = start
        self.playing = False
        self.rate = 1.0
        self.last_idx = -1 # Frame number last decoded; the video is positioned just after it (-1 = at the start).
        self.frame = None
        self.last_wall = None
        self.build_figure()
        self.seek(start)

    # ---- layout
    def build_figure(self):
        plt.rcParams["keymap.back"] = []; plt.rcParams["keymap.forward"] = []
        plt.rcParams["keymap.pan"] = []; plt.rcParams["keymap.zoom"] = []
        self.fig = plt.figure(figsize=(14, 10))
        grid = self.fig.add_gridspec(6, 1, height_ratios=[5, 1.4, 1.4, 1.4, 0.5, 0.25], hspace=0.35, left=0.06, right=0.97, top=0.96, bottom=0.04)
        self.ax_video = self.fig.add_subplot(grid[0]); self.ax_video.axis("off")
        self.ax_speed = self.fig.add_subplot(grid[1])
        self.ax_fwd = self.fig.add_subplot(grid[2], sharex=self.ax_speed)
        self.ax_det = self.fig.add_subplot(grid[3], sharex=self.ax_speed)
        self.ax_phase = self.fig.add_subplot(grid[4], sharex=self.ax_speed)
        self.ax_slider = self.fig.add_subplot(grid[5])
        d = self.d

        # Speed: filled dots = used by the app, hollow = rejected for poor speed accuracy.
        self.ax_speed.plot(d.gt, d.gspeed, "-", color="tab:blue", lw=1)
        good = d.gacc <= APP_MAX_SPEED_ACC
        self.ax_speed.plot(d.gt[good], d.gspeed[good], ".", color="tab:blue", ms=4, label="GPS (accepted)")
        self.ax_speed.plot(d.gt[~good], d.gspeed[~good], "o", mfc="none", mec="tab:red", ms=4, label=f"GPS rejected (acc > {APP_MAX_SPEED_ACC} m/s)")
        self.ax_speed.set_ylabel("speed m/s"); self.ax_speed.legend(loc="upper right", fontsize=7, ncol=2)
        self.ax_speed.secondary_yaxis("right", functions=(lambda x: x * MPS_TO_MPH, lambda x: x / MPS_TO_MPH)).set_ylabel("mph")

        self.ax_fwd.plot(d.mt, d.fwd_raw, color="0.75", lw=0.6, label="fwd_raw")
        self.ax_fwd.plot(d.mt, d.fwd, color="tab:purple", lw=1, label="fwd (filtered)")
        for level in (0.3, -0.3):
            self.ax_fwd.axhline(level, color="tab:red", ls="--", lw=0.8)
        self.ax_fwd.axhline(0, color="k", lw=0.5)
        self.ax_fwd.set_ylabel("forward g"); self.ax_fwd.legend(loc="upper right", fontsize=7, ncol=2)

        self.ax_det.plot(d.sign_t, d.sign_h, ".", color="limegreen", ms=4, label="stop sign")
        self.ax_det.plot(d.person_t, d.person_h, ".", color="red", ms=3, label="person")
        if len(d.back_t) == len(d.back_h) and len(d.back_t):
            self.ax_det.plot(d.back_t, d.back_h, "o", mfc="none", mec="darkorange", ms=5, label="rejected: back of sign")
        self.ax_det.set_ylabel("box height")
        self.ax_det.legend(loc="upper right", fontsize=7, ncol=2)

        self.draw_coach_strip()
        for ax in (self.ax_speed, self.ax_fwd, self.ax_det):
            for e in d.coach_events:  # Coach's spoken alerts.
                if e["kind"] == "speak":
                    ax.axvline(e["t"], color="tab:green", lw=1.2)
            for t, note in d.marks:
                ax.axvline(t, color="tab:orange", lw=1.2)
            for t, note in d.events:
                ax.axvline(t, color="tab:red", lw=1, ls=":")
            ax.grid(alpha=0.25)
        for t, note in d.marks:
            self.ax_speed.text(t, 1.02, note, transform=self.ax_speed.get_xaxis_transform(), fontsize=7, color="tab:orange", rotation=45)
        self.ax_speed.set_xlim(0, self.duration)

        self.cursors = [ax.axvline(self.t, color="k", lw=1.2) for ax in (self.ax_speed, self.ax_fwd, self.ax_det, self.ax_phase)]
        self.slider = Slider(self.ax_slider, "t", 0, self.duration, valinit=self.t, valfmt="%.1f s")
        self.slider.on_changed(lambda v: self.seek(v, from_slider=True))
        self.image = None
        self.patches = []
        self.title = self.ax_video.set_title("", fontsize=10, loc="left", family="monospace")
        self.coach_text = self.ax_video.text(0.01, 0.98, "", transform=self.ax_video.transAxes, va="top", color="white",
                                             fontsize=14, family="monospace", bbox=dict(fc="black", ec="none", alpha=0.6, pad=4))
        # Blitting: the graphs are drawn once and saved; each frame only redraws the "animated" artists (video, cursors,
        # text, boxes) on top. A full redraw of 30k+ motion points takes ~250 ms; this takes a few ms.
        for a in self.cursors + [self.title, self.coach_text, self.slider.valtext]:
            a.set_animated(True)
        self.slider.drawon = False  # The slider would otherwise trigger a full redraw on every frame.
        self.background = None
        self.fig.canvas.mpl_connect("draw_event", self.on_draw)
        self.fig.canvas.mpl_connect("key_press_event", self.on_key)
        self.fig.canvas.mpl_connect("button_press_event", self.on_click)
        self.timer = self.fig.canvas.new_timer(interval=60)
        self.timer.add_callback(self.tick)

    def draw_coach_strip(self):
        ax, d = self.ax_phase, self.d
        ax.set_yticks([]); ax.set_ylim(0, 1); ax.set_xlabel("video time (s)")
        if not d.coach_frames:
            ax.text(0.5, 0.5, "no coach replay (run without --no-coach)", transform=ax.transAxes, ha="center", va="center", color="0.5", fontsize=8)
            return
        ax.set_ylabel("coach", fontsize=8)
        runs, i, frames = [], 0, d.coach_frames
        while i < len(frames):  # Merge consecutive frames in the same phase into one colored block.
            j = i
            while j + 1 < len(frames) and frames[j + 1]["phase"] == frames[i]["phase"]:
                j += 1
            end = frames[j + 1]["t"] if j + 1 < len(frames) else frames[j]["t"] + 0.2
            if frames[i]["phase"] != "idle":
                runs.append((frames[i]["t"], end, frames[i]["phase"]))
            i = j + 1
        for start, end, phase in runs:
            ax.axvspan(start, end, color=PHASE_COLORS.get(phase, "gray"), alpha=0.85, lw=0)
            if end - start > 5:
                ax.text((start + end) / 2, 0.5, phase, ha="center", va="center", fontsize=7)
        for e in d.coach_events:
            if e["kind"] == "speak":
                ax.plot(e["t"], 0.85, "v", color="tab:green", ms=6)
            elif e["kind"] == "result":
                ax.plot(e["t"], 0.2, "*", color="black", ms=9)
                ax.text(e["t"], 0.3, f' {e["outcome"]}', fontsize=7, va="bottom")

    # ---- video
    def index_of(self, t):  # Frame whose real timestamp is closest to t.
        times = self.frame_times
        i = int(np.searchsorted(times, t))
        if i == 0:
            return 0
        if i >= len(times):
            return len(times) - 1
        return i - 1 if t - times[i - 1] < times[i] - t else i

    def decode(self, idx):
        """Returns frame number idx as an RGB array (at most 1100 px wide), or None at the end of the video."""
        try:
            if self.frames is not None and 0 < idx - self.last_idx <= 45:  # Playing forward: just read on.
                for _ in range(idx - self.last_idx):
                    frame = next(self.frames)
            else:  # Jump: seek to the keyframe before it (~1 per second), then decode forward to the exact frame.
                target = self.frame_times[idx]
                self.container.seek(int(target / self.stream.time_base), stream=self.stream, backward=True)
                self.frames = self.container.decode(self.stream)
                frame = next(self.frames)
                while frame.time < target - 0.005:
                    frame = next(self.frames)
        except (StopIteration, av.error.FFmpegError):
            self.frames = None
            return None
        width = min(frame.width, 1100)
        return frame.to_ndarray(format="rgb24", width=width, height=round(frame.height * width / frame.width))

    def read_frame(self, t):
        idx = self.index_of(t)
        if idx == self.last_idx and self.frame is not None:
            return self.frame
        rgb = self.decode(idx)
        if rgb is not None:
            self.last_idx = idx
            self.frame = rgb
        else:
            self.last_idx = -10**6 # Position unknown: the next frame will seek.
        return self.frame

    def seek(self, t, from_slider=False):
        self.t = float(np.clip(t, 0, self.duration - 0.05))
        frame = self.read_frame(self.t)
        if frame is not None:
            h, w = frame.shape[:2]
            if self.image is None:
                self.image = self.ax_video.imshow(frame, animated=True)
            else:
                self.image.set_data(frame)
            self.draw_boxes(w, h)
        d = self.d
        speed, fwd = d.speed_at(self.t), d.fwd_at(self.t)
        near = [m for m in d.marks + d.events if abs(m[0] - self.t) < 1.0]
        phase, said = d.phase_at(self.t), d.speech_at(self.t)
        self.coach_text.set_text(f"coach: {phase}" + (f'\n"{said}"' if said else "") if phase else "")
        self.title.set_text(f"[{self.d.model}] t={self.t:7.2f}s   speed={speed:5.1f} m/s ({speed * MPS_TO_MPH:4.1f} mph)   fwd={fwd:+.2f} g"
                            + ("   << " + ", ".join(n for _, n in near) if near else ""))
        for c in self.cursors:
            c.set_xdata([self.t, self.t])
        if not from_slider:
            self.slider.eventson = False
            self.slider.set_val(self.t)
            self.slider.eventson = True
        self.blit()

    def on_draw(self, _event):  # After any full redraw (first show, resize, zoom): save it and put the animated artists back.
        self.background = self.fig.canvas.copy_from_bbox(self.fig.bbox)
        self.draw_animated()

    def draw_animated(self):
        for a in [self.image] + self.patches + [self.title, self.coach_text]:
            if a is not None:
                self.ax_video.draw_artist(a)
        for c in self.cursors:
            c.axes.draw_artist(c)
        self.fig.draw_artist(self.ax_slider)
        self.ax_slider.draw_artist(self.slider.valtext)  # Sits outside the slider box, so it needs its own draw.

    def blit(self):
        if self.background is None:  # Not shown yet: the first full draw will do it.
            self.fig.canvas.draw_idle()
            return
        self.fig.canvas.restore_region(self.background)
        self.draw_animated()
        self.fig.canvas.blit(self.fig.bbox)

    def draw_boxes(self, w, h):
        for patch in getattr(self, "patches", []):
            patch.remove()
        self.patches = []
        for label, conf, bx, by, bw, bh, key in self.d.detections_at(self.t):
            color, style, tag = SIGN_COLORS.get(label, "white"), "-", ""
            if label == "stop sign" and (key, round(bx, 4)) in self.d.sign_info:
                red, front = self.d.sign_info[(key, round(bx, 4))]
                tag = "" if red is None else f" red={red:.2f}"
                if not front:  # The coach ignores this box: it looks like the back of a sign.
                    color, style, label = "darkorange", "--", "back?"
                elif self.d.sign_left.get((key, round(bx, 4))):  # A front, but on the left: not for your lane.
                    color, style, label = "violet", "--", "left side"
            # Vision boxes: origin bottom-left, fractions of the frame.
            rect = Rectangle((bx * w, (1 - by - bh) * h), bw * w, bh * h, fill=False, ec=color, lw=2, ls=style, animated=True)
            self.ax_video.add_patch(rect)
            text = self.ax_video.text(bx * w, (1 - by - bh) * h - 4, f"{label} {conf:.2f} h={bh:.2f}{tag}", color=color, fontsize=8,
                                      bbox=dict(fc="black", ec="none", alpha=0.6, pad=1), animated=True)
            self.patches += [rect, text]

    # ---- interaction
    def tick(self):
        now = time.monotonic()
        if self.last_wall is not None:
            self.seek(self.t + (now - self.last_wall) * self.rate)
        self.last_wall = now

    def set_playing(self, playing):
        self.playing = playing
        self.last_wall = None
        self.timer.start() if playing else self.timer.stop()

    def on_key(self, event):
        key = event.key or ""
        step = 10 if key.startswith("shift+") else 1
        key = key.replace("shift+", "")
        if key == " ":
            self.set_playing(not self.playing)
        elif key == "left":
            self.seek(self.t - step)
        elif key == "right":
            self.seek(self.t + step)
        elif key == "up":
            self.rate = min(self.rate * 2, 8)
        elif key == "down":
            self.rate = max(self.rate / 2, 0.125)
        elif key in ("n", "p") and len(self.d.sign_t):
            times = self.d.sign_t
            # Jump between separate sightings: gaps over 3 s start a new one.
            starts = times[np.r_[True, np.diff(times) > 3.0]]
            later = starts[starts > self.t + 0.5]
            earlier = starts[starts < self.t - 0.5]
            if key == "n" and len(later):
                self.seek(later[0] - 2)
            elif key == "p" and len(earlier):
                self.seek(earlier[-1] - 2)

    def on_click(self, event):
        if event.inaxes in (self.ax_speed, self.ax_fwd, self.ax_det, self.ax_phase) and event.xdata is not None:
            self.seek(event.xdata)


def data_files(folder: Path, model: str | None):
    """(sensors file, coach file) names: the recording's own, or another model's re-detection (Scripts/run_redetect.sh)."""
    return ("sensors.csv", "coach.json") if model is None else (f"sensors_{model}.csv", f"coach_{model}.json")


def replay_coach(folder: Path, model: str | None = None):
    """Runs the real Swift coach over the recording, unless its coach file is already up to date."""
    here = Path(__file__).parent
    sensors, coach_file = data_files(folder, model)
    if model is not None and not (folder / sensors).exists():
        print(f"Re-detecting with {model} (once per drive; a few minutes)...")
        subprocess.run([str(here / "run_redetect.sh"), str(folder), model], check=True)
    sources = [folder / sensors, folder / "meta.json", here / "coach_replay.swift", here / "run_coach_replay.sh",
               here.parent / "Congressional App Challenge/Coach/StopSignCoach.swift",
               here.parent / "Congressional App Challenge/Motion/SignalFilters.swift",
               here.parent / "Congressional App Challenge/Detection/SignColor.swift"]
    out = folder / coach_file
    if out.exists() and out.stat().st_mtime >= max(p.stat().st_mtime for p in sources):
        return
    print("Replaying the coach over this drive (compiles Swift, a few seconds)...")
    subprocess.run([str(here / "run_coach_replay.sh"), str(folder), str(out), sensors], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    parser.add_argument("--no-coach", action="store_true", help="don't replay or draw the Swift StopSignCoach")
    parser.add_argument("--model", help="replay with another bundled model's detections, e.g. yolo11s_1280 (re-detected on the Mac)")
    parser.add_argument("--start", type=float, default=0.0, help="video second to start at")
    parser.add_argument("--snapshot", nargs=2, metavar=("SECONDS", "PNG"), help="render one frame to a PNG and exit")
    args = parser.parse_args()
    if args.snapshot:
        matplotlib.use("Agg")
    if not args.no_coach:
        replay_coach(args.folder, args.model)
    viewer = Viewer(args.folder, float(args.snapshot[0]) if args.snapshot else args.start, args.model)
    if args.snapshot:
        viewer.fig.savefig(args.snapshot[1], dpi=90)
        return
    plt.show()


if __name__ == "__main__":
    main()
