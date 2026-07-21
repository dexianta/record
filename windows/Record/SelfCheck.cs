using System.Buffers.Binary;
using System.IO;
using NAudio.Wave;

namespace Record;

internal static class SelfCheck
{
    private static readonly WaveFormat Format = new(48_000, 16, 2);

    public static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"record-self-check-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);

        try
        {
            var systemPath = Path.Combine(directory, "system.wav");
            var microphonePath = Path.Combine(directory, "microphone.wav");
            var outputPath = Path.Combine(directory, "self-check.mp4");
            WriteTrack(systemPath, 4_000);
            WriteTrack(microphonePath, -2_000);

            using (var separated = new SeparatedStereoProvider(systemPath, microphonePath))
            {
                Span<byte> frame = stackalloc byte[4];
                Require(separated.Read(frame) == frame.Length, "could not read the separated tracks");
                Require(BinaryPrimitives.ReadInt16LittleEndian(frame[..2]) == 4_000,
                    "system audio was not preserved on the left channel");
                Require(BinaryPrimitives.ReadInt16LittleEndian(frame[2..]) == -2_000,
                    "microphone audio was not preserved on the right channel");
            }

            using (var separated = new SeparatedStereoProvider(systemPath, microphonePath))
            {
                MediaFoundationEncoder.EncodeToAac(separated, outputPath, 128_000);
            }
            Require(new FileInfo(outputPath).Length > 1_024, "AAC output is empty");

            using var decoded = new MediaFoundationReader(outputPath);
            var buffer = new byte[Math.Max(decoded.WaveFormat.BlockAlign, decoded.WaveFormat.AverageBytesPerSecond / 10)];
            var alignedLength = buffer.Length - buffer.Length % decoded.WaveFormat.BlockAlign;
            Require(decoded.Read(buffer.AsSpan(0, alignedLength)) > 0, "AAC output cannot be decoded");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void WriteTrack(string path, short sample)
    {
        using var writer = new WaveFileWriter(path, Format);
        Span<byte> frame = stackalloc byte[Format.BlockAlign];
        BinaryPrimitives.WriteInt16LittleEndian(frame[..2], sample);
        BinaryPrimitives.WriteInt16LittleEndian(frame[2..], sample);
        for (var index = 0; index < Format.SampleRate; index++)
        {
            writer.Write(frame);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
