# Capture reliability QA

These checks exercise the real CoreAudio capture graph in a disposable library.
They do not explain why macOS originally omitted a tap. Use generated audio or
an openly licensed clip, not a private meeting, and do not overwrite the
installed app.

## Build a disposable debug app

```sh
BLAISE_BUNDLE_ID=app.blaise.captureqa BLAISE_APP_DISPLAY_NAME="Blaise QA" scripts/build_app.sh
source scripts/env.sh
(cd app && "$SWIFT" build --product Blaise)
qa_root="$(mktemp -d /tmp/blaise-capture-qa.XXXXXX)"
mkdir -p "$qa_root/data"
ditto dist/Blaise.app "$qa_root/Blaise QA.app"
cp app/.build/debug/Blaise "$qa_root/Blaise QA.app/Contents/MacOS/Blaise"
for bundle in app/.build/debug/*.bundle; do
    ditto "$bundle" "$qa_root/Blaise QA.app/Contents/Resources/$(basename "$bundle")"
done
codesign --force --sign - "$qa_root/Blaise QA.app"
```

The separate QA bundle identifier keeps GUI QA out of existing app Keychain
namespaces. A temporary meeting directory alone does **not** isolate Keychain
access. An ad-hoc rebuild under an existing identifier can repeatedly prompt
for access to previously stored credentials. Cancel such prompts; use a
separate QA identity or the capture-only harness below instead.

The QA identity may require its own macOS Microphone and System Audio Recording
grants. Do not change the production app's permissions. Skip optional identity
setup; no cloud account or delivery destination is needed.

## Missing tap, bounded retries, and manual recovery

```sh
BLAISE_DATA_ROOT="$qa_root/data" BLAISE_CAPTURE_TEST_OMIT_TAP_BUILDS=3 \
    "$qa_root/Blaise QA.app/Contents/MacOS/Blaise"
```

1. Start recording. The debug switch removes the tap from the initial aggregate
   and the next two aggregate builds, while retaining the real microphone.
2. Confirm the persistent missing-call-audio banner and library warning. Logs
   must show one microphone stream, no active tap, and exactly two automatic
   recovery attempts; recording must continue with the warning after them.
3. Play the reference audio from an independent application such as Chrome.
   A player launched as the capture process's child may be excluded by the tap.
4. Press Retry Call Audio. The fourth build includes the real tap. The live
   warning must clear only after system frames are written.
5. Pause to finalize the audio without requesting transcription. Confirm the
   incomplete-capture note remains in the library and database. Decode both
   retained tracks and verify that recovered audio appears at its original
   microphone-timeline position, with silence in the missing system interval.
6. Quit & Keep Paused. Do not confuse a cleared live warning with recovery of
   the earlier missing conversation.

## Prove the source is system audio, not speaker bleed

Use the capture-only harness to avoid constructing the GUI's Keychain, account,
and delivery services. Build `CrashRunner`, copy it into the disposable QA
bundle as its executable, and sign that bundle again:

```sh
(cd app && "$SWIFT" build --product CrashRunner)
cp app/.build/debug/CrashRunner "$qa_root/Blaise QA.app/Contents/MacOS/Blaise"
codesign --force --sign - "$qa_root/Blaise QA.app"
mkdir -p "$qa_root/mic-free-data"
BLAISE_DATA_ROOT="$qa_root/mic-free-data" BLAISE_CAPTURE_TEST_OMIT_MIC=1 \
    "$qa_root/Blaise QA.app/Contents/MacOS/Blaise" capture-probe "$qa_root/mic-free-data" 30
```

The probe records for the supplied 1–60 seconds, then stops and finalizes its
tracks without transcription or delivery. Do not open this harness bundle with
Launch Services or a GUI automation tool; launch the executable as shown so the
explicit environment and arguments are retained. Omit the tap-fault switch.
The mic-free switch removes the microphone sub-device and its clock designation
from the aggregate. Logs must report **zero mic streams, one active tap, and
one aggregate stream**.

Play the reference clip in Chrome during the bounded probe. The system M4A must contain the
reference clip, while the zero-frame microphone CAF produces no microphone
M4A. This isolation is necessary: playing through speakers with the microphone
connected is not, by itself, proof of process-tap capture. A mic warning during
this test is expected.

Both switches require an existing directory under the macOS temporary directory
or `/private/tmp`. Tap omission is bounded to 1–3 builds. The switches and
omission code are compiled only in DEBUG builds; release builds ignore them.
Unit tests pin the opt-in, temporary-root, and bounds checks.

## Other validation still needed

- Independent Slack playback or a controlled call.
- A real system stream that stalls after capture begins, including route changes.
- Denied permission and disabled-notification presentation.
- A signed production build with the production permission identity.

The ordinary unit suite covers frame-stall detection, silence discrimination,
CAF alignment, callback provenance, and note persistence through regeneration.
Those checks complement, but do not replace, real-device QA.
