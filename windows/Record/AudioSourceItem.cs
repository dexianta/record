using System.Diagnostics;

namespace Record;

internal sealed record AudioSourceItem(string DisplayName, int? ProcessId)
{
    public static AudioSourceItem AllSystem { get; } = new("All system audio", null);
}

internal static class AudioSourceCatalog
{
    public static IReadOnlyList<AudioSourceItem> Load()
    {
        var sources = new List<AudioSourceItem> { AudioSourceItem.AllSystem };

        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id == Environment.ProcessId || string.IsNullOrWhiteSpace(process.MainWindowTitle))
                    {
                        continue;
                    }

                    var appName = FriendlyProcessName(process.ProcessName);
                    var windowTitle = CollapseWhitespace(process.MainWindowTitle);
                    var displayName = windowTitle.Equals(appName, StringComparison.OrdinalIgnoreCase)
                        ? appName
                        : $"{appName} — {Truncate(windowTitle, 58)}";
                    sources.Add(new AudioSourceItem(displayName, process.Id));
                }
                catch (InvalidOperationException)
                {
                    // The process exited while the list was being built.
                }
                catch (System.ComponentModel.Win32Exception)
                {
                    // Some elevated/system processes do not expose window details.
                }
            }
        }

        return sources
            .Skip(1)
            .OrderBy(source => source.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .Prepend(AudioSourceItem.AllSystem)
            .ToArray();
    }

    private static string FriendlyProcessName(string processName)
    {
        return processName.ToLowerInvariant() switch
        {
            "chrome" => "Google Chrome",
            "msedge" => "Microsoft Edge",
            "firefox" => "Firefox",
            "slack" => "Slack",
            "teams" or "ms-teams" => "Microsoft Teams",
            "zoom" or "zoomworkplace" => "Zoom",
            _ => processName
        };
    }

    private static string CollapseWhitespace(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static string Truncate(string text, int length) =>
        text.Length <= length ? text : $"{text[..(length - 1)]}…";
}
