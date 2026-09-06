"""Regression fixtures; no app, microphone, or real log access."""

import unittest

from dictation_log_summary import parse_logs, render, summarize


def row(family, t, event):
    return f"[12:00:00.000] [INFO] {family} t={t} {event}"


class DictationLogSummaryTests(unittest.TestCase):
    def parse(self, *lines):
        return [summarize(run) for run in parse_logs(lines)]

    def test_paste_and_main_callback_are_distinct(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("ASR_BENCH", 1.1, "session=1 first_audio"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("TYPING_BENCH", 2.2, "complete totalMs=16"),
            row("OVERLAY_BENCH", 2.18, "manager finish_hide_request"),
            row("OVERLAY_BENCH", 2.24, "manager finish_hide_complete"),
            row("TYPING_BENCH", 2.4, "delivery_main_begin"),
            row("PIPELINE_SUMMARY", 2.4, "id=A outcome=inserted"),
        )[0]
        self.assertEqual(result["from_stop_ms"]["paste_done"], 200)
        self.assertEqual(result["metrics"]["overlay_after_paste_ms"], 40)
        self.assertEqual(result["metrics"]["callback_queue_ms"], 200)
        self.assertEqual(result["metrics"]["hide_duration_ms"], 60)
        self.assertEqual(result["metrics"]["start_to_pcm_ms"], 100)

    def test_empty_run_never_inherits_paste(self):
        results = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("TYPING_BENCH", 2.1, "complete"),
            row("APP_BENCH", 3, "begin_recording"),
            row("APP_BENCH", 4, "pipeline_begin id=B"),
            row("ASR_BENCH", 4.1, "session=2 final_done textChars=0"),
            row("APP_BENCH", 4.2, "pipeline_handler_return id=B"),
        )
        self.assertEqual(results[1]["outcome"], "empty")
        self.assertIsNone(results[1]["from_stop_ms"]["paste_done"])

    def test_late_id_callback_routes_to_old_run(self):
        results = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("APP_BENCH", 3, "begin_recording"),
            row("PIPELINE_SUMMARY", 3.1, "id=A outcome=inserted"),
            row("OVERLAY_BENCH", 3.2, "manager finish_hide_complete"),
            row("APP_BENCH", 4, "pipeline_begin id=B"),
        )
        self.assertEqual(results[0]["outcome"], "inserted")
        self.assertEqual(results[1]["outcome"], "incomplete")
        self.assertIsNone(results[1]["from_stop_ms"]["hidden"])

    def test_rotation_duplicates_and_restart_are_isolated(self):
        begin = row("APP_BENCH", 1, "begin_recording")
        results = self.parse(begin, begin, row("APP_BENCH", 2, "pipeline_begin id=A"),
                             "[RUN] PID=2", row("PIPELINE_SUMMARY", 3, "id=A outcome=inserted"),
                             row("APP_BENCH", 4, "pipeline_begin id=B"))
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["outcome"], "incomplete")
        self.assertTrue(results[1]["partial_start"])

    def test_incomplete_cancelled_and_untimed_markers(self):
        result = self.parse(row("APP_BENCH", 1, "begin_recording"),
                            "ASR_BENCH provider_streaming_done elapsedMs=4",
                            "Cancel shortcut pressed")[0]
        self.assertEqual(result["outcome"], "cancelled")
        self.assertIsNone(result["from_stop_ms"]["hidden"])
        self.assertIn("provider_streaming_done", render([result], details=True))

    def test_superseded_hide_is_not_reported_as_hidden(self):
        result = self.parse(row("APP_BENCH", 1, "begin_recording"),
                            row("APP_BENCH", 2, "pipeline_begin id=A"),
                            row("OVERLAY_BENCH", 2.1, "manager finish_hide_complete outcome=superseded"))[0]
        self.assertIsNone(result["from_stop_ms"]["hidden"])

    def test_internal_model_handoffs_and_context_are_separate(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("ASR_BENCH", 2.01, "session=4 capture_stop_await_begin"),
            row("ASR_BENCH", 2.05, "session=4 capture_stop_await_return"),
            row("ASR_BENCH", 2.06, "session=4 final_executor_request model=parakeet-v3 "
                "samples=80000 vocabEnabled=true vocabTerms=8"),
            row("ASR_BENCH", 2.061, "session=4 final_queue_previous_finished mainThread=false"),
            row("ASR_BENCH", 2.064, "final_executor_begin mainThread=true"),
            "ASR_BENCH provider_final_done samples=80000 audioMs=5000 elapsedMs=91 textChars=40",
            row("ASR_BENCH", 2.155, "final_executor_end"),
            row("ASR_BENCH", 2.16, "session=4 final_done samples=80000 audioMs=5000 textChars=40"),
            row("APP_BENCH", 2.162, "asr_stop_return elapsedMs=162"),
            row("APP_BENCH", 2.164, "processing_ui_requested status=Refining"),
            row("APP_BENCH", 2.165, "ai_process_call id=A provider=FluidIntelligence "
                "model=fluid-1 inputChars=40"),
            row("APP_BENCH", 2.365, "ai_process_return id=A"),
            row("APP_BENCH", 2.367, "text_ready chars=41"),
        )[0]

        self.assertEqual(result["metrics"]["capture_stop_ms"], 40)
        self.assertEqual(result["metrics"]["final_executor_hop_ms"], 3)
        self.assertEqual(result["metrics"]["asr_provider_ms"], 91)
        self.assertEqual(result["metrics"]["asr_to_ai_call_ms"], 3)
        self.assertEqual(result["metrics"]["refining_to_ai_call_ms"], 1)
        self.assertEqual(result["metrics"]["ai_processing_ms"], 200)
        self.assertEqual(result["metrics"]["ai_to_ready_ms"], 2)
        self.assertEqual(result["metrics"]["internal_stop_to_ready_ms"], 367)
        self.assertEqual(result["context"]["audio_ms"], 5000)
        self.assertEqual(result["context"]["samples"], 80000)
        self.assertEqual(result["context"]["asr_model"], "parakeet-v3")
        self.assertEqual(result["context"]["vocab_enabled"], "true")
        self.assertEqual(result["context"]["vocab_terms"], 8)
        self.assertEqual(result["context"]["ai_provider"], "FluidIntelligence")
        self.assertEqual(result["context"]["ai_model"], "fluid-1")


if __name__ == "__main__":
    unittest.main()
