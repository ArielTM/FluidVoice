#!/usr/bin/env python3
"""Read-only, standard-library summary of recent FluidVoice dictation timings.

Usage: python3 scripts/dictation_log_summary.py --last 5 [--details] [--json]
Reads Fluid.log.1 then Fluid.log. Explicit paths are accepted with --log PATH.
No recording, playback, app activation, or file writes are performed.
"""

import argparse
import json
import re
import statistics
from pathlib import Path


MARKER = re.compile(r"\b(APP_BENCH|ASR_BENCH|OVERLAY_BENCH|TYPING_BENCH|HISTORY_BENCH|PIPELINE_SUMMARY)\b(.*)")
FIELD = re.compile(r"(?:^|\s)(\w+)=([^\s]+)")
WALL = re.compile(r"^\[([\d:.]+)\]")


def parse_logs(lines):
    """Group at recording boundaries; never reuse a previous run's timings.

    Late ID-bearing callbacks are routed back to their original pipeline.
    Unlabelled tail events after a rapid restart cannot be safely attributed;
    keep them in the timeline but exclude pre-stop events from stop metrics.
    App restarts reset correlation even when IDs/session numbers are reused.
    """
    runs, by_id, current, seen = [], {}, None, set()
    for line in lines:
        if line in seen:
            continue  # overlapping rotated snapshots
        seen.add(line)
        if line.startswith("[RUN]"):
            current, by_id = None, {}
            continue
        match = MARKER.search(line)
        if not match:
            if current and ("Cancel shortcut pressed" in line or "stopWithoutTranscription" in line):
                current["cancelled"] = True
            continue
        family, body = match.groups()
        fields = dict(FIELD.findall(body))
        words = [part for part in body.split() if "=" not in part]
        name = " ".join(words) if family != "PIPELINE_SUMMARY" else "summary"
        try:
            timestamp = float(fields["t"])
        except (KeyError, ValueError):
            timestamp = None
        event = {"family": family, "name": name, "t": timestamp,
                 "fields": {k: v for k, v in fields.items() if k != "t"}}
        if family == "APP_BENCH" and name == "begin_recording":
            wall = WALL.match(line)
            current = {"id": None, "time": wall.group(1) if wall else "?",
                       "events": [], "cancelled": False, "partial_start": False}
            runs.append(current)
        if family == "APP_BENCH" and name == "pipeline_begin":
            if current is None or current["id"] is not None:
                current = {"id": None, "time": WALL.match(line).group(1) if WALL.match(line) else "?",
                           "events": [], "cancelled": False, "partial_start": True}
                runs.append(current)
            current["id"] = fields.get("id")
            if current["id"]:
                by_id[current["id"]] = current
        target = by_id.get(fields.get("id"), current)
        # An unknown callback ID must not contaminate a newer recording.
        if fields.get("id") and family in ("APP_BENCH", "PIPELINE_SUMMARY") and name != "pipeline_begin":
            target = by_id.get(fields["id"])
        if target is not None:
            target["events"].append(event)
    return runs


def summarize(run):
    events = run["events"]

    def find(family, names, after=None, last=False):
        matches = [e for e in events if e["family"] == family and e["name"] in names
                   and not (e["name"] == "manager finish_hide_complete"
                            and e["fields"].get("outcome") == "superseded")
                   and e["t"] is not None and (after is None or e["t"] >= after)]
        return (matches[-1] if last else matches[0]) if matches else None

    def find_with_field(family, names, key, value, after=None):
        return next((e for e in events if e["family"] == family and e["name"] in names
                     and e["fields"].get(key) == value and e["t"] is not None
                     and (after is None or e["t"] >= after)), None)

    def find_untimed(family, names, after_index=0):
        return next((e for e in events[after_index:]
                     if e["family"] == family and e["name"] in names), None)

    def time(event):
        return event["t"] if event else None

    def delta(end, start):
        return round((end - start) * 1000, 1) if end is not None and start is not None else None

    start = time(find("APP_BENCH", {"begin_recording"}))
    stop = time(find("APP_BENCH", {"stop_path_enter"}))
    if stop is None:
        stop = time(find("APP_BENCH", {"pipeline_begin"}))
    # Do not accidentally match recording-stage events as completion events.
    after = stop if stop is not None else float("inf")
    phases = {
        "asr_stop_call": time(find("APP_BENCH", {"asr_stop_call"}, after)),
        "capture_stop_begin": time(find("ASR_BENCH", {"capture_stop_await_begin"}, after)),
        "capture_stop_return": time(find("ASR_BENCH", {"capture_stop_await_return"}, after)),
        "final_queue_ready": time(find("ASR_BENCH", {"final_queue_previous_finished"}, after)),
        "final_executor_begin": time(find("ASR_BENCH", {"final_executor_begin"}, after)),
        "final_executor_end": time(find("ASR_BENCH", {"final_executor_end"}, after)),
        "final_asr": time(find("ASR_BENCH", {"final_done"}, after)),
        "asr_return": time(find("APP_BENCH", {"asr_stop_return"}, after)),
        "refining_requested": time(find_with_field(
            "APP_BENCH", {"processing_ui_requested"}, "status", "Refining", after
        )),
        "ai_call": time(find("APP_BENCH", {"ai_process_call"}, after)),
        "ai_return": time(find("APP_BENCH", {"ai_process_return"}, after)),
        "text_ready": time(find("APP_BENCH", {"text_ready"}, after)),
        "paste_dispatch": time(find("TYPING_BENCH", {"asr_type_dispatched"}, after)),
        "paste_done": time(find("TYPING_BENCH", {"complete"}, after)),
        "hide_request": time(find("OVERLAY_BENCH", {"manager finish_hide_request"}, after)),
        "alpha_return": time(find("OVERLAY_BENCH", {"bottom_hide_alpha_return"}, after)),
        "order_out_return": time(find("OVERLAY_BENCH", {"bottom_hide_order_out_return"}, after)),
        "hidden": time(find("OVERLAY_BENCH", {"manager finish_hide_complete"}, after)),
        "delivery_callback": time(find("TYPING_BENCH", {"delivery_main_begin"}, after)),
        "handler_return": time(find("APP_BENCH", {"pipeline_handler_return"}, after)),
        "cleanup": time(find("OVERLAY_BENCH", {"bottom_hide_immediate_cleanup_complete",
                                               "notch hide_immediate_cleanup_complete"}, after, last=True)),
    }
    final = find("ASR_BENCH", {"final_done"}, after)
    stop_event_index = next((index for index, event in enumerate(events)
                             if event["t"] == stop and event["family"] == "APP_BENCH"), 0)
    provider_final = find_untimed("ASR_BENCH", {"provider_final_done"}, stop_event_index)
    final_request = find("ASR_BENCH", {"final_executor_request"}, after)
    ai_call = find("APP_BENCH", {"ai_process_call"}, after)
    summary = find("PIPELINE_SUMMARY", {"summary"}, after)
    if run["cancelled"]:
        outcome = "cancelled"
    elif summary:
        outcome = summary["fields"].get("outcome", "finished")
    elif final and final["fields"].get("textChars") == "0" and phases["handler_return"] is not None:
        outcome = "empty"
    elif phases["paste_done"] is not None:
        outcome = "paste done; callback missing"
    else:
        outcome = "incomplete"
    tail = delta(phases["hidden"], phases["paste_done"])
    try:
        provider_final_ms = float(provider_final["fields"]["elapsedMs"]) if provider_final else None
    except (KeyError, ValueError):
        provider_final_ms = None
    metrics = {
        "start_to_pcm_ms": delta(time(find("ASR_BENCH", {"first_audio"})), start),
        "start_to_overlay_ms": delta(time(find("OVERLAY_BENCH", {"bottom_visible", "bottom_order_front"})), start),
        "recording_ms": delta(stop, start),
        "hide_duration_ms": delta(phases["hidden"], phases["hide_request"]),
        "overlay_after_paste_ms": tail,
        "callback_queue_ms": delta(phases["delivery_callback"], phases["paste_done"]),
        "capture_stop_ms": delta(phases["capture_stop_return"], phases["capture_stop_begin"]),
        "final_executor_hop_ms": delta(phases["final_executor_begin"], phases["final_queue_ready"]),
        "final_executor_ms": delta(phases["final_executor_end"], phases["final_executor_begin"]),
        "asr_provider_ms": provider_final_ms,
        "asr_to_ai_call_ms": delta(phases["ai_call"], phases["asr_return"]),
        "refining_to_ai_call_ms": delta(phases["ai_call"], phases["refining_requested"]),
        "ai_processing_ms": delta(phases["ai_return"], phases["ai_call"]),
        "ai_to_ready_ms": delta(phases["text_ready"], phases["ai_return"]),
        "internal_stop_to_ready_ms": delta(phases["text_ready"], stop),
    }
    context = {
        "audio_ms": float(final["fields"]["audioMs"]) if final and final["fields"].get("audioMs") else None,
        "samples": int(final["fields"]["samples"]) if final and final["fields"].get("samples") else None,
        "text_chars": int(final["fields"]["textChars"]) if final and final["fields"].get("textChars") else None,
        "asr_model": final_request["fields"].get("model") if final_request else None,
        "vocab_enabled": final_request["fields"].get("vocabEnabled") if final_request else None,
        "vocab_terms": int(final_request["fields"]["vocabTerms"])
        if final_request and final_request["fields"].get("vocabTerms") else None,
        "ai_provider": ai_call["fields"].get("provider") if ai_call else None,
        "ai_model": ai_call["fields"].get("model") if ai_call else None,
    }
    return {"id": run["id"], "time": run["time"], "outcome": outcome,
            "partial_start": run["partial_start"], "stop_uptime": stop,
            "from_stop_ms": {key: delta(value, stop) for key, value in phases.items()},
            "metrics": metrics, "context": context, "events": events}


def render(rows, details=False):
    def fmt(value):
        return "—" if value is None else f"{value:.1f}"

    lines = ["# Recent dictations", "",
             "Times in ms from stop-handler entry (not physical key-down). — = not logged / not applicable.",
             "Hidden = window API returned, not measured pixels. Paste = injection completed, not target-app rendering.", "",
             "| Time / ID | Outcome | ASR | Ready | Paste | Hidden | Hide cost | Hidden − paste | Callback queue | Cleanup |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        p, m = row["from_stop_ms"], row["metrics"]
        values = [p["asr_return"], p["text_ready"], p["paste_done"], p["hidden"],
                  m["hide_duration_ms"], m["overlay_after_paste_ms"], m["callback_queue_ms"], p["cleanup"]]
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | {row['outcome']} | " + " | ".join(map(fmt, values)) + " |")
    tails = [r["metrics"]["overlay_after_paste_ms"] for r in rows if r["metrics"]["overlay_after_paste_ms"] is not None]
    if tails:
        lines += ["", f"Overlay API returned after paste in {sum(t > 0 for t in tails)}/{len(tails)} measured runs. "
                  f"Hidden − paste: median {statistics.median(tails):.1f} ms, worst {max(tails):.1f} ms "
                  "(negative = hidden first)."]
    lines += ["", "Cleanup is the last logged overlay-cleanup marker, not proof all background work has finished.",
              "Unlabelled events are bounded by recording starts; rapid-overlap tails cannot be reliably attributed."]
    lines += ["", "## Internal model handoffs", "",
              "These exclude focus restoration, paste injection, and overlay dismissal.", "",
              "| Time / ID | Capture stop | ASR hop | ASR provider | ASR→AI | Refining→AI | AI process | AI→ready | Stop→ready |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        m = row["metrics"]
        values = [m["capture_stop_ms"], m["final_executor_hop_ms"], m["asr_provider_ms"],
                  m["asr_to_ai_call_ms"], m["refining_to_ai_call_ms"], m["ai_processing_ms"],
                  m["ai_to_ready_ms"], m["internal_stop_to_ready_ms"]]
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    lines += ["", "ASR provider and AI process are measured model-call envelopes; all other columns are glue/handoff time."]
    if details:
        for row in rows:
            context = row["context"]
            lines += ["", f"## {row['time']} / {row['id'] or 'no pipeline ID'}", "",
                      f"Start → first PCM: {fmt(row['metrics']['start_to_pcm_ms'])} ms; "
                      f"start → overlay: {fmt(row['metrics']['start_to_overlay_ms'])} ms; "
                      f"start → stop: {fmt(row['metrics']['recording_ms'])} ms.",
                      f"Audio: {fmt(context['audio_ms'])} ms / {context['samples'] or '—'} samples; "
                      f"ASR: {context['asr_model'] or '—'}; vocab: {context['vocab_enabled'] or '—'} "
                      f"({context['vocab_terms'] if context['vocab_terms'] is not None else '—'} terms); "
                      f"AI: {context['ai_provider'] or '—'} / {context['ai_model'] or '—'}; "
                      f"text: {context['text_chars'] or '—'} chars.", "",
                      "| From stop (ms) | Event | Fields |", "|---:|---|---|"]
            for e in row["events"]:
                relative = (e["t"] - row["stop_uptime"]) * 1000 if e["t"] is not None and row["stop_uptime"] is not None else None
                fields = " ".join(f"{k}={v}" for k, v in e["fields"].items()).replace("|", "\\|")
                lines.append(f"| {fmt(relative)} | {e['family']} {e['name']} | {fields} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last", type=int, default=5, help="number of recent recordings (default: 5)")
    parser.add_argument("--log", type=Path, action="append", help="explicit log; repeat oldest first")
    parser.add_argument("--details", action="store_true", help="include every benchmark marker from start through tail")
    parser.add_argument("--json", action="store_true", help="machine-readable metrics and events")
    args = parser.parse_args()
    if args.last < 1:
        parser.error("--last must be positive")
    base = Path.home() / "Library/Logs/Fluid/Fluid.log"
    paths = args.log if args.log else [p for p in (base.with_name("Fluid.log.1"), base) if p.exists()]
    if not paths:
        parser.error("no FluidVoice logs found; supply --log PATH")
    try:
        # Read-only snapshots. The next invocation picks up any newly appended tail.
        lines = [line for path in paths for line in path.read_text(errors="replace").splitlines()]
    except OSError as error:
        parser.error(str(error))
    rows = [summarize(run) for run in parse_logs(lines)[-args.last:]]
    if not rows:
        parser.error("no recording/pipeline start markers found")
    print(json.dumps(rows, indent=2) if args.json else render(rows, args.details))


if __name__ == "__main__":
    main()
