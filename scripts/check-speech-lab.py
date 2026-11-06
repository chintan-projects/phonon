#!/usr/bin/env python3
"""Offline smoke test for the packaged Speech Lab, without microphone or UI access.

The attenuated clips test level sensitivity, not whispered or silent articulation.
"""
import argparse
import json
import math
import os
import queue
import signal
import struct
import subprocess
import tempfile
import threading
import time
import wave
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path(__file__).resolve().parents[1] / "bar/dist/PhononLab.app")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    fixture = app / "Contents/Resources/assets/startup.wav"
    corpus = Path.home() / "Library/Application Support/Phonon/Corpus"
    before = set(corpus.iterdir()) if corpus.exists() else set()
    report = {"network_denied": True, "microphone_used": False, "text_inserted": False,
              "purpose": "level sensitivity and integration; not a whisper or silent-speech benchmark",
              "samples": []}
    events = queue.Queue()
    with tempfile.TemporaryDirectory(prefix="phonon-lab-check-") as temp:
        work = Path(temp)
        with (args.out.with_suffix(".log")).open("w") as log:
            process = subprocess.Popen([
                "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                str(app / "Contents/Helpers/phonon"), "engine"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
                start_new_session=True,
                env=dict(os.environ, UV_OFFLINE="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                         PHONON_PROFILE_DIR=""))

            def reader():
                for line in process.stdout:
                    try:
                        events.put(json.loads(line))
                    except json.JSONDecodeError:
                        pass
                events.put({"type": "eof"})

            threading.Thread(target=reader, daemon=True).start()

            def send(**request):
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()

            def wait_for(predicate, seconds=90, expected_error=False):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    event = events.get(timeout=max(0.01, deadline - time.monotonic()))
                    if predicate(event):
                        return event
                    if event.get("type") in ("error", "eof") and not expected_error:
                        raise RuntimeError(event)
                    if event.get("type") == "stream" and event.get("state") == "error":
                        raise RuntimeError(event)
                raise TimeoutError("Engine response timed out")

            try:
                wait_for(lambda e: e.get("type") == "ready", seconds=180)
                send(cmd="lab_transcribe", id="invalid", path=str(fixture))
                rejected = wait_for(lambda e: e.get("type") == "error" and e.get("id") == "invalid",
                                    expected_error=True)
                report["invalid_id_rejected"] = "speech-lab-" in rejected.get("msg", "")
                with wave.open(str(fixture), "rb") as source:
                    pcm = source.readframes(source.getnframes())
                    original = struct.unpack("<" + "h" * (len(pcm) // 2), pcm)
                for index, (name, multiplier) in enumerate([
                    ("normal sample", 1), ("sample attenuated 20 dB", 0.1),
                    ("attenuated sample plus 12 dB gain", 0.1 * 10 ** (12 / 20)),
                ]):
                    clip = work / f"{index}.wav"
                    values = [round(value * multiplier) for value in original]
                    with wave.open(str(clip), "wb") as output:
                        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                        output.writeframes(struct.pack("<" + "h" * len(values), *values))
                    ident = f"speech-lab-check-{index}"
                    started = time.monotonic()
                    send(cmd="lab_transcribe", id=ident, path=str(clip))
                    raw = wait_for(lambda e, ident=ident: e.get("id") == ident and e.get("kind") == "asr")
                    send(cmd="polish", id=ident, text=raw["text"], local_history=False)
                    rewritten = wait_for(lambda e, ident=ident: e.get("id") == ident and e.get("kind") == "polish")
                    rms = math.sqrt(sum(value * value for value in values) / len(values)) / 32768
                    report["samples"].append({
                        "condition": name, "raw": raw["text"], "refined": rewritten["text"],
                        "input_rms_dbfs": 20 * math.log10(max(rms, 1e-9)),
                        "asr_ms": raw.get("seconds", 0) * 1000,
                        "refiner_ms": rewritten.get("latency_ms"),
                        "batch_ms": (time.monotonic() - started) * 1000,
                    })
                after = set(corpus.iterdir()) if corpus.exists() else set()
                report["corpus_unchanged"] = before == after
                report["success"] = report["invalid_id_rejected"] and report["corpus_unchanged"] and all(
                    sample["raw"].strip() and sample["refined"].strip() for sample in report["samples"])
            except (OSError, ValueError, RuntimeError, TimeoutError, queue.Empty, struct.error) as error:
                report.update(success=False, error=repr(error))
            finally:
                if process.poll() is None:
                    try:
                        send(cmd="shutdown")
                        process.wait(timeout=15)
                    except (BrokenPipeError, subprocess.TimeoutExpired):
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=10)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
