# Record

A small macOS and Windows recorder that saves your microphone together with system audio, even when the meeting is playing through headphones.

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

Pause is applied when the final M4A is saved. If export fails, the retained `.recording.mp4` recovery file is the uninterrupted capture and can include audio from paused periods.

## Build

This project uses only native Apple frameworks and Swift Package Manager:

```sh
swift run Record --self-check
./scripts/build-dmg.sh
```

The current DMG is Apple Silicon-only and ad-hoc signed for local testing. Public distribution requires a Developer ID certificate and Apple notarization.

## Windows

The native Windows version lives in [`windows/`](windows/README.md). It supports all-system audio or one selected app plus the microphone, visible level meters, and pause/resume without restarting the capture devices. All-system capture works on Windows 10; selected-app capture requires Windows build 20348 or newer (normally Windows 11).

Build and run it on Windows with the .NET 10 SDK:

```powershell
dotnet run --project .\windows\Record\Record.csproj
.\windows\build.ps1
```

The build script creates `dist\record-windows-x64.zip` with a self-contained `record.exe`.
