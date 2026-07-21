using System.Diagnostics;

namespace Record;

internal sealed class RecordingClock
{
    private const long HundredNanosecondsPerSecond = 10_000_000;
    private readonly object _gate = new();
    private ClockState _state = ClockState.Idle;
    private long _startedAt;
    private long _pausedAt;
    private long _pausedDuration;
    private long _stoppedAt;

    public bool IsPaused
    {
        get
        {
            lock (_gate)
            {
                return _state == ClockState.Paused;
            }
        }
    }

    public TimeSpan Elapsed
    {
        get
        {
            lock (_gate)
            {
                if (_state == ClockState.Idle)
                {
                    return TimeSpan.Zero;
                }

                var now = _state == ClockState.Stopped ? _stoppedAt : QpcNow();
                var currentPause = _state == ClockState.Paused ? now - _pausedAt : 0;
                var active = Math.Max(0, now - _startedAt - _pausedDuration - currentPause);
                return TimeSpan.FromTicks(active);
            }
        }
    }

    public void Start()
    {
        lock (_gate)
        {
            _startedAt = QpcNow();
            _pausedAt = 0;
            _pausedDuration = 0;
            _stoppedAt = 0;
            _state = ClockState.Recording;
        }
    }

    public bool Pause()
    {
        lock (_gate)
        {
            if (_state != ClockState.Recording)
            {
                return false;
            }

            _pausedAt = QpcNow();
            _state = ClockState.Paused;
            return true;
        }
    }

    public bool Resume()
    {
        lock (_gate)
        {
            if (_state != ClockState.Paused)
            {
                return false;
            }

            _pausedDuration += Math.Max(0, QpcNow() - _pausedAt);
            _pausedAt = 0;
            _state = ClockState.Recording;
            return true;
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            if (_state is ClockState.Idle or ClockState.Stopped)
            {
                return;
            }

            _stoppedAt = QpcNow();
            if (_state == ClockState.Paused)
            {
                _pausedDuration += Math.Max(0, _stoppedAt - _pausedAt);
            }
            _state = ClockState.Stopped;
        }
    }

    public bool TryGetFramePosition(long packetQpc, int sampleRate, out long framePosition)
    {
        lock (_gate)
        {
            if (_state != ClockState.Recording)
            {
                framePosition = 0;
                return false;
            }

            var activeTime = Math.Max(0, packetQpc - _startedAt - _pausedDuration);
            framePosition = activeTime * sampleRate / HundredNanosecondsPerSecond;
            return true;
        }
    }

    public static long QpcNow()
    {
        var timestamp = Stopwatch.GetTimestamp();
        var seconds = timestamp / Stopwatch.Frequency;
        var remainder = timestamp % Stopwatch.Frequency;
        return checked(seconds * HundredNanosecondsPerSecond
            + remainder * HundredNanosecondsPerSecond / Stopwatch.Frequency);
    }

    private enum ClockState
    {
        Idle,
        Recording,
        Paused,
        Stopped
    }
}
