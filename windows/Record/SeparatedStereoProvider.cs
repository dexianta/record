using System.Buffers.Binary;
using System.IO;
using NAudio.Wave;

namespace Record;

internal sealed class SeparatedStereoProvider : IWaveProvider, IDisposable
{
    private readonly WaveFileReader _system;
    private readonly WaveFileReader _microphone;
    private byte[] _systemBuffer = Array.Empty<byte>();
    private byte[] _microphoneBuffer = Array.Empty<byte>();

    public SeparatedStereoProvider(string systemPath, string microphonePath)
    {
        _system = new WaveFileReader(systemPath);
        _microphone = new WaveFileReader(microphonePath);

        if (!FormatsMatch(_system.WaveFormat, _microphone.WaveFormat)
            || _system.WaveFormat.Encoding != WaveFormatEncoding.Pcm
            || _system.WaveFormat.BitsPerSample != 16
            || _system.WaveFormat.Channels != 2)
        {
            throw new InvalidDataException("The recovery tracks do not use the expected 16-bit stereo PCM format.");
        }

        WaveFormat = new WaveFormat(_system.WaveFormat.SampleRate, 16, 2);
    }

    public WaveFormat WaveFormat { get; }

    public int Read(Span<byte> output)
    {
        var outputLength = output.Length - output.Length % WaveFormat.BlockAlign;
        if (outputLength == 0)
        {
            return 0;
        }

        EnsureBuffers(outputLength);
        var systemBytes = _system.Read(_systemBuffer.AsSpan(0, outputLength));
        var microphoneBytes = _microphone.Read(_microphoneBuffer.AsSpan(0, outputLength));
        var sourceBytes = Math.Max(systemBytes, microphoneBytes);
        var frames = (sourceBytes + 3) / 4;
        if (frames == 0)
        {
            return 0;
        }

        for (var frame = 0; frame < frames; frame++)
        {
            var sourceOffset = frame * 4;
            var outputOffset = frame * 4;
            var systemMono = DownmixFrame(_systemBuffer, sourceOffset, systemBytes);
            var microphoneMono = DownmixFrame(_microphoneBuffer, sourceOffset, microphoneBytes);
            BinaryPrimitives.WriteInt16LittleEndian(output.Slice(outputOffset, 2), systemMono);
            BinaryPrimitives.WriteInt16LittleEndian(output.Slice(outputOffset + 2, 2), microphoneMono);
        }

        return frames * WaveFormat.BlockAlign;
    }

    public void Dispose()
    {
        _system.Dispose();
        _microphone.Dispose();
    }

    private void EnsureBuffers(int length)
    {
        if (_systemBuffer.Length < length)
        {
            _systemBuffer = new byte[length];
            _microphoneBuffer = new byte[length];
        }
    }

    private static short DownmixFrame(byte[] buffer, int offset, int available)
    {
        if (offset + 4 > available)
        {
            return 0;
        }

        var left = BinaryPrimitives.ReadInt16LittleEndian(buffer.AsSpan(offset, 2));
        var right = BinaryPrimitives.ReadInt16LittleEndian(buffer.AsSpan(offset + 2, 2));
        return (short)(((int)left + right) / 2);
    }

    private static bool FormatsMatch(WaveFormat left, WaveFormat right) =>
        left.SampleRate == right.SampleRate
        && left.BitsPerSample == right.BitsPerSample
        && left.Channels == right.Channels
        && left.Encoding == right.Encoding;
}
