using System.Windows;

namespace Record;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (e.Args.Contains("--self-check", StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                SelfCheck.Run();
                Console.WriteLine("Record Windows self-check passed.");
                Shutdown(0);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"Record Windows self-check failed: {error}");
                Shutdown(1);
            }
            return;
        }

        if (e.Args.Contains("--audio-self-check", StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                await AudioSelfCheck.RunAsync();
                Console.WriteLine("Record Windows audio self-check passed.");
                Shutdown(0);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"Record Windows audio self-check failed: {error}");
                Shutdown(1);
            }
            return;
        }

        new MainWindow().Show();
    }
}
