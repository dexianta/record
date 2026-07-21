# Record for Windows

Small native Windows recorder for system/app audio plus the default microphone.

## Requirements

- Windows 10 22H2 or Windows 11
- .NET 10 SDK to build
- Windows microphone access enabled for desktop apps

## Run from source

```powershell
dotnet run --project .\Record\Record.csproj
```

Choose **All system audio** or a running app, then press the red record button. Selected-app capture includes that process and its child processes. It requires Windows build 20348 or newer, which normally means Windows 11 on consumer PCs; Windows 10 users can record **All system audio**. Browsers do not expose reliable per-tab audio capture through the Windows process-loopback API, so selecting Chrome or Edge records the browser process tree.

Recordings are saved under `%LOCALAPPDATA%\Record\Recordings`. Meeting audio is stored on the left channel and the microphone on the right channel, which preserves clean source separation for later transcription. The normal output is AAC in an `.mp4` audio container; if AAC encoding is unavailable, Record saves a `.wav` file instead.

## Build a portable app

From PowerShell:

```powershell
.\build.ps1
```

This runs `record.exe --self-check` to verify stereo separation and Windows AAC encode/decode support, then creates `dist\record-windows-x64.zip` containing the self-contained Windows app.

On the Windows PC that will run Record, verify the real audio paths once:

```powershell
(Start-Process .\record.exe -ArgumentList --audio-self-check -Wait -PassThru).ExitCode
```

The check plays a short, quiet tone and expects exit code `0`. It verifies selected-app capture, all-system capture, the default microphone, and AAC playback through the same Windows APIs used by the app.

This prototype build is not code-signed, so Windows SmartScreen may show an unrecognized-app warning. A public release should be signed with a trusted Windows code-signing certificate.
