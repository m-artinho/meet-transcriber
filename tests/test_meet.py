"""Unit tests for the pure helpers in the `meet` CLI.

`meet` has no .py extension, so it is loaded the same way as in CLAUDE.md:
SourceFileLoader + spec_from_loader. Run from the repo root:

    python3 -m unittest discover tests
"""

import datetime as dt
import importlib.machinery
import importlib.util
import os
import struct
import tempfile
import unittest
import wave
from pathlib import Path


def load_meet():
    path = str(Path(__file__).resolve().parent.parent / "meet")
    loader = importlib.machinery.SourceFileLoader("meet", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("meet", loader))
    loader.exec_module(module)
    return module


meet = load_meet()


def seg(text, start=0.0, end=1.0, speaker="Me"):
    return {"text": text, "start": start, "end": end, "speaker": speaker}


def pcm_wav(payload, data_size=None, riff_size=None):
    """16 kHz mono 16-bit WAV. data_size/riff_size default to a consistent header."""
    if data_size is None:
        data_size = len(payload)
    fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
    body = b"fmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", data_size) + payload
    if riff_size is None:
        riff_size = len(body)
    return b"RIFF" + struct.pack("<I", riff_size) + b"WAVE" + body


class ParseValueTests(unittest.TestCase):
    def test_quotes_are_kept_verbatim(self):
        self.assertEqual(meet.parse_value('"hello"'), "hello")
        self.assertEqual(meet.parse_value("'hello'"), "hello")
        self.assertEqual(meet.parse_value('"hello # not a comment"'), "hello # not a comment")
        self.assertEqual(meet.parse_value('"value with "inner" quote"'), 'value with "inner" quote')
        self.assertEqual(meet.parse_value("  'keep  spaces'  "), "keep  spaces")
        self.assertEqual(meet.parse_value('""'), "")
        self.assertEqual(meet.parse_value('"hello'), "hello")  # no closing quote

    def test_unquoted_value_stops_at_hash_comment(self):
        self.assertEqual(meet.parse_value("hello # comment"), "hello")
        self.assertEqual(meet.parse_value("hello#notcomment"), "hello#notcomment")
        self.assertEqual(meet.parse_value("  spaced  "), "spaced")
        self.assertEqual(meet.parse_value("0"), "0")
        self.assertEqual(meet.parse_value(""), "")

    def test_truthy(self):
        for value in ("1", "true", "YES", "on", " true ", 1, True):
            self.assertTrue(meet.truthy(value), repr(value))
        for value in ("0", "false", "no", "off", "", "2", None):
            self.assertFalse(meet.truthy(value), repr(value))


class SlugAndTagTests(unittest.TestCase):
    def test_slugify(self):
        self.assertEqual(meet.slugify("Pricing sync"), "pricing-sync")
        self.assertEqual(meet.slugify("Migração"), "migracao")
        self.assertEqual(meet.slugify("São Paulo Q&A 2026"), "sao-paulo-q-a-2026")
        self.assertEqual(meet.slugify("Hello!! World"), "hello-world")
        self.assertEqual(meet.slugify("  multiple   spaces  "), "multiple-spaces")
        self.assertEqual(meet.slugify(""), "")
        self.assertEqual(meet.slugify("---"), "")
        self.assertEqual(meet.slugify("hello-world-this-is-a-very-long-title", 20), "hello-world-this-is")

    def test_tagify_keeps_accents_and_drops_numeric(self):
        self.assertEqual(meet.tagify("Migração"), "migração")
        self.assertEqual(meet.tagify("team/q4"), "team/q4")
        self.assertEqual(meet.tagify("  hello world "), "hello-world")
        self.assertEqual(meet.tagify("Q4!"), "q4")
        self.assertEqual(meet.tagify("123"), "")
        self.assertEqual(meet.tagify("42-7"), "")
        self.assertEqual(meet.tagify("---"), "")

    def test_parse_tags(self):
        self.assertEqual(meet.parse_tags("pricing, q4"), ["pricing", "q4"])
        self.assertEqual(meet.parse_tags("#pricing #q4"), ["pricing", "q4"])
        self.assertEqual(meet.parse_tags("pricing, pricing, q4"), ["pricing", "q4"])
        self.assertEqual(meet.parse_tags("#Migração, 42"), ["migração"])
        self.assertEqual(meet.parse_tags("  #one,#two  three "), ["one", "two", "three"])
        self.assertEqual(meet.parse_tags(None), [])
        self.assertEqual(meet.parse_tags(""), [])


class TimeTests(unittest.TestCase):
    def test_hms(self):
        self.assertEqual(meet.hms(0), "00:00:00")
        self.assertEqual(meet.hms(61), "00:01:01")
        self.assertEqual(meet.hms(3661), "01:01:01")
        self.assertEqual(meet.hms(59.9), "00:00:59")
        self.assertEqual(meet.hms(-5), "00:00:00")

    def test_parse_time(self):
        self.assertIsNone(meet.parse_time(""))
        self.assertIsNone(meet.parse_time(None))
        naive = meet.parse_time("2026-10-16T14:30:00")
        self.assertEqual(naive, dt.datetime(2026, 10, 16, 14, 30, 0))
        self.assertIsNone(naive.tzinfo)
        offset = meet.parse_time("2026-10-16T11:30:00-03:00")
        self.assertEqual(offset, dt.datetime(2026, 10, 16, 11, 30, tzinfo=dt.timezone(dt.timedelta(hours=-3))))

    def test_parse_time_trailing_z(self):
        # Recorder timestamps at UTC+0 end in Z. Python 3.9 fromisoformat rejects that.
        got = meet.parse_time("2026-10-16T14:30:00Z")
        self.assertEqual(got, dt.datetime(2026, 10, 16, 14, 30, tzinfo=dt.timezone.utc))


class HallucinationTests(unittest.TestCase):
    def assert_junk(self, lines):
        for line in lines:
            with self.subTest(line=line):
                self.assertTrue(meet.is_hallucination(line))

    def assert_kept(self, lines):
        for line in lines:
            with self.subTest(line=line):
                self.assertFalse(meet.is_hallucination(line))

    def test_real_speech_that_mentions_an_outro_word_is_kept(self):
        self.assert_kept([
            "If customers subscribe annually we give 20% off.",
            "We should subscribe the team to the newsletter tomorrow.",
            "If they subscribe, we win.",
            "Thanks for watching the demo, the numbers are in.",
            "Thank you for watching the numbers with me.",
            "Obrigado por assistir a apresentação de hoje.",
            "As legendas pela comunidade estão erradas neste trecho.",
            "I found the file on amara.org yesterday.",
            "See you next time, subscribe",
            "subscribed",
            "Please unsubscribe from that list.",
            "hello [Music] there",
            "[Music] extra",
        ])

    def test_outro_junk_lines_are_dropped(self):
        self.assert_junk([
            "Thanks for watching",
            "Thanks for watching!",
            "thanks for watching.",
            "Thank you for watching",
            "Obrigado por assistir",
            "Obrigada por assistir.",
            "Please subscribe",
            "Subscribe",
            "Subscribe!",
            "Subscribe to my channel",
            "Don't forget to subscribe",
            "Like and subscribe",
            "Inscreva-se",
            "Inscreva-se no canal",
            "Por favor, inscreva-se",
            "Legendas pela comunidade",
            "Legendas pela comunidade Amara.org",
            "Subtitles by the Amara.org community",
            "www.amara.org",
            "amara.org",
            "Thanks for watching! Please subscribe",
        ])

    def test_noise_markers_are_dropped(self):
        self.assert_junk(["[Music]", "[BLANK_AUDIO]", "(música)", "[Applause]", " (music) "])


class CollapseRepeatsTests(unittest.TestCase):
    def texts(self, items):
        return [s["text"] for s in meet.collapse_repeats([seg(t, i, i + 0.5) for i, t in enumerate(items)])]

    def test_consecutive_duplicate_dropped_even_when_short(self):
        self.assertEqual(self.texts(["ok", "ok"]), ["ok"])
        self.assertEqual(self.texts(["Hello!", "hello"]), ["Hello!"])
        self.assertEqual(self.texts(["Yes.", "yes"]), ["Yes."])

    def test_short_line_can_repeat_later(self):
        self.assertEqual(self.texts(["ok", "other", "ok"]), ["ok", "other", "ok"])

    def test_long_line_dropped_on_third_occurrence(self):
        line = "one two three four"
        self.assertEqual(self.texts([line, "x", line, "y", line]), [line, "x", line, "y"])

    def test_consecutive_long_line_dropped_on_the_second(self):
        line = "same words here now"
        self.assertEqual(self.texts([line, line]), [line])


class BleedTests(unittest.TestCase):
    def test_long_echo_run_is_removed_and_the_rest_kept(self):
        text = meet.remove_echoed_words(
            "hello there can everyone hear me yes loud and clear",
            "yes loud and clear thanks",
        )
        self.assertEqual(text, "hello there can everyone hear me")

    def test_segment_that_is_only_an_echo_is_dropped(self):
        self.assertEqual(
            meet.remove_echoed_words(
                "yes loud and clear thanks so much",
                "yes loud and clear thanks so much everyone",
            ),
            "",
        )

    def test_mostly_echoed_segment_is_dropped(self):
        self.assertEqual(
            meet.remove_echoed_words("yes ok sure", "yes ok sure absolutely"),
            "",
        )
        self.assertEqual(
            meet.remove_echoed_words("alpha beta gamma delta epsilon", "gamma delta epsilon zeta"),
            "",
        )

    def test_different_words_and_reordered_words_stay(self):
        self.assertEqual(
            meet.remove_echoed_words("totally different words here", "nothing in common at all really"),
            "totally different words here",
        )
        self.assertEqual(
            meet.remove_echoed_words("can you hear me yes", "yes I can hear you"),
            "can you hear me yes",
        )

    def test_drop_bleed_removes_echo_and_quiet_overlap(self):
        me = [
            seg("I think we should start", 0, 2),
            seg("yes loud and clear thanks", 10, 12),
            seg("faint overlap words", 20, 22),
            seg("normal speech alone", 30, 32),
        ]
        them = [
            seg("yes loud and clear thanks everyone", 10, 12, "Them"),
            seg("they are talking over this", 20, 22, "Them"),
        ]
        levels = {0: 0.2, 10: 0.2, 20: 0.05, 30: 0.2}
        kept = meet.drop_bleed(me, them, lambda s: levels[s["start"]])
        self.assertEqual([s["text"] for s in kept], ["I think we should start", "normal speech alone"])

    def test_loud_overlap_that_is_not_an_echo_stays(self):
        me = [
            seg("my own words here", 0, 2),
            seg("loud overlap reply", 5, 7),
        ]
        them = [seg("they talk now please", 5, 7, "Them")]
        kept = meet.drop_bleed(me, them, lambda s: 0.2)
        self.assertEqual([s["text"] for s in kept], ["my own words here", "loud overlap reply"])

    def test_quiet_overlap_stays_when_there_is_no_clean_reference(self):
        me = [seg("this is my own sentence", 0, 1)]
        them = [seg("completely different words from them", 0, 1, "Them")]
        kept = meet.drop_bleed(me, them, lambda s: 0.01)
        self.assertEqual([s["text"] for s in kept], ["this is my own sentence"])

    def test_echo_near_the_segment_is_removed_and_far_echo_is_not(self):
        me = [seg("yes loud and clear thanks", 0, 1)]
        near = [seg("yes loud and clear thanks", 1.5, 3, "Them")]
        far = [seg("yes loud and clear thanks", 30, 32, "Them")]
        self.assertEqual(meet.drop_bleed(me, near, lambda s: 0.2), [])
        self.assertEqual(
            [s["text"] for s in meet.drop_bleed(list(me), far, lambda s: 0.2)],
            ["yes loud and clear thanks"],
        )


class LanguageTests(unittest.TestCase):
    def test_stopwords_and_whisper_langs(self):
        segs = [
            seg("não sei se você está bem"),
            seg("the meeting is about the budget and we will review it"),
            seg("we should talk about our plan"),
            seg("xyzzy plugh"),
        ]
        self.assertEqual(meet.detect_languages(segs, ["de", "en"]), ["en", "pt", "de"])

    def test_one_language_and_whisper_only(self):
        self.assertEqual(meet.detect_languages([seg("não sei se você está bem")], []), ["pt"])
        self.assertEqual(meet.detect_languages([], ["pt"]), ["pt"])
        self.assertEqual(meet.detect_languages([], [None, ""]), [])
        self.assertEqual(meet.detect_languages([], ["en", "en"]), ["en"])


class MarkdownTests(unittest.TestCase):
    def test_build_body_joins_sorts_and_marks_time(self):
        body = meet.build_body([
            seg("Later", 31, 32, "Me"),
            seg("Hello", 0, 1, "Me"),
            seg("there", 1.2, 2, "Me"),
            seg("Fine", 3, 4, "Them"),
        ])
        self.assertEqual(body, (
            "**[00:00:00]**\n"
            "\n"
            "**Me:** Hello there\n"
            "\n"
            "**Them:** Fine\n"
            "\n"
            "**[00:00:31]**\n"
            "\n"
            "**Me:** Later\n"
        ))

    def test_build_body_gap_and_marker_boundaries(self):
        joined = meet.build_body([seg("A", 0, 1, "Me"), seg("B", 2.9, 4, "Me")])
        split = meet.build_body([seg("A", 0, 1, "Me"), seg("B", 3.0, 4, "Me")])
        self.assertIn("**Me:** A B\n", joined)
        self.assertNotIn("**Me:** A B\n", split)
        same_block = meet.build_body([seg("A", 0, 1, "Me"), seg("B", 29.9, 31, "Them")])
        new_block = meet.build_body([seg("A", 0, 1, "Me"), seg("B", 30, 31, "Them")])
        self.assertNotIn("**[00:00:29]**", same_block)
        self.assertIn("**[00:00:30]**", new_block)
        self.assertEqual(meet.build_body([]), "_No speech detected._\n")

    def test_render_markdown_matches_the_transcript_shape(self):
        info = {"title": "Pricing sync", "initiative": "pricing-sync", "tags": ["pricing", "q4"]}
        started = dt.datetime(2026, 10, 16, 14, 30, 0)
        ended = dt.datetime(2026, 10, 16, 15, 2, 14)
        segs = [
            seg("Olá pessoal, can everyone hear me?", 0, 2, "Me"),
            seg("Yes, loud and clear.", 3, 5, "Them"),
        ]
        self.assertEqual(meet.render_markdown(info, started, ended, segs, ["pt", "en"]), (
            "---\n"
            'title: "Pricing sync"\n'
            "date: 2026-10-16\n"
            'start_time: "14:30"\n'
            'end_time: "15:02"\n'
            'duration: "00:32:14"\n'
            "initiative: pricing-sync\n"
            "language: [pt, en]\n"
            "tags: [pricing, q4]\n"
            "source: local-recording\n"
            "---\n"
            "\n"
            "# Pricing sync\n"
            "\n"
            "#pricing #q4\n"
            "\n"
            "**[00:00:00]**\n"
            "\n"
            "**Me:** Olá pessoal, can everyone hear me?\n"
            "\n"
            "**Them:** Yes, loud and clear.\n"
        ))
        self.assertEqual(meet.output_name(info, started), "2026-10-16_1430_pricing-sync")

    def test_render_markdown_variants(self):
        started = dt.datetime(2026, 10, 16, 14, 30, 0)
        ended = dt.datetime(2026, 10, 16, 15, 2, 14)
        empty = meet.render_markdown({"name": "Standup", "initiative": "standup"}, started, ended, [], [])
        self.assertIn('title: "Standup"\n', empty)
        self.assertIn("language: unknown\n", empty)
        self.assertIn("tags: []\n", empty)
        self.assertNotIn("#standup", empty)
        self.assertTrue(empty.endswith("_No speech detected._\n"))

        one = meet.render_markdown({"initiative": "x", "tags": ["a", "a", "b"]}, started, ended, [], ["en"])
        self.assertIn("language: en\n", one)
        self.assertIn("tags: [a, b]\n", one)
        self.assertIn("#a #b\n", one)

        quoted = meet.render_markdown({"title": 'Say "hi"', "initiative": "say-hi"}, started, ended, [], ["en"])
        self.assertIn('title: "Say \\"hi\\""\n', quoted)
        self.assertIn('# Say "hi"\n', quoted)


class WriteAtomicTests(unittest.TestCase):
    def test_writes_utf8_and_disambiguates_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            inbox = Path(tmp) / "nested" / "inbox"
            first = meet.write_atomic(inbox, "note", "café — já\n")
            second = meet.write_atomic(inbox, "note", "second")
            third = meet.write_atomic(inbox, "note", "third")
            self.assertEqual([first.name, second.name, third.name], ["note.md", "note-2.md", "note-3.md"])
            self.assertEqual(first.read_text(encoding="utf-8"), "café — já\n")
            self.assertEqual(first.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(inbox.glob(".*")), [])
            self.assertTrue(inbox.is_dir())

    def test_does_not_follow_a_symlink_or_overwrite_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            secret = tmp / "secret"
            secret.write_text("keep")
            inbox = tmp / "inbox"
            inbox.mkdir()
            tmp_link = inbox / f".note.md.{os.getpid()}.tmp"
            tmp_link.symlink_to(secret)
            (inbox / "note.md").symlink_to(secret)
            written = meet.write_atomic(inbox, "note", "body\n")
            self.assertEqual(written.name, "note-2.md")
            self.assertEqual(written.read_text(encoding="utf-8"), "body\n")
            self.assertEqual(written.stat().st_mode & 0o777, 0o600)
            self.assertEqual(secret.read_text(encoding="utf-8"), "keep")
            self.assertFalse(tmp_link.exists())


class RepairWavTests(unittest.TestCase):
    def test_repairs_data_and_riff_sizes(self):
        payload = b"\x01\x00" * 100
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "mic.wav"
            path.write_bytes(pcm_wav(payload, data_size=0, riff_size=0))
            meet.repair_wav(path)
            blob = path.read_bytes()
            self.assertEqual(struct.unpack_from("<I", blob, 40)[0], len(payload))
            self.assertEqual(struct.unpack_from("<I", blob, 4)[0], len(blob) - 8)
            with wave.open(str(path)) as handle:
                self.assertEqual(handle.getnframes(), 100)
                self.assertEqual(handle.readframes(100), payload)

    def test_leaves_a_consistent_or_non_wav_file_alone(self):
        payload = b"\x01\x00" * 10
        with tempfile.TemporaryDirectory() as tmp:
            ok = Path(tmp) / "ok.wav"
            raw = pcm_wav(payload)
            ok.write_bytes(raw)
            meet.repair_wav(ok)
            self.assertEqual(ok.read_bytes(), raw)

            riff_only = Path(tmp) / "riff.wav"
            raw_riff = pcm_wav(payload, riff_size=1)
            riff_only.write_bytes(raw_riff)
            meet.repair_wav(riff_only)
            self.assertEqual(riff_only.read_bytes(), raw_riff)

            other = Path(tmp) / "nope.bin"
            other.write_bytes(b"not a wav!!!!")
            meet.repair_wav(other)
            self.assertEqual(other.read_bytes(), b"not a wav!!!!")

            short = Path(tmp) / "short.bin"
            short.write_bytes(b"RIFF")
            meet.repair_wav(short)
            self.assertEqual(short.read_bytes(), b"RIFF")


class PrivacyTests(unittest.TestCase):
    def test_recorder_command_is_exact(self):
        binary = "/Users/me/meet.release/bin/meet-capture"
        self.assertTrue(meet.is_recorder_command(binary, binary))
        self.assertTrue(meet.is_recorder_command(binary + " /tmp/rec dir", binary))
        self.assertTrue(meet.is_recorder_command("  " + binary + "  ", binary))
        self.assertFalse(meet.is_recorder_command("vim " + binary, binary))
        self.assertFalse(meet.is_recorder_command("pgrep -f " + binary, binary))
        self.assertFalse(meet.is_recorder_command(binary + "-evil /tmp", binary))
        self.assertFalse(meet.is_recorder_command("", binary))

    def test_this_process_is_not_the_recorder(self):
        self.assertFalse(meet.is_our_recorder(os.getpid()))

    def test_recording_id_cannot_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = tmp / "recordings"
            root.mkdir()
            outside = tmp / "outside"
            outside.mkdir()
            (outside / "info.json").write_text("{}")
            good = root / "2026-10-16_120000_demo"
            good.mkdir()
            (good / "info.json").write_text("{}")
            (root / "linked").symlink_to(outside)
            old = meet.RECORDINGS
            meet.RECORDINGS = root
            try:
                self.assertEqual(meet.recording_from_id("2026-10-16_120000_demo"), good.resolve())
                self.assertEqual(meet.recording_from_id("missing"), (root / "missing").resolve())
                for bad in ("../outside", "..", ".", "/etc", "nested/id", "x/../../outside", "", "linked"):
                    self.assertIsNone(meet.recording_from_id(bad), bad)
                self.assertEqual(meet.recording_dirs(), [good.resolve()])
                self.assertIsNone(meet.resolve_recording(outside))
                self.assertIsNone(meet.resolve_recording(root))
            finally:
                meet.RECORDINGS = old


if __name__ == "__main__":
    unittest.main()
