# Murmur Lab guide

Murmur Lab is our experimental Phonon fork. **Speech Lab** is the page inside
the app for comparing normal and whispered microphone recordings. It uses
Parakeet for recognition and LFM3 for text cleanup. We have not trained a new
model or implemented Subvocal's RF sensing. See the
[Subvocal research and experiment protocol](subvocal-research.md) for the
evidence and the limits of a microphone-only experiment.

Source: [chintan-projects/phonon, codex/quiet-speech-lab](https://github.com/chintan-projects/phonon/tree/codex/quiet-speech-lab).
The parent `agentarmy` checkout is a workspace; this fork is its own Git
repository. App bundles and local verification artifacts are not a GitHub DMG
release. The upstream GPL license and separate model licenses still apply;
see [License](../README.md#license) and [THIRD_PARTY.md](../THIRD_PARTY.md).

## Record and find a take

1. Open **Murmur Lab**, wait for the local models to be ready, and open
   **Speech Lab**. Quit and reopen the app after installing an updated build.
2. Choose **Microphone**. **Automatic (same as dictation)** uses the regular
   dictation microphone resolver; an explicit choice changes the shared
   microphone preference.
3. Enter the words you will actually say in **Reference sentence**, or clear
   it for free dictation without a word-error score.
4. Choose **Normal speech** or **Whisper**, and **Digital gain** Off, +12 dB
   or +24 dB. Both conditions use the same Parakeet model. The condition is an
   experiment label; gain changes the audio sent to recognition. Start with
   the setting that works for your microphone and compare held-out takes.
5. Leave **Save recordings and transcripts in Notes** enabled to keep the
   take. Click **Record**, speak, then **Stop & test**. Recording ends
   automatically at 30 seconds. This button workflow does not require holding
   the global dictation hotkey.
6. Compare **PARAKEET HEARD** with **LFM3 WROTE**. Use **Play original** to
   hear the source and **Play ASR input** to hear the converted, amplified
   audio supplied to recognition.
7. Click **Open Notes**, or choose **Notes** in the sidebar. The recording is
   saved before model recognition starts, then its transcripts update as the
   model results arrive. A model failure retains an already saved recording
   and records the error. Check the save status if a take is missing.

**Import audio…** accepts WAV, AIFF and M4A files up to 30 seconds, using the
same gain and saving choices. **Test sample** replays bundled normal speech
without creating a Note. Speech Lab never automatically pastes its output
into another app.

Condition, gain and the saving toggle persist across restarts. The reference,
session trial list and current playback selection do not. The view keeps up to
30 completed trials in memory and displays the latest five; **Export results…**
exports those session trials as JSON containing text, references and metrics,
without audio. Persistent Notes are independent of that session list.

## Storage and deletion

The fork keeps Phonon's existing support directory and model cache. Its
distinct app name, teal waveform icon and bundle ID `com.chintan.phononlab`
do not create an isolated data profile. Phonon and Murmur Lab also share a
single-instance lock; run one app at a time.

```text
~/Library/Application Support/Phonon/
├── speech-lab-settings.json
├── SpeechLabNotes/
│   └── speech-lab-<uuid>/
│       ├── original.caf       # native-rate microphone recording
│       ├── asr.wav            # mono PCM16, 16 kHz, with selected digital gain
│       └── note.json          # reference, settings, measurements and transcripts
├── Corpus/                    # regular dictations when local history is on
└── Meetings/                  # existing meeting recordings
```

Imported originals retain a supported source extension instead of `.caf`.
Notes lists saved Speech Lab takes, existing dictations whose audio is still
present, and meetings. Lab takes do not enter `Corpus/` or change Home and
Insights dictation metrics.

| Action | Effect on Speech Lab recordings |
| --- | --- |
| Save toggle on | New takes save locally until deleted; successful model results update the saved Note. |
| Save toggle off | New takes are temporary; the latest audio remains in memory for playback. Existing saved Notes remain. |
| Clear view | Clears the lab's current result, session list and playback memory; saved Notes remain. |
| Notes → Move to Trash | Moves that saved take's audio and metadata folder to macOS Trash after confirmation. |
| Settings → Keep recordings for / Clear all history | Applies to regular dictation history, not `SpeechLabNotes/`. |
| Speech Lab → Export results | Saves session text and metrics, excluding audio. |
| Settings → Backup → export | Copies the support data, including Speech Lab files, to the chosen local destination. |

Temporary work files are removed after processing or normal shutdown. A crash
can leave temporary files until the OS clears them. The small automatic mirror
at `~/.phonon/backup` does not include Speech Lab audio, Notes or lab preferences;
keep a separate copy or use the full data export when needed.

The first Speech Lab version kept only temporary recordings and session text.
Those old recordings cannot be recovered by upgrading. The saving behavior
above was introduced in feature commit `dc621a3`.

## Understand the results

Capture shares normal dictation's CoreAudio recorder and preserves the native
sample rate in the original CAF. A band-limited `AVAudioConverter` prepares
the 16 kHz ASR file, including draining short reads rather than truncating a
take. Fixed digital gain amplifies noise as well as speech; inspect the clipped
sample count before increasing it.

**Raw word error** compares Parakeet with the reference, ignoring case and
punctuation. **Rewrite difference** measures LFM3's word differences from that
reference, and can include intentional cleanup. A fluent rewrite can conceal
a recognition error, so evaluate the raw transcript separately. **Batch
processing** excludes recording and OS text insertion; it is not streaming
hotkey-release latency.

The lab rejects digital silence. Other non-speech sounds can still produce
ASR hallucinations. Whisper recognition quality needs real microphone trials:
lowering the volume of normal speech does not reproduce whisper acoustics.
No microphone setting here can decode unspoken, silent mouthing.

Recognition, rewriting, playback and storage run on the Mac. Initial runtime
and model downloads need network access when not cached. This lab build does
not check for stock release updates. Its preview path does not request screen
or text-box context, expand macros, use the clipboard or insert text.

## Build and open the fork

Use an Apple silicon Mac running macOS 14 or later, a working Xcode/Command
Line Tools installation with Swift, and Rust/Cargo. The wrapper reuses native
helpers and bundled `uv` from a verified upstream Phonon release app, while
building the changed Swift UI and Rust coordinator from this checkout.

From the repository root, with no existing bundle at the output path:

```bash
PHONON_LAB_ENGINE_APP="/path/to/verified/Phonon.app" bash scripts/package-lab.sh
open "bar/dist/Murmur Lab.app"
```

Without that environment variable, the wrapper expects the local release copy
at `../verification/Phonon.app`; that copy is not included in Git. Quit the
currently running Phonon or Murmur Lab before opening the new build. The app is
ad-hoc signed, rather than notarized as an official release; macOS permissions
may need granting again after a rebuild.

To stage a new build while preserving an existing app, choose a new output
path whose parent directory already exists:

```bash
mkdir -p bar/dist/updates
PHONON_LAB_ENGINE_APP="/path/to/verified/Phonon.app" \
PHONON_LAB_OUTPUT="$PWD/bar/dist/updates/Murmur Lab.app" \
  bash scripts/package-lab.sh
```

The wrapper refuses to overwrite an existing output bundle. Quit the old app,
move its bundle aside, then move the staged bundle into its place and reopen
it. The support data stays outside the app. This wrapper uses the release
helpers; the upstream [engine build script](../scripts/build-engine.sh)
describes the separate route for compiling those native helpers from source.

## Verify and troubleshoot

From the repository root:

```bash
swift test --package-path bar
codesign --verify --deep --strict "bar/dist/Murmur Lab.app"
python3 scripts/check-speech-lab.py \
  --app "bar/dist/Murmur Lab.app" --out /tmp/murmur-lab-check.json
```

The offline check needs the model/runtime caches populated by an initial
successful launch. It denies network access for the engine and children,
uses no microphone or text insertion, rejects an invalid lab request ID and
replays normal, attenuated and attenuated-plus-gain sample audio. It checks
that raw and rewritten results arrive and that the top-level dictation corpus
entries are unchanged.

Validated on 5 November 2026 for implementation commit `dc621a3`, on the local
M4 Max Mac running macOS 26.6.2:

- Swift suite: 262 tests executed, one skipped, zero failures. Coverage includes
  saved Notes surviving reload, metadata updates, saving off, failed recognition,
  clearing without deleting, gain clipping, sample-rate conversion and UI renders.
- Packaged offline model check: passed; all three fixture variants produced
  `Hello Fluid Voice.` as both raw and refined output.
- Installed app signature: verified. The teal icon and Murmur Lab app identity
  were retained.

These checks establish integration and file handling. They do not establish
real whispered-speech accuracy or verify a live microphone recording.

If Notes is missing a take, reopen the updated app, check the saving toggle
and save status, and distinguish a recording from **Test sample**. If the
transcript is wrong, compare original and ASR playback, confirm the microphone,
check clipping and compare with a normal-voice take of the same sentence. Keep
the incorrect raw result when evaluating LFM3's rewrite.
