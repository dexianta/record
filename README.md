# Record

A small macOS recorder that saves your microphone together with system audio, even when the meeting is playing through headphones.

Download the latest Mac installer from [GitHub Releases](https://github.com/dexianta/record/releases/latest), open `record.dmg`, and drag **Record** to Applications.

## macOS

1. Open `dist/record.dmg` and drag **Record** to Applications.
2. Open the app. Because this development build is ad-hoc signed rather than notarized, macOS may require right-clicking the app and choosing **Open**.
3. Allow **Microphone** and **Screen & System Audio Recording** when macOS asks. Restart the app after granting Screen & System Audio access if the first attempt requests it.
4. Choose **All system audio** or a running app, check the two level meters, then click **Record**. Pause/Resume creates one gap-free final file.

Recordings are stored in:

```text
~/Library/Application Support/Meeting Audio/Recordings
```

Selecting Chrome records all Chrome audio; macOS cannot isolate a single browser tab. If **All system audio** is selected, notification sounds and music are also recorded, so Focus mode is useful. Make sure meeting participants have consented to recording.

Recordings are saved as M4A audio files, with paused gaps removed and no video track. The format works directly for transcription.

Click the transcription button to download a local Whisper model and transcribe a recording. To transcribe one again, click its circular-arrow button or right-click it and choose **Transcribe again**; the existing transcript is kept unless the new transcription succeeds. The default quantized Turbo model is 574 MB; the optional full Turbo model is 1.62 GB. Models are downloaded only when requested, transcription runs offline, and no Python, Homebrew, ffmpeg, API key, or account is required. Plain-text transcripts are saved beside their audio files.

Pause is applied when the final M4A is saved. If export fails, the retained `.recording.mp4` recovery file is the uninterrupted capture and can include audio from paused periods.

## Build

This project uses only native Apple frameworks and Swift Package Manager:

```sh
swift run Record --self-check
./scripts/build-dmg.sh
```

The current DMG is Apple Silicon-only. The build script automatically uses an installed Developer ID or Apple Development certificate; otherwise it falls back to ad-hoc signing. Rebuilt ad-hoc copies lose Screen & System Audio Recording permission because their code identity changes. Public distribution and a stable identity require a Developer ID certificate and Apple notarization.

## Updates

Record checks for updates hourly and includes a manual **Check for Updates** button in the upper-right toolbar, powered by Sparkle. Updates are read from [`appcast.xml`](appcast.xml), and release archives are hosted by GitHub Releases.

Publish a new version to GitHub Releases:

```sh
make publish 0.2.0
```

Run `make publish` without a version to show the latest published version. Publishing requires a clean working tree. The target builds `dist/record.dmg`, signs the in-app update with the `dexianta.record` Sparkle key in your login Keychain, creates the GitHub release, uploads both artifacts, then commits and pushes `appcast.xml`. It uses the Git commit count as the Sparkle build number. Keep an off-Mac backup of the Sparkle private key; never commit it to this repository.
