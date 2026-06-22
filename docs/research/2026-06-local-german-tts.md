# Deep Research — Local German TTS on Apple Silicon (June 2026)

> Status: **complete** · Method: 5-angle parallel web research + adversarial
> cross-checking · Question owner: @daydy16
>
> **Outcome:** see the decision record
> [`docs/decisions/0001-cloud-tts-keep-local-stt.md`](../decisions/0001-cloud-tts-keep-local-stt.md).
> Short version: **local German TTS that is simultaneously natural, low-latency
> and cleanly runnable on a Mac does not exist today.** The project keeps **cloud
> TTS** and focuses its own value on **local STT**.

## The question

> Why is it so hard to run a *good* local/offline TTS model — and is there a
> German voice, late 2025/2026, that sounds natural (Siri/ElevenLabs level), has
> low latency (streaming, RTF < 1) and runs fully local on an Apple Silicon Mac
> (M4)? Target: a Home Assistant voice pipeline. STT already works well via Apple
> `SpeechAnalyzer`; this is **only** about TTS.

Constraints: must speak **German**; Apple system voices (`AVSpeechSynthesizer`)
and **Piper/Thorsten** were already tested and rejected as too robotic/monotone;
prefer local + streaming + Wyoming/OpenAI-compatible hookup to HA.

## TL;DR

- **Why it is hard:** three compounding walls — an **architecture dilemma**
  (fast *or* natural *or* streamable, rarely all three), a **German data
  shortage**, and **immature Apple-Silicon TTS inference**.
- **The fast Mac-native models can't speak German** (Kokoro, MeloTTS), and Piper
  was already rejected.
- **The natural German models run poorly on the Mac:** XTTS is broken on Apple
  GPU (MPS) — CPU-only = slow; F5-German runs natively (MLX) but is
  **non-streaming (~4 s/utterance)**; Orpheus-German is a 3B model (RAM-heavy,
  GGUF/Metal only, unmeasured on Mac).
- **Nothing local matches ElevenLabs/Siri for German** — the gap is *larger* for
  German than for English because of training-data scarcity.
- **Decision:** keep **cloud TTS**; keep **local STT**. Revisit if a streaming,
  German, Apple-Silicon-native neural TTS appears.

## 1. Why good local TTS is technically hard

**Architecture dilemma.** Two model families, each with a built-in catch:
- *Autoregressive (LLM-style)* — XTTS, Orpheus, Fish-Speech. Streams well (first
  audio ~200 ms), expressive, but large (1–3 B params), latency grows with text
  length, and exposure bias propagates early errors through long sentences.
  ([Spheron](https://www.spheron.network/blog/self-host-voice-cloning-gpu-cloud-xtts-f5-tts-openvoice-v2/),
  [Orpheus](https://bitbasti.com/blog/audio-streaming-with-orpheus))
- *Non-autoregressive / flow-matching / diffusion* — F5-TTS, StyleTTS2, Matcha.
  Fast (RTF ~0.15) and parallel, but **does not stream naturally** — the whole
  utterance is generated at once, so first-audio latency = full generation time.
  ([F5-TTS paper](https://arxiv.org/abs/2410.06885))

  You cannot get *streaming + top quality + small* simultaneously.

**German data shortage (the real core).** Naturalness needs huge clean datasets.
English has LibriLight/LibriHeavy (50–60k+ h). In the multilingual Emilia corpus
(101k h) English alone is ~46k h — German shares the rest with five other
languages. The largest clean German TTS corpus (HUI) is ~326 h. That's why almost
all SOTA models are English-first.
([HUI corpus](https://arxiv.org/pdf/2106.06309),
[Emilia](https://arxiv.org/html/2407.05361v3))

**German grapheme-to-phoneme (G2P).** Most engines (including Piper) depend on
**espeak-ng**, which systematically mishandles German compounds, homographs and
foreign words — capping intelligibility *before* the acoustic model runs.
([OLaPh](https://arxiv.org/html/2509.20086v1),
[Piper G2P](https://huggingface.co/blog/hexgrad/g2p))

**Apple Silicon is immature for TTS.** PyTorch-MPS is missing ops TTS vocoders
need (CPU fallback kills throughput; e.g. `aten::angle` absent, MeloTTS hits a
">65536 output channels" limit). The fast paths (MLX/CoreML/ANE) forbid the
dynamic shapes/control-flow TTS duration models use, so there is no clean
single-graph port — only bespoke per-model ports.
([kokoro-coreml](https://github.com/mattmireles/kokoro-coreml),
[MeloTTS #228](https://github.com/myshell-ai/MeloTTS/issues/228))

**The gap to ElevenLabs.** For English read speech the MOS gap has shrunk to
~0.1–0.3. For **expressiveness/emotion** and especially **German** it is larger —
no source claims local German TTS reaches ElevenLabs-DE.
([CodeSOTA](https://www.codesota.com/text-to-speech),
[MultiVox](https://arxiv.org/pdf/2507.10859))

## 2. German-capable models — overview

| Model | German? | Naturalness (DE) | License (commercial?) | Cloning |
|---|---|---|---|---|
| **XTTS-v2** (Coqui) | ✅ good (monolingual DE > cross-lingual) | high | ⚠️ CPML **non-commercial** | ✅ (~6 s) |
| **F5-TTS German** (aihpi / hvoss) | ✅ dedicated finetune | high | ⚠️ Emilia ckpt CC-BY-NC; finetunes vary | ✅ (~10 s) |
| **Orpheus German** (Kartoffel / tv-orpheus) | ✅ dedicated (~12k Thorsten recs) | high, "clearly more natural than Piper" | ✅ **Apache-2.0** | partial |
| **Chatterbox Multilingual** (Resemble) | ✅ (23 langs) | good, variable | ✅ **MIT** | ✅ |
| **Zonos-v0.1** (Zyphra) | ✅ | good | ✅ **Apache-2.0** | ✅ (5–30 s) |
| **Parler-TTS Mini Multilingual** | ✅ (8 langs) | ok, < XTTS | ✅ **Apache-2.0** | ❌ (text-prompt only) |
| **MaskGCT** (Amphion, ~6,900 h DE) | ✅ native | high | ⚠️ **CC-BY-NC** | ✅ |
| **Higgs Audio v2** | ✅ secondary | medium | ⚠️ research/restricted | ✅ |
| **Piper/Thorsten** (baseline) | ✅ | "natural but clearly synthetic", monotone | ✅ **MIT/CC0** | ❌ |
| **Kokoro, MeloTTS, GPT-SoVITS, Spark-TTS, Sesame CSM** | ❌ **no German** | — | — | — |

Sources: [XTTS-v2](https://huggingface.co/coqui/XTTS-v2) ·
[F5-German (aihpi)](https://huggingface.co/aihpi/F5-TTS-German) /
[hvoss](https://huggingface.co/hvoss-techfak/F5-TTS-German) ·
[Kartoffel-Orpheus](https://huggingface.co/SebastianBodza/Kartoffel_Orpheus-3B_german_natural-v0.1) /
[tv-orpheus](https://huggingface.co/Thorsten-Voice/tv-orpheus-v1) ·
[Chatterbox](https://github.com/resemble-ai/chatterbox) ·
[Zonos](https://github.com/Zyphra/Zonos) ·
[Parler](https://github.com/huggingface/parler-tts) ·
[MaskGCT](https://huggingface.co/amphion/MaskGCT) ·
[Kokoro (lang list, no DE)](https://huggingface.co/hexgrad/Kokoro-82M)

**Note:** the nicest-sounding models often carry **license catches** (XTTS,
MaskGCT, Fish, Higgs = non-commercial/restricted). Cleanly commercial-friendly +
German + cloning are mainly **Chatterbox (MIT)**, **Zonos (Apache)** and
**Orpheus-German (Apache)**.

## 3. The Mac reality — what actually runs on an M4

Measured Apple-Silicon numbers for German models barely exist; this is the crux:

| Model | Mac path | Latency/RTF on Apple Silicon | Streaming? |
|---|---|---|---|
| **Kokoro** | MLX / CoreML(ANE) | ~12–23× realtime (M4 Pro), ~1.5 GB RAM | ✅ — **but no German** |
| **Piper** | CPU/MPS | ~32× realtime, 208 ms TTFB (M4) | ✅ — but quality rejected |
| **F5-TTS German** | **MLX (native)** | ~4 s/utterance (M3 Max), RTF ~0.15 | ❌ non-streaming |
| **Orpheus German (3B)** | GGUF via LM Studio / orpheus-cpp (Metal) | **unmeasured on Mac**; GPU ~200 ms TTFB; RAM-heavy | ✅ (AR) |
| **XTTS-v2** | CPU only | **MPS hangs/broken** → CPU = slow | ✅ (GPU only) |
| **Chatterbox** | MLX port exists | unmeasured on Mac | partial |
| **Zonos** | no Mac benchmark | ~7.5 GB+ VRAM → poor Mac fit | — |

Sources: [vllm-mlx Kokoro bench](https://github.com/waybarrios/vllm-mlx/blob/main/docs/benchmarks/audio.md) ·
[FluidAudio Kokoro CoreML (M4 Pro)](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md) ·
[Piper on M4](https://github.com/5uck1ess/tts-bench) ·
[f5-tts-mlx](https://github.com/lucasnewman/f5-tts-mlx) ·
[XTTS MPS broken](https://github.com/coqui-ai/TTS/issues/3649) ·
[Orpheus on macOS](https://codersera.com/blog/install-and-run-orpheus-3b-tts-on-macos-a-complete-guide/)

**The bitter punchline:** the models that fly on the Mac (Kokoro, Piper) are
exactly the ones we can't/won't use. The good-German models either don't run
cleanly (XTTS), don't stream (F5), or are untested-heavy (Orpheus 3B).

## 4. Home Assistant hookup (ready-made paths)

- **`dokterbob/macos-speech-server`** — the *only* native-Mac server with Wyoming
  + OpenAI API. But German only via **Apple system voices** (non-neural — no
  better than what we already have).
  ([repo](https://github.com/dokterbob/macos-speech-server))
- **`roryeckel/wyoming_openai`** — bridge that puts *any* OpenAI-compatible TTS
  server behind HA's Wyoming (sentence-chunk streaming). Language-agnostic → DE
  depends on the backend. ([repo](https://github.com/roryeckel/wyoming_openai))
- **`lmoe/wyoming-xtts`** — XTTS-v2 DE + cloning, native Wyoming streaming, but
  **needs an NVIDIA GPU** (irrelevant for a Mac).
  ([repo](https://github.com/lmoe/wyoming-xtts))
- **`sfortis/openai_tts`** — HACS integration for any OpenAI-TTS endpoint,
  streaming since HA 2025.7+. ([repo](https://github.com/sfortis/openai_tts))
- **Obsolete, avoid:** `matatonic/openedai-speech` (can do XTTS-DE but officially
  obsolete).

HA's **native TTS streaming (2025.10)** starts playback before the text is
finished (~10× perceived speed-up) — but only helps **AR/streaming** models
(Orpheus), not F5.

## 5. What the German community actually says

- The Wyoming-XTTS project exists **specifically because German Piper/Thorsten
  was too poor** for the author.
  ([HA forum](https://community.home-assistant.io/t/wyoming-xtts-xtts-v2-text-to-speech-for-home-assistant/976138))
- Even an Orpheus-German contributor calls the Thorsten voice **"monotone."**
  ([Orpheus discussion](https://github.com/canopyai/Orpheus-TTS/discussions/117))
- **Thorsten Müller himself** (the voice's creator) finds his new **Orpheus**
  model "significantly more natural" than Piper/Coqui — but is ambivalent on
  prolonged listening.
  ([thorsten-voice.de](https://www.thorsten-voice.de/2025/12/15/orpheus-tts-modellvergleich/))
- Broad consensus: **XTTS-v2 and F5-TTS clearly beat Piper** on naturalness;
  Piper's strength is speed, not beauty.
  ([promptquorum](https://www.promptquorum.com/power-local-llm/local-tts-voice-cloning-piper-coqui-xtts))
- F5-German has known **umlaut (Ä/Ö/Ü)** and spelling-out weaknesses — relevant
  when an assistant spells things.
  ([aihpi #6](https://huggingface.co/aihpi/F5-TTS-German/discussions/6))
- A German 8-model practical test concludes local premium TTS on consumer
  hardware is "not practical for live interaction" as of mid-2026 (snippet only —
  [wulffit.de](https://wulffit.de/artikel/tts-deutsch/)).

## 6. If we ever revisit local German TTS

The two only-serious experiments for "noticeably better than Thorsten" + runnable
on an M4 (neither is plug-and-play):

1. **Orpheus-German "Kartoffel" / tv-orpheus as GGUF** (LM Studio / orpheus-cpp,
   Metal) — the only *natural + streamable* path, Apache-licensed, rated "clearly
   more natural" by Thorsten himself. Risk: 3B model, Mac performance unmeasured.
2. **F5-TTS German via MLX** — runs natively/fast on M4, high quality. Catch:
   non-streaming (~3–4 s/answer) and umlaut quirks.

Recommended *if revisited*: benchmark both on the actual M4 (time-to-first-audio,
RTF, audio samples) before committing, then expose via an OpenAI-compatible
server → `wyoming_openai` → HA.

## Confidence / verification notes

- Quality/naturalness ratings come from community blogs/forums, not peer-reviewed
  German listening tests — treat as directional.
- Several Hugging Face cards and HA forum threads returned HTTP 403 to automated
  fetch; license/quality details for F5, Fish, Higgs are version-dependent and
  should be re-verified against the exact checkpoint before any commercial use.
- Apple-Silicon latency for the German models specifically is largely
  **unmeasured** in public sources — the F5 "~4 s" figure is an English sample on
  an M3 Max; XTTS-on-MPS-broken is high confidence.
