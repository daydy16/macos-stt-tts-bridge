# Research — Making Apple on-device STT more accurate & reliable (context enrichment)

> Status: **complete** · Method: Apple developer-docs (backing JSON), Apple
> Developer Forums (Apple-engineer replies), WWDC 2023/2025 sessions ·
> Question owner: @daydy16
>
> **Context:** follow-up to [ADR 0001](../decisions/0001-cloud-tts-keep-local-stt.md)
> — with TTS moved to the cloud, the speech effort concentrates on making the
> **local STT** more accurate and reliable, e.g. by biasing recognition toward
> Home-Assistant entity/room/device names.

## TL;DR — the one finding that drives everything

There are **two non-overlapping biasing mechanisms**, and the catch is:

> **`SpeechTranscriber` — the high-accuracy module this bridge currently uses —
> does NOT support contextual-string biasing.** (Confirmed by an Apple engineer:
> https://developer.apple.com/forums/thread/801877)

So enriching with HA vocabulary forces an explicit trade-off:

| Goal | Path | Biasing? | Cost |
|---|---|---|---|
| Best raw accuracy (today's setup) | `SpeechAnalyzer` + **`SpeechTranscriber`** | ❌ none | — |
| New API **and** bias to entity names | `SpeechAnalyzer` + **`DictationTranscriber`** + `AnalysisContext.contextualStrings` | ✅ phrases | lower base accuracy (mirrors system dictation) |
| Heavy vocab: weighted phrases, intent templates, custom pronunciations | **`SFSpeechRecognizer`** (legacy engine) + `SFCustomLanguageModelData` | ✅ full custom LM | per-locale, prep latency, on-device-only |
| Light, any-OS phrase hints | `SFSpeechRecognizer` + `SFSpeechRecognitionRequest.contextualStrings` | ✅ ≤100 short phrases | weakest |

There is **no way to keep `SpeechTranscriber`'s accuracy *and* inject vocabulary**
at the same time — you pick one.

## 1. `contextualStrings` (legacy `SFSpeechRecognizer`, any recent OS)

- "An array of phrases that should be recognized, even if they are not in the
  system vocabulary." `var contextualStrings: [String]`.
- Apple constraints: **≤100 phrases**; keep them **one or two words**; each phrase
  should be sayable **without pausing**.
- Soft prior, not a guarantee; degrades with long phrases / >100 entries.
- Source: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings

## 2. Custom language model — `SFCustomLanguageModelData` (iOS 17+/macOS 14+, still in 26)

The most powerful path; introduced WWDC23 session 10101
(https://developer.apple.com/videos/play/wwdc2023/10101/).

**Build (result-builder DSL), `SFCustomLanguageModelData(locale:identifier:version:)`:**
- `PhraseCount` — a phrase **plus a weight** (relative bias strength).
- `CustomPronunciation` — new vocabulary term + pronunciation in **X-SAMPA**
  (queryable phoneme subset via `supportedPhonemes(locale:)`). Good for awkward
  device names.
- `PhraseCountsFromTemplates` / `TemplatePhraseCountGenerator` — expand **template
  classes** (slot/named-entity style). Maps directly onto HA intents, e.g.
  `"<verb> the <device> in the <room>"` with entity lists as classes.
- `export(to: URL)`.

**Compile + apply at runtime:**
- `SFSpeechLanguageModel.prepareCustomLanguageModel(for:configuration:)` — compiles
  the data; expensive, run off-main.
  - The older `…(for:clientIdentifier:configuration:completion:)` overload is
    **deprecated in 26.0**; the custom-LM workflow itself is **not** removed.
- Attach via `SFSpeechRecognitionRequest.customLanguageModel`; requires
  `requiresOnDeviceRecognition = true` (customization is on-device-only).
- Apple sample: https://github.com/gromb57/ios-wwdc23__RecognizingSpeechInLiveAudio ·
  3rd-party builder CLI: https://github.com/Compiler-Inc/SpeechModelBuilder
- Sources: https://developer.apple.com/documentation/speech/sfcustomlanguagemodeldata ·
  https://developer.apple.com/documentation/speech/sfspeechlanguagemodel

Scales well past the 100-phrase cap; supports weighting + templates +
pronunciations. Costs: one model per locale, finite data budget, preparation
latency, and it pins us to the **legacy `SFSpeechRecognizer`** engine.

## 3. New framework biasing — `DictationTranscriber` + `AnalysisContext`

- `SpeechAnalyzer.context: AnalysisContext` (+ `setContext(_:)`).
- `AnalysisContext.contextualStrings: [ContextualStringsTag: [String]]` — "words or
  phrases, grouped by tag, recognized even if not in the system vocabulary"
  (predefined tag `.general`).
- **Only `DictationTranscriber` honors it; `SpeechTranscriber` ignores it.**
  `DictationTranscriber` mirrors system dictation (lower base accuracy than
  `SpeechTranscriber`, works on more devices).
- Sources: https://developer.apple.com/documentation/speech/analysiscontext ·
  https://developer.apple.com/forums/thread/801877 · WWDC25 session 277
  (https://developer.apple.com/videos/play/wwdc2025/277/)

## 4. Non-biasing reliability levers (apply regardless of path)

- **Confidence gating:** request `ResultAttributeOption.transcriptionConfidence`
  and refuse/clarify low-confidence commands instead of mis-acting.
- **Volatile vs final:** keep `.volatileResults` for live UI but only *act* on
  finalized results. Avoid `.fastResults` for command parsing (it trades accuracy
  for latency).
- **Warm start:** `prepareToAnalyze(in:)` / model retention to cut first-result
  latency; pre-`reserve` the `de-DE` asset via `AssetInventory` before first use
  and handle the "asset not found" error
  (https://developer.apple.com/forums/thread/797835).
- **Audio format:** feed exactly `SpeechAnalyzer.bestAvailableAudioFormat(...)`
  (already done in `SpeechAnalyzerEngine`) — avoids resample guesswork.
- Legacy-only: `addsPunctuation`, `taskHint` (`.confirmation`/`.search`/`.dictation`).

## 5. Accuracy context: German vs English (third-party, indicative)

- An independent 2026 comparison (Dicta.to, ~13k recordings) found Apple
  `SpeechAnalyzer` the **most accurate on-device engine on clean read-aloud across
  FR/ES/DE/IT**; on **disfluent/noisy** speech Parakeet/Whisper close or overtake.
  → expect strong German WER on **clear commands**, weaker on hesitant/noisy
  speech. (https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/ —
  snippet only, blog blocked direct fetch.)
- Argmax/WhisperKit comparisons: https://www.argmaxinc.com/blog/apple-and-argmax

## 6. Recommendation for this bridge

The bridge today has no source of HA vocabulary — entity/area/device names live
in Home Assistant, not in the app. So context enrichment is a **two-part feature**:
(a) get the names into the bridge, (b) feed them to a biasing-capable engine.

Pragmatic ordering:

1. **Cheap reliability wins first (no biasing, keep `SpeechTranscriber`):** surface
   `transcriptionConfidence`, keep acting only on finals, ensure warm
   start/asset-reserve. These improve reliability without giving up accuracy.
2. **If entity-name misrecognition is the real pain:** add an optional vocabulary
   source (env var / file / small `POST /vocabulary` endpoint, or pull from HA),
   then bias via **`SFSpeechRecognitionRequest.contextualStrings`** on the legacy
   engine for a quick win, graduating to a **`SFCustomLanguageModelData`** custom
   LM (templates + weights + pronunciations) for many/changing entities.
3. **Only if biasing must live in the new framework:** switch the engine to
   `DictationTranscriber` and push names into `AnalysisContext.contextualStrings`
   — but measure, because its base accuracy is below `SpeechTranscriber`.

**Key trade-off to decide:** keep `SpeechTranscriber`'s top accuracy (no biasing),
or accept a lower-accuracy/legacy engine to gain vocabulary biasing. Worth an A/B
on real German commands with actual HA entity names before committing.

## Limitations / confidence

- "`SpeechTranscriber` cannot be biased" is from an Apple-engineer forum reply +
  the docs' lack of any context API on that type — high confidence, but
  re-verify against a future SDK release.
- German real-world (disfluent/noisy) accuracy figures are third-party snippets,
  not peer-reviewed — directional only.
- Apple HTML docs are JS-rendered; API declarations were taken from the docs'
  backing JSON. API names are accurate as of macOS 26.0.
