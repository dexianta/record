using NAudio.Wave;

namespace Record;

internal sealed class TimedWaveWriter : IDisposable
{
    private static readonly byte[] Silence = new byte[32 * 1024];
    private readonly object _gate = new();
    private readonly WaveFileWriter _writer;
    private readonly WaveFormat _format;
    private long _framesWritten;
    private long _framesAtLastFlush;
    private bool _disposed;

    public TimedWaveWriter(string path, WaveFormat format)
    {
        _format = format;
        _writer = new WaveFileWriter(path, format, new WaveFileWriterOptions { EnableRf64 = true });
        _writer.Flush();
    }

    public bool Write(ReadOnlySpan<byte> packet, long packetQpc, RecordingClock clock)
    {
        var packetFrames = packet.Length / _format.BlockAlign;
        if (packetFrames == 0)
        {
            return false;
        }

        if (packetQpc <= 0)
        {
            var duration = packetFrames * TimeSpan.TicksPerSecond / _format.SampleRate;
            packetQpc = RecordingClock.QpcNow() - duration;
        }

        if (!clock.TryGetFramePosition(packetQpc, _format.SampleRate, out var targetFrame))
        {
            return false;
        }

        lock (_gate)
        {
            if (_disposed)
            {
                return false;
            }

            if (targetFrame > _framesWritten)
            {
                WriteSilence(targetFrame - _framesWritten);
            }
            else if (targetFrame < _framesWritten)
            {
                var overlapFrames = _framesWritten - targetFrame;
                if (overlapFrames >= packetFrames)
                {
                    return true;
                }

                packet = packet[(int)(overlapFrames * _format.BlockAlign)..];
                packetFrames -= (int)overlapFrames;
            }

            _writer.Write(packet);
            _framesWritten += packetFrames;

            if (_framesWritten - _framesAtLastFlush >= _format.SampleRate * 5L)
            {
                _writer.Flush();
                _framesAtLastFlush = _framesWritten;
            }
            return true;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _writer.Dispose();
        }
    }

    private void WriteSilence(long frames)
    {
        var bytesRemaining = frames * _format.BlockAlign;
        while (bytesRemaining > 0)
        {
            var count = (int)Math.Min(bytesRemaining, Silence.Length);
            count -= count % _format.BlockAlign;
            _writer.Write(Silence.AsSpan(0, count));
            bytesRemaining -= count;
        }
        _framesWritten += frames;
    }
}
