using System.Buffers.Binary;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Record;

internal static class AudioSelfCheck
{
    private static readonly WaveFormat Format = new(48_000, 16, 2);

    public static async Task RunAsync()
    {
        var stage = "checking the Windows version";
        try
        {
            Require(OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348),
                "selected-app capture needs Windows build 20348 or newer");

            stage = "opening selected-app capture";
            await using var processCapture = await new WasapiRecorderBuilder()
                .WithProcessLoopback((uint)Environment.ProcessId, ProcessLoopbackMode.IncludeTargetProcessTree)
                .WithFormat(Format)
                .WithBufferLength(50)
                .BuildAsync();

            stage = "opening all-system capture";
            await using var systemCapture = new WasapiRecorderBuilder()
                .WithLoopbackCapture()
                .WithFormat(Format)
                .WithBufferLength(50)
                .Build();

            stage = "opening the default microphone";
            await using var microphoneCapture = new WasapiRecorderBuilder()
                .WithFormat(Format)
                .WithBufferLength(50)
                .Build();

            stage = "opening the default speakers";
            await using var player = new WasapiPlayerBuilder()
                .WithLatency(50)
                .Build();

            long processBytes = 0;
            long systemBytes = 0;
            long microphoneBytes = 0;
            double processPeak = 0;
            double systemPeak = 0;
            processCapture.DataAvailable += (buffer, _, _, _) =>
            {
                Interlocked.Add(ref processBytes, buffer.Length);
                processPeak = Math.Max(processPeak, Peak(buffer));
            };
            systemCapture.DataAvailable += (buffer, _, _, _) =>
            {
                Interlocked.Add(ref systemBytes, buffer.Length);
                systemPeak = Math.Max(systemPeak, Peak(buffer));
            };
            microphoneCapture.DataAvailable += (buffer, _, _, _) =>
                Interlocked.Add(ref microphoneBytes, buffer.Length);

            stage = "starting audio capture";
            processCapture.StartRecording();
            systemCapture.StartRecording();
            microphoneCapture.StartRecording();
            await Task.WhenAll(
                WaitForCaptureAsync(processCapture),
                WaitForCaptureAsync(systemCapture),
                WaitForCaptureAsync(microphoneCapture));

            var playbackStopped = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
            player.PlaybackStopped += (_, args) => playbackStopped.TrySetResult(args.Exception);
            var tone = new SignalGenerator(Format.SampleRate, Format.Channels)
            {
                Frequency = 880,
                Gain = 0.08
            }.Take(TimeSpan.FromMilliseconds(800));
            player.Init(tone.ToWaveProvider());

            stage = "playing and capturing the test tone";
            player.Play();
            var playbackError = await playbackStopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (playbackError is not null)
            {
                throw playbackError;
            }
            await Task.Delay(200);

            processCapture.StopRecording();
            systemCapture.StopRecording();
            microphoneCapture.StopRecording();
            await Task.WhenAll(
                WaitForStopAsync(processCapture),
                WaitForStopAsync(systemCapture),
                WaitForStopAsync(microphoneCapture));

            stage = "validating captured audio";
            Require(processBytes > 0 && processPeak > 0.01,
                "selected-app capture did not receive the test tone");
            Require(systemBytes > 0 && systemPeak > 0.01,
                "all-system capture did not receive the test tone");
            Require(microphoneBytes > 0,
                "the default microphone opened but delivered no audio buffers");
        }
        catch (Exception error) when (error is not InvalidOperationException
            || !error.Message.StartsWith(stage, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{stage}: {error.Message}", error);
        }
    }

    private static async Task WaitForStopAsync(WasapiRecorder recorder)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (recorder.CaptureState != CaptureState.Stopped && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }
        Require(recorder.CaptureState == CaptureState.Stopped, "an audio device did not stop in time");
    }

    private static async Task WaitForCaptureAsync(WasapiRecorder recorder)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (recorder.CaptureState == CaptureState.Starting && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }
        Require(recorder.CaptureState == CaptureState.Capturing, "an audio device did not start in time");
    }

    private static double Peak(ReadOnlySpan<byte> buffer)
    {
        var peak = 0.0;
        for (var offset = 0; offset + 1 < buffer.Length; offset += 2)
        {
            peak = Math.Max(peak, Math.Abs(BinaryPrimitives.ReadInt16LittleEndian(buffer[offset..]) / 32768.0));
        }
        return peak;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
