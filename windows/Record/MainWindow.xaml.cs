using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace Record;

public partial class MainWindow : Window
{
    private readonly DispatcherTimer _timer;
    private CaptureSession? _session;
    private bool _busy;
    private bool _allowClose;

    public MainWindow()
    {
        InitializeComponent();
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(200), DispatcherPriority.Background, OnTimer, Dispatcher);
        Closing += MainWindow_Closing;
        RefreshSources();
        UpdateControls();
    }

    private async void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _session is not null || SourceComboBox.SelectedItem is not AudioSourceItem source)
        {
            return;
        }

        _busy = true;
        StatusText.Text = "Starting…";
        UpdateControls();
        var session = new CaptureSession();
        session.LevelChanged += Session_LevelChanged;
        session.Faulted += Session_Faulted;

        try
        {
            await session.StartAsync(source);
            _session = session;
            AudioWaveform.Reset();
            MicrophoneWaveform.Reset();
            AudioSignalText.Text = "Waiting";
            MicrophoneSignalText.Text = "Waiting";
            StatusText.Text = source.ProcessId is null
                ? "Recording system audio and microphone"
                : "Recording selected app and microphone";
            _timer.Start();
        }
        catch (Exception error)
        {
            session.LevelChanged -= Session_LevelChanged;
            session.Faulted -= Session_Faulted;
            await session.DisposeAsync();
            StatusText.Text = FriendlyError(error);
        }
        finally
        {
            _busy = false;
            UpdateControls();
        }
    }

    private void PauseButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _session is null)
        {
            return;
        }

        if (_session.IsPaused)
        {
            if (_session.Resume())
            {
                AudioSignalText.Text = "Waiting";
                MicrophoneSignalText.Text = "Waiting";
                StatusText.Text = "Recording resumed";
            }
        }
        else if (_session.Pause())
        {
            AudioWaveform.AddSample(0);
            MicrophoneWaveform.AddSample(0);
            StatusText.Text = "Paused";
        }
        UpdateControls();
    }

    private async void StopButton_Click(object sender, RoutedEventArgs e)
    {
        await StopRecordingAsync();
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_busy && _session is null)
        {
            RefreshSources();
        }
    }

    private void FolderButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(CaptureSession.RecordingsFolder);
            Process.Start(new ProcessStartInfo
            {
                FileName = CaptureSession.RecordingsFolder,
                UseShellExecute = true
            });
        }
        catch (Exception error)
        {
            StatusText.Text = $"Could not open the folder: {error.Message}";
        }
    }

    private async Task StopRecordingAsync()
    {
        if (_busy || _session is null)
        {
            return;
        }

        _busy = true;
        _timer.Stop();
        StatusText.Text = "Finishing audio file…";
        UpdateControls();
        var session = _session;

        try
        {
            var result = await session.StopAsync();
            var fileName = Path.GetFileName(result.OutputPath);
            StatusText.Text = result.Warning is null ? $"Saved {fileName}" : $"Saved {fileName} — {result.Warning}";
        }
        catch (Exception error)
        {
            StatusText.Text = FriendlyError(error);
        }
        finally
        {
            session.LevelChanged -= Session_LevelChanged;
            session.Faulted -= Session_Faulted;
            await session.DisposeAsync();
            _session = null;
            _busy = false;
            AudioSignalText.Text = "Idle";
            MicrophoneSignalText.Text = "Idle";
            UpdateControls();
        }
    }

    private void Session_LevelChanged(AudioTrack track, double level)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_session is null || _session.IsPaused)
            {
                return;
            }

            if (track == AudioTrack.System)
            {
                AudioWaveform.AddSample(level);
                AudioSignalText.Text = level > 0.08 ? "Signal" : "Quiet";
            }
            else
            {
                MicrophoneWaveform.AddSample(level);
                MicrophoneSignalText.Text = level > 0.08 ? "Signal" : "Quiet";
            }
        });
    }

    private void Session_Faulted(string message)
    {
        Dispatcher.BeginInvoke(async () =>
        {
            if (_session is null || _busy)
            {
                return;
            }
            StatusText.Text = $"Capture stopped: {message}";
            await StopRecordingAsync();
        });
    }

    private void OnTimer(object? sender, EventArgs e)
    {
        if (_session is null)
        {
            return;
        }

        var elapsed = _session.Elapsed;
        ElapsedText.Text = elapsed.TotalHours >= 1
            ? $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}"
            : $"{elapsed.Minutes:00}:{elapsed.Seconds:00}";

        if (_session.IsPaused)
        {
            AudioSignalText.Text = "Paused";
            MicrophoneSignalText.Text = "Paused";
        }
    }

    private void RefreshSources()
    {
        var previousProcessId = (SourceComboBox.SelectedItem as AudioSourceItem)?.ProcessId;
        var sources = AudioSourceCatalog.Load();
        SourceComboBox.ItemsSource = sources;
        SourceComboBox.SelectedItem = sources.FirstOrDefault(source => source.ProcessId == previousProcessId)
            ?? sources[0];
        StatusText.Text = "Ready";
    }

    private void UpdateControls()
    {
        var recording = _session is not null;
        RecordButton.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        ActiveControls.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        ElapsedText.Visibility = recording ? Visibility.Visible : Visibility.Hidden;
        SourceComboBox.IsEnabled = !_busy && !recording;
        RefreshButton.IsEnabled = !_busy && !recording;
        RecordButton.IsEnabled = !_busy;
        PauseButton.IsEnabled = !_busy && recording;
        StopButton.IsEnabled = !_busy && recording;
        FolderButton.IsEnabled = !_busy;

        if (recording)
        {
            PauseButton.Content = _session!.IsPaused ? "Resume" : "Pause";
        }
    }

    private async void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_allowClose || _session is null)
        {
            return;
        }

        e.Cancel = true;
        if (_busy)
        {
            StatusText.Text = "Please wait for the current operation to finish.";
            return;
        }

        await StopRecordingAsync();
        _allowClose = true;
        Close();
    }

    private static string FriendlyError(Exception error)
    {
        var message = error.GetBaseException().Message;
        if (message.Contains("access", StringComparison.OrdinalIgnoreCase)
            || message.Contains("denied", StringComparison.OrdinalIgnoreCase))
        {
            return "Audio access was denied. Enable microphone access for desktop apps in Windows Privacy settings.";
        }
        return $"Could not record: {message}";
    }
}
