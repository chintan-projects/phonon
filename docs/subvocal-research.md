# Subvocal and a local quiet-speech experiment

Implemented in **Murmur Lab**, our Phonon-derived app, on branch
`codex/quiet-speech-lab`. The page inside the app is named **Speech Lab**.

Researched 5 November 2026. Target: **The Subvocal Company**, the YC-backed
company at [subvocal.company](https://subvocal.company/).
The first experiment uses a Mac and microphone only.

## What the company has disclosed

Subvocal is developing glasses that convert deliberately articulated, unvoiced
speech into text. Its product page claims 200+ WPM and a short personal
calibration. It says cameras and audible speech are unnecessary and that this
does not decode involuntary thoughts. These are vendor claims, not measurements
we have reproduced. [Product page](https://subvocal.company/)

The founders are Aarush Yadav and Arnav Kumar. The company is in YC F26 and
describes a small team working across sensing, embedded systems and ML. Its
sensing job listing explicitly withholds the detailed architecture and stresses
placement, anatomy, motion and interference as difficult variables.
[YC company](https://www.ycombinator.com/companies/the-subvocal-company),
[sensing role](https://www.ycombinator.com/companies/the-subvocal-company/jobs/yBCprPW-head-of-sensing)

The founder's launch account supplies more detail than the job listing:

- The first prototype used face-mounted EMG electrodes. They later switched to
  RF sensing, with antennas embedded in the glasses.
- The described signal comes from radio propagation changing with the tongue,
  lips and soft palate. They collected prompted recordings across people to
  improve generalization; the demo reportedly used 20 calibration sentences.
- The founder says launch inference will run in the cloud. Local weights are a
  possible future release. A device SDK is also described as a future release.
- He reports development latency usually below 500 ms, not a published
  independent benchmark.

These are attributed statements, not a released circuit, trained checkpoint or
reproducible evaluation. The public account does **not** disclose enough to
reconstruct the RF front end or train an equivalent decoder.
[Founder launch and discussion](https://news.ycombinator.com/item?id=50340088)

Specifically unresolved in the material reviewed: a reproducible RF front-end
design, carrier/channel configuration, raw signal format and sampling rate,
hardware interface, model architecture and size, downloadable training data,
weights, a public calibration protocol, and a held-out WER/latency report. A
general modality description does not answer these implementation questions.

The preorder page describes an estimated Q1 2027 shipment and delivery subject
to FCC approval. A preorder is not evidence that a production unit or SDK is
available to us today. [Preorder information](https://subvocal.company/preorder)

## How this differs from Phonon

| Stage | Current Phonon | Subvocal's disclosed direction | Our experiment |
| --- | --- | --- | --- |
| Input measurement | Microphone waveform | Articulation-dependent RF measurements | Microphone waveform |
| First decoder | Parakeet acoustic ASR | Proprietary sensor-to-text model | Existing Parakeet |
| Text cleanup | Fine-tuned LFM3 | Public details insufficient | Existing LFM3, shown separately |
| Runtime | Local Metal / MLX | Founder describes cloud launch inference | Local Metal / MLX |
| Setup | Audio input and app permissions | Wearable and personal calibration | Shared dictation microphone selection |
| Silent articulation | No useful acoustic input | Claimed target capability | Explicitly unsupported |

The Phonon columns follow the [upstream architecture](../README.md#pipeline)
and source. The last column describes our implementation. The comparison's
Subvocal column is a summary of the cited public disclosures above.

Engineering implication: changing the input sensor also changes the recognition
problem. LFM3 accepts text, not arbitrary RF or EMG arrays. It can remain a text
cleanup stage **after** an appropriate sensor decoder. Increasing microphone
gain does not manufacture an RF measurement or recover words from absent audio.

## Open work we can actually inspect

### EMG: the strongest reproducible starting point for true silent input

David Gaddy and Dan Klein published methods for converting facial EMG from
silent articulation into speech. The 2020 work transfers training targets from
vocalized to silent recordings. The 2021 work learns signal features with
convolutional layers and uses Transformer layers plus auxiliary phoneme
prediction. These are EMG methods, not evidence of Subvocal's model design.
[EMNLP 2020](https://aclanthology.org/2020.emnlp-main.445/),
[ACL 2021](https://aclanthology.org/2021.acl-short.23/)

The authors' MIT-licensed [code](https://github.com/dgaddy/silent_speech) includes
direct EMG-to-text recognition with a CTC decoder. Its README reports roughly
28% WER for that recognition model, and roughly 36% for the latest speech
synthesis evaluation; those are different tasks. It assumes a CUDA-oriented
environment, normalization, alignments and language-model dependencies. Those
published results do not establish robustness on a new person, sensor placement
or Mac implementation.

Public artifacts exist:

| Artifact | Published size / form | Use for us |
| --- | --- | --- |
| [Facial EMG dataset](https://zenodo.org/records/4064409) | 3.9 GB compressed; per example includes a `(T, 8)` EMG array and metadata | Evaluate a compatible decoder on recorded signals before buying hardware |
| [EMG-to-text checkpoint](https://zenodo.org/records/7183877) | 216.6 MB | Inspect loading and portability after checking asset terms |

Code licensing does not automatically establish the license of every dataset
and checkpoint. Both Zenodo records' API metadata specifies **CC-BY-4.0**:
[checkpoint metadata](https://zenodo.org/api/records/7183877),
[dataset metadata](https://zenodo.org/api/records/4064409). Attribution must be
preserved if those assets are used. We have not downloaded or bundled these
artifacts, trained on them, or claimed an EMG result in this fork.

### AirPods motion: an experiment, not a general speech decoder

[Subvox](https://github.com/joeblau/subvox) is an inspectable MIT-licensed Mac
prototype based on headphone motion. Its current README describes small-word-
set template matching with dynamic time warping, leave-one-out evaluation and a
500-shuffle label-permutation test. It notes processed motion around 25 Hz,
user/session-specific templates and lack of access to the inward microphone or
speech-detecting accelerometer. This is not demonstrated equivalence to an
open-vocabulary RF system.

[Apple's Core Motion documentation](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)
confirms that supported headphones can provide processed motion updates. It
does not promise silent-speech information in those updates. An AirPods branch
would therefore test whether information is present, using held-out sessions,
negative controls and chance baselines before attempting open-ended text.

### Acoustic sensing: different hardware again

Cornell's [EchoSpeech](https://news.cornell.edu/stories/2023/04/ai-equipped-eyeglasses-can-read-silent-speech)
uses small speakers and microphones on glasses to measure echoes of mouth
movement. The university describes 31 unvocalized commands and approximately
95% accuracy. A constrained-command result is not an open-ended dictation WER.
It also requires sensing geometry and active probing that a normal laptop
microphone recording does not reproduce.

## Implemented now: Speech Lab

This is a useful experiment we can run with today's hardware, not a claim of
reimplementing the proprietary wearable. No Subvocal code, brand assets, model
weights or device integration are included.

The native sidebar has a **Speech Lab** page. It uses the existing local engine
and makes the following actions explicit:

1. Choose a microphone, an optional reference, a normal/whisper condition and
   0, +12 or +24 dB digital gain. The condition is a label, not an ASR model switch.
2. Click **Record**, speak, then **Stop & test**. Capture stops at 30 seconds.
   Alternatively import a short audio file or run the bundled startup sample.
3. Inspect **Parakeet heard** and **LFM3 wrote** independently.
4. Compare raw word error rate, rewritten word difference rate, input level,
   clipped-sample count, ASR/refiner time and complete batch processing time.
5. Play the original recording and ASR input separately. Compare recent trials
   or export a JSON report. Audio is excluded from that report.
6. New recordings and transcripts appear in **Notes**, unless **Save recordings
   and transcripts in Notes** is turned off. Existing saved dictations also
   appear there. Notes provides playback, file reveal and Move to Trash.

The lab uses a batch preview command rather than the normal insertion path.
It does not paste text, expand macros, read the screen or register recordings in
the regular dictation corpus. With saving on, original audio, the exact 16 kHz
ASR WAV, and metadata live under
`~/Library/Application Support/Phonon/SpeechLabNotes/<utterance-id>/`. Audio is
saved before recognition, so a model failure does not discard the recording;
the raw transcript and rewrite are added as they arrive. These Notes are kept
until deleted. With saving off, latest audio is retained in memory for playback
and temporary files are removed after testing or normal shutdown. A crash can
leave temporary files until the OS clears them. The bundled **Test sample**
does not create a Note. No new cloud API is introduced.

Capture uses the same CoreAudio recorder and microphone selection as regular
dictation, retaining native-rate float audio. Apple's band-limited
`AVAudioConverter` prepares the 16 kHz PCM16 model input; raw playback is not
restricted to that recognition bandwidth. See
[Apple's sample-rate conversion note](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions).
This corrects the experiment's capture consistency and conversion path; it is
not evidence that the unchanged acoustic model recognizes all real whispers.

Fixed gain scales speech and noise together. It may help or hurt a particular
clip; the measurements make clipping visible. It is not a whisper-trained ASR
model or a denoiser. Digital silence is rejected before recognition. Other
non-speech noise may still cause ASR hallucinations, which remain visible in the
lab and never cause automatic actions.

### First experiment protocol

Use the same 10 short, held-out sentences in each condition. Include names,
numbers, technical terms, a negation and a mid-sentence correction. For each:

- Record normal voice and whisper at the same measured microphone distance.
- Repeat each condition with gain off and +12 dB; try +24 dB only when clipping
  remains absent. Randomize order and repeat on another day.
- Add ambient-room noise without speech as a negative control. Silence or
  noise should not yield usable text. Do not count guessed output as recognition.
- Enter the words actually spoken as reference. Score raw ASR separately from
  LFM3 output, since rewriting deliberately changes wording.
- Summarize median and p90 batch latency, WER, empty outputs, hallucinations and
  clipped takes by condition. Keep session-level holdouts for any later tuning.

The bundled sample is normal voiced speech. Lowering its amplitude tests level
sensitivity, **not** the spectral and phonetic changes of a real whisper.
Successful sample replay is an integration check, not an accuracy benchmark.

Run the packaged-engine smoke test with:

```bash
python3 scripts/check-speech-lab.py --out /tmp/phonon-lab-check.json
```

It blocks network access for the engine and children, rejects invalid preview
IDs, replays normal and attenuated samples, checks that raw and refined results
arrive, and verifies that the regular corpus directory is unchanged. It uses no
microphone or text insertion. The Swift suite separately tests metrics,
clipping, silence rejection, temporary-file cleanup and stale-event handling.

Decision rule for this first pass: continue only if real whispered takes provide
adequate raw recognition on the user's workload. A fluent LFM3 guess must not
substitute for adequate acoustic evidence. Pick an acceptable WER and latency
before comparing conditions, rather than selecting the easiest examples later.

## Path to real silent input

The next input interface should accept decoder text with an utterance ID,
partial/final state, timestamps, source modality and confidence when available.
It should reuse the lab's preview/refinement path first; insertion is a separate
user action. This is a proposed boundary, not a claim that a Subvocal SDK exists.

Required work before enabling any RF/EMG source:

1. Obtain a sensor with documented raw data access and compatible sampling,
   synchronization and placement. Do not treat a generic Bluetooth microphone
   as a physiological sensor.
2. Establish a held-out signal-to-text baseline with the correct decoder and
   normalization. Record silence, chewing, walking and non-speech movement.
3. Measure cross-session and cross-user errors, calibration cost and uncertainty.
   Compare before and after optional language cleanup.
4. Port or train an appropriate decoder for local inference, measuring memory,
   energy and latency on the target Mac. No such port is completed here.
5. Only then connect it to the normal dictation/insertion flow.

For a microphone-only product experiment, the practical next improvement is a
measured whisper-capable acoustic model or front end. For a truly silent one,
sensor acquisition and a physiological decoder are the first dependency.
