# ADR 0001 — Use cloud TTS; keep local (Apple) STT

- **Status:** accepted
- **Date:** 2026-06-22
- **Deciders:** @daydy16
- **Context research:** [`docs/research/2026-06-local-german-tts.md`](../research/2026-06-local-german-tts.md)

## Context

This bridge exposes Apple's on-device speech engines to Home Assistant. Two
parts have very different value:

- **STT** via Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+) works
  well: fast, on-device, German-capable, instant finalization. This is the
  project's unique strength.
- **TTS** via `AVSpeechSynthesizer` (system/Premium voices) was judged too
  robotic. The obvious "make it better locally" path — a neural German TTS on
  the Mac — was investigated in depth.

A full multi-source study (see the research doc) found that a local German TTS
which is **simultaneously natural, low-latency, and cleanly runnable on Apple
Silicon does not exist today**:

- The Mac-fast neural models (Kokoro, MeloTTS) **don't speak German**.
- Piper/Thorsten speaks German fast but was already rejected as robotic/monotone.
- The natural German models run badly on the Mac: **XTTS is broken on MPS**
  (CPU-only, slow), **F5-German is non-streaming (~4 s/utterance)**, and
  **Orpheus-German is a 3B model** (RAM-heavy, GGUF/Metal only, unmeasured).
- Nothing local matches ElevenLabs/Siri for German — the gap is *wider* for
  German than English due to training-data scarcity.

## Decision

1. **TTS stays in the cloud.** Home Assistant uses a cloud TTS engine (e.g. HA
   Cloud / ElevenLabs / OpenAI-compatible) for speech output. We do **not** ship
   or maintain a local neural TTS engine in this app.
2. **STT stays local** on Apple `SpeechAnalyzer`. It is the part this project
   does uniquely well, and it works.
3. The bridge's primary role is therefore the **local STT bridge** for Home
   Assistant. The existing `AVSpeechSynthesizer` TTS path is retained only as a
   convenience/fallback, not as a quality target.

## Consequences

- We stop chasing local neural TTS. No XTTS/F5/Orpheus/Kokoro integration work.
- Effort on the speech side concentrates on **making STT more accurate and
  reliable** (e.g. context enrichment / vocabulary biasing for smart-home entity
  and room names) rather than on TTS voice quality.
- Cloud TTS implies the TTS text leaves the device. That is an accepted
  trade-off here; the STT path remains fully on-device/private.
- README and docs are updated to reflect "local STT + cloud TTS" as the
  intended architecture.

## Revisit criteria

Reopen this decision if **a streaming, German-capable, Apple-Silicon-native
(MLX/CoreML) neural TTS** appears. The two candidates to benchmark first would be
**Orpheus-German (Kartoffel/tv-orpheus) GGUF** and **F5-TTS German (MLX)** — see
§6 of the research doc.
