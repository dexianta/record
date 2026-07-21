using System.Windows;
using System.Windows.Media;

namespace Record;

internal sealed class WaveformControl : FrameworkElement
{
    private const int SampleCount = 58;
    private readonly Queue<double> _samples = new(Enumerable.Repeat(0.0, SampleCount));

    public Brush BarBrush { get; set; } = Brushes.SeaGreen;

    public void AddSample(double level)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => AddSample(level));
            return;
        }

        _samples.Dequeue();
        _samples.Enqueue(Math.Clamp(level, 0, 1));
        InvalidateVisual();
    }

    public void Reset()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(Reset);
            return;
        }

        _samples.Clear();
        foreach (var _ in Enumerable.Range(0, SampleCount))
        {
            _samples.Enqueue(0);
        }
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        var bounds = new Rect(0.5, 0.5, Math.Max(0, ActualWidth - 1), Math.Max(0, ActualHeight - 1));
        drawingContext.DrawRoundedRectangle(
            new SolidColorBrush(Color.FromArgb(12, 0, 0, 0)),
            new Pen(new SolidColorBrush(Color.FromArgb(22, 0, 0, 0)), 1),
            bounds,
            6,
            6);

        if (ActualWidth <= 12 || ActualHeight <= 8)
        {
            return;
        }

        var values = _samples.ToArray();
        const double spacing = 2;
        var usableWidth = ActualWidth - 12;
        var barWidth = Math.Max(1, (usableWidth - spacing * (values.Length - 1)) / values.Length);
        var x = 6.0;
        foreach (var sample in values)
        {
            var height = Math.Max(3, sample * (ActualHeight - 8));
            var rect = new Rect(x, (ActualHeight - height) / 2, barWidth, height);
            var brush = sample > 0.015
                ? BarBrush
                : new SolidColorBrush(Color.FromArgb(35, 100, 100, 100));
            drawingContext.DrawRoundedRectangle(brush, null, rect, Math.Min(2, barWidth / 2), Math.Min(2, barWidth / 2));
            x += barWidth + spacing;
        }
    }
}
