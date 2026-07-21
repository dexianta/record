using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Record;

internal enum AudioTrack
{
    System,
    Microphone
}

internal sealed record RecordingResult(string OutputPath, string? Warning = null);

internal sealed class CaptureSession : IAsyncDisposable
{
    private static readonly WaveFormat CaptureFormat = new(48_000, 16, 2);
    private readonly RecordingClock _clock = new();
    private WasapiRecorder? _systemRecorder;
    private WasapiRecorder? _microphoneRecorder;
    private TimedWaveWriter? _systemWriter;
    private TimedWaveWriter? _microphoneWriter;
    private string? _systemRecoveryPath;
    private string? _microphoneRecoveryPath;
    private string? _finalBasePath;
    private bool _started;
    private bool _stopping;
    private bool _disposed;

    public static string RecordingsFolder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Record",
        "Recordings");

    public event Action<AudioTrack, double>? LevelChanged;
    public event Action<string>? Faulted;

    public bool IsPaused => _clock.IsPaused;
    public TimeSpan Elapsed => _clock.Elapsed;

    public async Task StartAsync(AudioSourceItem source)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_started)
        {
            throw new InvalidOperationException("This recording session has already started.");
        }

        Directory.CreateDirectory(RecordingsFolder);
        CreatePaths(source.DisplayName);
        _systemWriter = new TimedWaveWriter(_systemRecoveryPath!, CaptureFormat);
        _microphoneWriter = new TimedWaveWriter(_microphoneRecoveryPath!, CaptureFormat);

        try
        {
            _systemRecorder = await CreateSystemRecorderAsync(source);
            _microphoneRecorder = new WasapiRecorderBuilder()
                .WithFormat(CaptureFormat)
                .WithBufferLength(50)
                .WithMmcssThreadPriority("Audio")
                .Build();

            _systemRecorder.DataAvailable += OnSystemData;
            _microphoneRecorder.DataAvailable += OnMicrophoneData;
            _systemRecorder.RecordingStopped += OnRecorderStopped;
            _microphoneRecorder.RecordingStopped += OnRecorderStopped;

            _clock.Start();
            _systemRecorder.StartRecording();
            _microphoneRecorder.StartRecording();
            _started = true;
        }
        catch
        {
            _stopping = true;
            _clock.Stop();
            await DisposeRecordersAsync();
            DisposeWriters();
            if (_systemRecoveryPath is not null && _microphoneRecoveryPath is not null)
            {
                DeleteRecoveryTracks(_systemRecoveryPath, _microphoneRecoveryPath);
            }
            throw;
        }
    }

    public bool Pause() => _started && !_stopping && _clock.Pause();

    public bool Resume() => _started && !_stopping && _clock.Resume();

    public async Task<RecordingResult> StopAsync()
    {
        if (!_started)
        {
            throw new InvalidOperationException("No recording is in progress.");
        }
        if (_stopping)
        {
            throw new InvalidOperationException("The recording is already stopping.");
        }

        _stopping = true;
        _clock.Stop();
        Exception? stopError = null;

        try
        {
            await Task.WhenAll(
                StopRecorderAsync(_systemRecorder),
                StopRecorderAsync(_microphoneRecorder));
        }
        catch (Exception error)
        {
            stopError = error;
        }
        finally
        {
            await DisposeRecordersAsync();
            DisposeWriters();
        }

        var result = await Task.Run(FinalizeRecording);
        if (stopError is not null)
        {
            return result with { Warning = $"The audio devices stopped with a warning: {stopError.Message}" };
        }
        return result;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _stopping = true;
        _clock.Stop();

        try
        {
            await Task.WhenAll(
                StopRecorderAsync(_systemRecorder),
                StopRecorderAsync(_microphoneRecorder));
        }
        catch
        {
            // Recovery files remain usable because their headers are refreshed every five seconds.
        }
        finally
        {
            await DisposeRecordersAsync();
            DisposeWriters();
        }
    }

    private async Task<WasapiRecorder> CreateSystemRecorderAsync(AudioSourceItem source)
    {
        var builder = new WasapiRecorderBuilder()
            .WithFormat(CaptureFormat)
            .WithBufferLength(50)
            .WithMmcssThreadPriority("Audio");

        if (source.ProcessId is int processId)
        {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
            {
                throw new PlatformNotSupportedException(
                    "Recording one selected app requires Windows build 20348 or newer (normally Windows 11). "
                    + "Choose All system audio on this version of Windows.");
            }

            try
            {
                using var process = Process.GetProcessById(processId);
                if (process.HasExited)
                {
                    throw new InvalidOperationException("The selected app is no longer running.");
                }
            }
            catch (ArgumentException)
            {
                throw new InvalidOperationException("The selected app is no longer running.");
            }

            return await builder
                .WithProcessLoopback((uint)processId, ProcessLoopbackMode.IncludeTargetProcessTree)
                .BuildAsync();
        }

        return builder.WithLoopbackCapture().Build();
    }

    private void OnSystemData(ReadOnlySpan<byte> buffer, AudioClientBufferFlags _, long __, long qpcPosition)
    {
        if (_systemWriter?.Write(buffer, qpcPosition, _clock) == true)
        {
            LevelChanged?.Invoke(AudioTrack.System, MeasureLevel(buffer));
        }
    }

    private void OnMicrophoneData(ReadOnlySpan<byte> buffer, AudioClientBufferFlags _, long __, long qpcPosition)
    {
        if (_microphoneWriter?.Write(buffer, qpcPosition, _clock) == true)
        {
            LevelChanged?.Invoke(AudioTrack.Microphone, MeasureLevel(buffer));
        }
    }

    private void OnRecorderStopped(object? sender, StoppedEventArgs args)
    {
        if (_stopping || !_started)
        {
            return;
        }

        var detail = args.Exception?.Message ?? "Windows stopped an audio capture device.";
        Faulted?.Invoke(detail);
    }

    private static async Task StopRecorderAsync(WasapiRecorder? recorder)
    {
        if (recorder is null || recorder.CaptureState == CaptureState.Stopped)
        {
            return;
        }

        var stopped = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<StoppedEventArgs>? handler = null;
        handler = (_, args) =>
        {
            recorder.RecordingStopped -= handler;
            stopped.TrySetResult(args.Exception);
        };
        recorder.RecordingStopped += handler;

        try
        {
            recorder.StopRecording();
            var completed = await Task.WhenAny(stopped.Task, Task.Delay(TimeSpan.FromSeconds(8)));
            if (completed != stopped.Task)
            {
                recorder.RecordingStopped -= handler;
                throw new TimeoutException("Windows did not close an audio device within eight seconds.");
            }

            if (await stopped.Task is Exception error)
            {
                throw error;
            }
        }
        catch
        {
            recorder.RecordingStopped -= handler;
            throw;
        }
    }

    private async Task DisposeRecordersAsync()
    {
        if (_systemRecorder is not null)
        {
            _systemRecorder.DataAvailable -= OnSystemData;
            _systemRecorder.RecordingStopped -= OnRecorderStopped;
            await _systemRecorder.DisposeAsync();
            _systemRecorder = null;
        }
        if (_microphoneRecorder is not null)
        {
            _microphoneRecorder.DataAvailable -= OnMicrophoneData;
            _microphoneRecorder.RecordingStopped -= OnRecorderStopped;
            await _microphoneRecorder.DisposeAsync();
            _microphoneRecorder = null;
        }
    }

    private void DisposeWriters()
    {
        _systemWriter?.Dispose();
        _systemWriter = null;
        _microphoneWriter?.Dispose();
        _microphoneWriter = null;
    }

    private RecordingResult FinalizeRecording()
    {
        var systemPath = _systemRecoveryPath
            ?? throw new InvalidOperationException("The system-audio recovery path is missing.");
        var microphonePath = _microphoneRecoveryPath
            ?? throw new InvalidOperationException("The microphone recovery path is missing.");
        var finalBasePath = _finalBasePath
            ?? throw new InvalidOperationException("The final recording path is missing.");

        var mp4Path = finalBasePath + ".mp4";
        var temporaryMp4Path = finalBasePath + ".encoding.mp4";
        try
        {
            using (var provider = new SeparatedStereoProvider(systemPath, microphonePath))
            {
                MediaFoundationEncoder.EncodeToAac(provider, temporaryMp4Path, 128_000);
            }
            ValidateOutput(temporaryMp4Path);
            File.Move(temporaryMp4Path, mp4Path);
            DeleteRecoveryTracks(systemPath, microphonePath);
            return new RecordingResult(mp4Path);
        }
        catch (Exception aacError)
        {
            TryDelete(temporaryMp4Path);
            var wavPath = finalBasePath + ".wav";
            try
            {
                using var provider = new SeparatedStereoProvider(systemPath, microphonePath);
                WaveFileWriter.CreateWaveFile(wavPath, provider);
                ValidateOutput(wavPath);
                DeleteRecoveryTracks(systemPath, microphonePath);
                return new RecordingResult(wavPath, $"AAC encoding was unavailable, so Record saved WAV instead: {aacError.Message}");
            }
            catch (Exception wavError)
            {
                TryDelete(wavPath);
                throw new InvalidOperationException(
                    $"Could not finish the audio file. The recovery tracks were kept in the recordings folder. "
                    + $"AAC: {aacError.Message} WAV: {wavError.Message}",
                    wavError);
            }
        }
    }

    private void CreatePaths(string sourceName)
    {
        var safeSource = SanitizeFileName(sourceName);
        var timestamp = DateTime.Now.ToString("yyyy-MM-dd 'at' HH.mm.ss");
        var baseName = $"Recording {timestamp} – {safeSource}";
        var candidate = Path.Combine(RecordingsFolder, baseName);
        var suffix = 2;
        while (File.Exists(candidate + ".mp4")
            || File.Exists(candidate + ".wav")
            || File.Exists(candidate + ".system.recovery.wav")
            || File.Exists(candidate + ".microphone.recovery.wav"))
        {
            candidate = Path.Combine(RecordingsFolder, $"{baseName} {suffix++}");
        }

        _finalBasePath = candidate;
        _systemRecoveryPath = candidate + ".system.recovery.wav";
        _microphoneRecoveryPath = candidate + ".microphone.recovery.wav";
    }

    private static string SanitizeFileName(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(value.Select(character => invalid.Contains(character) ? '-' : character).ToArray());
        clean = string.Join(' ', clean.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return clean.Length <= 64 ? clean : clean[..64].TrimEnd();
    }

    private static double MeasureLevel(ReadOnlySpan<byte> buffer)
    {
        var sampleCount = buffer.Length / 2;
        if (sampleCount == 0)
        {
            return 0;
        }

        double sum = 0;
        for (var offset = 0; offset + 1 < buffer.Length; offset += 2)
        {
            var sample = BinaryPrimitives.ReadInt16LittleEndian(buffer.Slice(offset, 2)) / 32768.0;
            sum += sample * sample;
        }

        var rms = Math.Sqrt(sum / sampleCount);
        if (rms <= 0.00001)
        {
            return 0;
        }
        var decibels = 20 * Math.Log10(rms);
        return Math.Clamp((decibels + 60) / 60, 0, 1);
    }

    private static void ValidateOutput(string path)
    {
        if (!File.Exists(path) || new FileInfo(path).Length < 1024)
        {
            throw new InvalidDataException("The encoded recording is empty.");
        }
    }

    private static void DeleteRecoveryTracks(string systemPath, string microphonePath)
    {
        TryDelete(systemPath);
        TryDelete(microphonePath);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // A completed recording is more important than cleanup of a temporary file.
        }
    }
}
