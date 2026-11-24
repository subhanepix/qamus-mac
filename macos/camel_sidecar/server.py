#!/usr/bin/env python3
"""
Qamus Local CAMeL Tools Sidecar (127.0.0.1:41933)
Provides context-aware Arabic diacritization, morphological disambiguation,
and probability-scored parse candidates (tense, voice, POS, grammatical case)
trained on NYU Abu Dhabi's CAMeL Arabic treebanks.
"""
import argparse
import json
import math
import os
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Defer heavy torch/camel imports until startup so /health can report loading state cleanly
STATE = {
    "ready": False,
    "loading": True,
    "error": None,
    "model_name": None,
    "device": "cpu",
    "disambiguator": None,
    "tokenize": None,
    "lock": threading.Lock(),
}

AR_DIAC_RE = re.compile(r"[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED\u0640]")
HAMZA_TRANS = str.maketrans({
    "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ء": "ا", "ؤ": "ا", "ئ": "ا",
    "ى": "ي", "ة": "ه", "ک": "ك", "ی": "ي",
})

POS_LABELS = {
    "verb": ("Verb", "فعل"),
    "verb_pseudo": ("Pseudo-verb", "شبه فعل"),
    "noun": ("Noun", "اسم"),
    "noun_prop": ("Proper Noun", "اسم علم"),
    "noun_num": ("Numeral", "عدد"),
    "noun_quant": ("Quantifier", "اسم كمية"),
    "adj": ("Adjective", "صفة"),
    "adj_comp": ("Comparative Adj.", "اسم تفضيل"),
    "adj_num": ("Ordinal Adj.", "عدد ترتيبي"),
    "adv": ("Adverb", "ظرف"),
    "adv_interrog": ("Interrogative Adv.", "أداة استفهام"),
    "adv_rel": ("Relative Adv.", "ظرف موصول"),
    "pron": ("Pronoun", "ضمير"),
    "pron_dem": ("Demonstrative", "اسم إشارة"),
    "pron_exclam": ("Exclamative", "أداة تعجب"),
    "pron_interrog": ("Interrogative Pron.", "اسم استفهام"),
    "pron_rel": ("Relative Pronoun", "اسم موصول"),
    "prep": ("Preposition", "حرف جر"),
    "conj": ("Conjunction", "حرف عطف"),
    "conj_sub": ("Subordinating Conj.", "حرف مصدري/شرط"),
    "part": ("Particle", "حرف"),
    "part_neg": ("Negation Particle", "حرف نفي"),
    "part_verb": ("Verbal Particle", "حرف تحقيقي/استقبال"),
    "part_fut": ("Future Particle", "حرف استقبال"),
    "part_interrog": ("Interrogative Particle", "حرف استفهام"),
    "part_focus": ("Focus Particle", "أداة حصر/توكيد"),
    "part_restrict": ("Restrictive Particle", "أداة حصر"),
    "part_voc": ("Vocative Particle", "حرف نداء"),
    "part_det": ("Definite Article", "أداة تعريف"),
    "interj": ("Interjection", "اسم فعل / تعجب"),
    "abbrev": ("Abbreviation", "اختصار"),
    "punc": ("Punctuation", "علامة ترقيم"),
    "digit": ("Number", "رقم"),
}

ASPECT_LABELS = {
    "i": ("Present", "مضارع"),
    "p": ("Past", "ماضٍ"),
    "c": ("Imperative", "أمر"),
}

VOICE_LABELS = {
    "a": ("Active", "مبني للمعلوم"),
    "p": ("Passive", "مبني للمجهول"),
}

CASE_LABELS = {
    "n": ("Nominative", "مرفوع"),
    "a": ("Accusative", "منصوب"),
    "g": ("Genitive", "مجرور"),
}

MOOD_LABELS = {
    "i": ("Indicative", "مرفوع"),
    "s": ("Subjunctive", "منصوب"),
    "j": ("Jussive", "مجزوم"),
}

PERSON_LABELS = {
    "1": "1st",
    "2": "2nd",
    "3": "3rd",
}

GEN_LABELS = {
    "m": "m.",
    "f": "f.",
}

NUM_LABELS = {
    "s": "sg.",
    "d": "dual",
    "p": "pl.",
}


def norm_ar(s: str) -> str:
    return AR_DIAC_RE.sub("", s or "").translate(HAMZA_TRANS).strip()


def format_analysis(scored_analysis, confidence: float, rank: int) -> dict:
    a = scored_analysis.analysis
    pos = a.get("pos", "")
    asp = a.get("asp", "na")
    vox = a.get("vox", "na")
    cas = a.get("cas", "na")
    mod = a.get("mod", "na")
    per = a.get("per", "na")
    gen = a.get("gen", "na")
    num = a.get("num", "na")
    diac = a.get("diac", "")
    lex = a.get("lex", "")
    gloss = a.get("gloss", "")

    pos_en, pos_ar = POS_LABELS.get(pos, (pos or "Word", ""))
    en_parts = [pos_en]
    ar_parts = [pos_ar] if pos_ar else []

    if pos == "verb":
        if asp in ASPECT_LABELS:
            en_parts.append(ASPECT_LABELS[asp][0])
            ar_parts = [f"فعل {ASPECT_LABELS[asp][1]}"]
        if vox in VOICE_LABELS:
            en_parts.append(VOICE_LABELS[vox][0])
            ar_parts.append(VOICE_LABELS[vox][1])
        if mod in MOOD_LABELS and asp == "i":
            en_parts.append(MOOD_LABELS[mod][0])
            ar_parts.append(MOOD_LABELS[mod][1])
        png = " ".join(x for x in [PERSON_LABELS.get(per), GEN_LABELS.get(gen), NUM_LABELS.get(num)] if x)
        if png:
            en_parts.append(f"({png})")
    else:
        if cas in CASE_LABELS:
            en_parts.append(CASE_LABELS[cas][0])
            ar_parts.append(CASE_LABELS[cas][1])
        if num in NUM_LABELS and num != "s":
            en_parts.append(NUM_LABELS[num])

    # Detect attached proclitics / enclitics
    clitics = []
    for k in ("prc3", "prc2", "prc1", "prc0", "enc0"):
        v = a.get(k, "0")
        if v and v not in ("0", "na"):
            clitics.append(f"{k}={v}")

    return {
        "rank": rank,
        "confidence": round(float(confidence), 4),
        "rawScore": round(float(scored_analysis.score), 4),
        "diac": diac,
        "lex": lex,
        "pos": pos,
        "aspect": None if asp in ("na", "", "u") else asp,
        "voice": None if vox in ("na", "", "u") else vox,
        "case": None if cas in ("na", "", "u") else cas,
        "mood": None if mod in ("na", "", "u") else mod,
        "englishLabel": " · ".join(en_parts),
        "arabicLabel": " ".join(ar_parts).strip(),
        "caseArabic": CASE_LABELS.get(cas, (None, None))[1] if pos != "verb" else MOOD_LABELS.get(mod, (None, None))[1],
        "caseEnglish": CASE_LABELS.get(cas, (None, None))[0] if pos != "verb" else MOOD_LABELS.get(mod, (None, None))[0],
        "clitics": clitics,
        "gloss": gloss,
    }


def deduplicate_analyses(scored_list):
    """Deduplicate synonymous glosses that share the exact same vocalization & grammatical features."""
    seen = set()
    out = []
    for sa in scored_list:
        a = sa.analysis
        sig = (
            a.get("diac", ""),
            a.get("pos", ""),
            a.get("asp", ""),
            a.get("vox", ""),
            a.get("cas", ""),
            a.get("mod", ""),
        )
        if sig in seen:
            continue
        seen.add(sig)
        out.append(sa)
    return out


def normalized_confidences(scored_list):
    """Convert CAMeL's top-K analysis scores (feature agreement ratios in [0,1]) into calibrated probabilities."""
    if not scored_list:
        return []
    scores = [max(0.0, float(x.score)) for x in scored_list]
    if max(scores) <= 1.0 and min(scores) >= 0.0:
        max_s = max(scores)
        weights = [math.exp(14.0 * (s - max_s)) for s in scores]
        wsum = sum(weights)
        return [w / wsum for w in weights]
    total = sum(scores)
    return [s / total for s in scores] if total > 0 else [1.0 / len(scored_list)] * len(scored_list)


def load_camel_model():
    try:
        t0 = time.time()
        import torch
        from camel_tools.disambig.bert import BERTUnfactoredDisambiguator
        from camel_tools.tokenizers.word import simple_word_tokenize

        # Keep CPU threads lean and avoid competing with Ollama GPU VRAM when Qwen 30B is loaded
        use_gpu = os.environ.get("QAMUS_CAMEL_GPU", "0") == "1"
        device_label = "mps" if (use_gpu and torch.backends.mps.is_available()) else "cpu"

        # Prefer Classical Arabic / MSA unfactored BERT disambiguator
        preferred = ["msa", "ca"]
        if os.environ.get("QAMUS_CAMEL_MODEL"):
            preferred.insert(0, os.environ["QAMUS_CAMEL_MODEL"])

        disambig = None
        chosen = None
        last_err = None
        for variant in preferred:
            try:
                disambig = BERTUnfactoredDisambiguator.pretrained(
                    variant,
                    top=6,
                    pretrained_cache=True,
                )
                chosen = f"camel-bert-unfactored-{variant}"
                break
            except Exception as e:
                last_err = e

        if disambig is None:
            raise RuntimeError(f"Failed to load CAMeL disambiguator: {last_err}")

        # Warm up on 2 Arabic words so first user click is instant
        _ = disambig.disambiguate(["طلب", "العلم"])

        STATE["disambiguator"] = disambig
        STATE["tokenize"] = simple_word_tokenize
        STATE["model_name"] = chosen
        STATE["device"] = device_label
        STATE["ready"] = True
        STATE["loading"] = False
        print(f"[camel-sidecar] Ready ({chosen}, {device_label}) in {time.time() - t0:.2f}s", flush=True)
    except Exception as e:
        STATE["error"] = str(e)
        STATE["loading"] = False
        print(f"[camel-sidecar] Load error: {e}", file=sys.stderr, flush=True)


def analyze_sentence(sentence: str, target_word: str) -> dict:
    if not STATE["ready"]:
        raise RuntimeError(STATE["error"] or "CAMeL model is still loading")

    tokenize = STATE["tokenize"]
    disambig = STATE["disambiguator"]

    # Keep line breaks clean while tokenizing Arabic words and punctuation
    clean_sent = re.sub(r"\s+", " ", (sentence or "").strip())
    raw_tokens = tokenize(clean_sent)
    if not raw_tokens:
        return {"diacritizedSentence": "", "targetParses": [], "tokens": []}

    # Cap sentence length safely for BERT (max ~120 tokens around target)
    if len(raw_tokens) > 120:
        norm_t = norm_ar(target_word)
        center = next((i for i, tok in enumerate(raw_tokens) if norm_ar(tok) == norm_t), 0)
        lo = max(0, center - 50)
        hi = min(len(raw_tokens), lo + 110)
        raw_tokens = raw_tokens[lo:hi]

    with STATE["lock"]:
        disambig_words = disambig.disambiguate(raw_tokens)

    norm_target = norm_ar(target_word)
    target_idx = -1
    # Prefer exact match (with harakat if provided), then normalized exact match, then substring match
    for idx, dw in enumerate(disambig_words):
        if dw.word == target_word.strip():
            target_idx = idx
            break
    if target_idx < 0 and norm_target:
        for idx, dw in enumerate(disambig_words):
            if norm_ar(dw.word) == norm_target:
                target_idx = idx
                break
    if target_idx < 0 and norm_target:
        for idx, dw in enumerate(disambig_words):
            nt = norm_ar(dw.word)
            if nt and (norm_target in nt or nt in norm_target):
                target_idx = idx
                break

    diac_words = []
    tokens_out = []
    target_parses = []

    for idx, dw in enumerate(disambig_words):
        analyses = deduplicate_analyses(dw.analyses or [])[:3]
        confs = normalized_confidences(analyses)
        if analyses:
            top_a = format_analysis(analyses[0], confs[0], 0)
            diac_words.append(top_a["diac"] or dw.word)
            if top_a["pos"] != "punc":
                tokens_out.append({
                    "word": dw.word,
                    "diac": top_a["diac"] or dw.word,
                    "pos": top_a["pos"],
                    "englishLabel": top_a["englishLabel"],
                    "arabicLabel": top_a["arabicLabel"],
                    "caseArabic": top_a["caseArabic"],
                    "caseEnglish": top_a["caseEnglish"],
                    "voice": top_a["voice"],
                    "aspect": top_a["aspect"],
                    "confidence": top_a["confidence"],
                    "isTarget": idx == target_idx,
                })
            if idx == target_idx:
                target_parses = [
                    format_analysis(sa, confs[r], r)
                    for r, sa in enumerate(analyses[:3])
                ]
        else:
            diac_words.append(dw.word)

    # Rejoin punctuation neatly for readable Arabic
    diac_sentence = " ".join(diac_words)
    diac_sentence = re.sub(r"\s+([،؛:.!؟»)])", r"\1", diac_sentence)
    diac_sentence = re.sub(r"([«(])\s+", r"\1", diac_sentence)

    return {
        "model": STATE["model_name"],
        "diacritizedSentence": diac_sentence,
        "targetWordMatched": disambig_words[target_idx].word if target_idx >= 0 else None,
        "targetParses": target_parses,
        "tokens": tokens_out,
    }


class CamelHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet unless debugging
        if os.environ.get("QAMUS_CAMEL_VERBOSE") == "1":
            super().log_message(format, *args)

    def _send_json(self, code: int, obj: dict):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            self._send_json(200, {
                "ok": True,
                "ready": STATE["ready"],
                "loading": STATE["loading"],
                "model": STATE["model_name"],
                "device": STATE["device"],
                "error": STATE["error"],
            })
            return
        self._send_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/analyze":
            self._send_json(404, {"error": "Not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            payload = json.loads(raw.decode("utf-8"))
            sentence = payload.get("sentence", "")
            target_word = payload.get("targetWord", "")
            result = analyze_sentence(sentence, target_word)
            self._send_json(200, result)
        except Exception as e:
            self._send_json(500, {"error": str(e)})


def main():
    parser = argparse.ArgumentParser(description="Qamus Local CAMeL Tools Sidecar")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=41933)
    args = parser.parse_args()

    # Load CAMeL in background thread so /health responds immediately while warming up
    threading.Thread(target=load_camel_model, daemon=True).start()

    server = ThreadingHTTPServer((args.host, args.port), CamelHandler)

    def shutdown_handler(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    print(f"[camel-sidecar] Listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
