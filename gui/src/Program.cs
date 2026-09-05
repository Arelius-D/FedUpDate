using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace FedUpDate.UI
{
    public class MainWindow : Window
    {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        [DllImport("user32.dll")]
        public static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr handle, uint flags);

        [DllImport("user32.dll")]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

        private const int WM_NCLBUTTONDOWN = 0xA1;
        private const int HTCAPTION = 0x2;
        private const int WM_NCHITTEST = 0x0084;
        private const int WM_GETMINMAXINFO = 0x0024;
        private const int GWL_STYLE = -16;
        private const int WS_MAXIMIZEBOX = 0x00010000;
        private const int WS_MINIMIZEBOX = 0x00020000;
        private const int WS_THICKFRAME = 0x00040000;

        // Windows 11 rounded window shell (DWM window corner preference).
        private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        private const int DWMWCP_ROUND = 2;

        private const int HTLEFT = 10;
        private const int HTRIGHT = 11;
        private const int HTTOP = 12;
        private const int HTTOPLEFT = 13;
        private const int HTTOPRIGHT = 14;
        private const int HTBOTTOM = 15;
        private const int HTBOTTOMLEFT = 16;
        private const int HTBOTTOMRIGHT = 17;

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MINMAXINFO
        {
            public POINT ptReserved;
            public POINT ptMaxSize;
            public POINT ptMaxPosition;
            public POINT ptMinTrackSize;
            public POINT ptMaxTrackSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public int dwFlags;
        }

        private Grid _rootGrid;
        private WebView2 _webView;
        private Grid _splashGrid;
        private Process _serverProcess;

        // The splash is held until the interface reports its first audit has
        // finished, so the branding is on screen for the wait rather than for a
        // moment before it. The minimum keeps it from flashing when that audit
        // returns immediately; the ceiling releases the window if the report
        // never arrives at all.
        private const int SplashMinimumMs = 1600;
        private const int SplashCeilingMs = 90000;
        private bool _splashMinimumElapsed;
        private bool _appReported;

        public MainWindow()
        {
            Title = "FedUpDate";
            Width = 1180;
            Height = 820;
            MinWidth = 800;
            MinHeight = 550;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.CanResize;
            Background = (SolidColorBrush)new BrushConverter().ConvertFromString("#141622");

            WindowChrome chrome = new WindowChrome
            {
                CaptionHeight = 0,
                ResizeBorderThickness = new Thickness(6),
                GlassFrameThickness = new Thickness(0, 0, 0, 1),
                CornerRadius = new CornerRadius(0),
                UseAeroCaptionButtons = false
            };
            WindowChrome.SetWindowChrome(this, chrome);

            _rootGrid = new Grid();
            _rootGrid.Background = (SolidColorBrush)new BrushConverter().ConvertFromString("#141622");

            _webView = new WebView2();
            _webView.Margin = new Thickness(4);
            _webView.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 20, 22, 34);

            // The interface stays hidden until the splash is released. This is
            // not decoration: the control hosts its own window handle, so once
            // it has anything to draw it draws over the splash regardless of
            // which sits higher in the layout. Without this the branding lasted
            // only until the page first painted, whatever the release logic
            // decided. Hidden rather than Collapsed, because a collapsed
            // control is given no size and its handle is never created, which
            // is what the browser needs in order to start at all.
            _webView.Visibility = Visibility.Hidden;
            _rootGrid.Children.Add(_webView);

            _splashGrid = CreateNativeSplashView();
            _rootGrid.Children.Add(_splashGrid);

            Content = _rootGrid;

            StateChanged += (s, e) =>
            {
                _webView.Margin = (WindowState == WindowState.Maximized) ? new Thickness(0) : new Thickness(4);
            };

            Loaded += MainWindow_Loaded;
            SourceInitialized += MainWindow_SourceInitialized;
            Closed += MainWindow_Closed;

            StartBackendServer();
        }

        private void MainWindow_SourceInitialized(object sender, EventArgs e)
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            HwndSource source = HwndSource.FromHwnd(hwnd);
            if (source != null)
            {
                source.AddHook(WndProc);
            }

            try
            {
                int style = GetWindowLong(hwnd, GWL_STYLE);
                SetWindowLong(hwnd, GWL_STYLE, style | WS_MAXIMIZEBOX | WS_MINIMIZEBOX | WS_THICKFRAME);
            }
            catch { }

            // Opt the frameless window into the Windows 11 rounded shell.
            try
            {
                int cornerPreference = DWMWCP_ROUND;
                DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref cornerPreference, sizeof(int));
            }
            catch { }
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == WM_GETMINMAXINFO)
            {
                MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));
                IntPtr monitor = MonitorFromWindow(hwnd, 0x00000002);
                if (monitor != IntPtr.Zero)
                {
                    MONITORINFO monitorInfo = new MONITORINFO();
                    monitorInfo.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                    if (GetMonitorInfo(monitor, ref monitorInfo))
                    {
                        RECT rcWorkArea = monitorInfo.rcWork;
                        RECT rcMonitorArea = monitorInfo.rcMonitor;
                        mmi.ptMaxPosition.x = Math.Abs(rcWorkArea.Left - rcMonitorArea.Left);
                        mmi.ptMaxPosition.y = Math.Abs(rcWorkArea.Top - rcMonitorArea.Top);
                        mmi.ptMaxSize.x = Math.Abs(rcWorkArea.Right - rcWorkArea.Left);
                        mmi.ptMaxSize.y = Math.Abs(rcWorkArea.Bottom - rcWorkArea.Top);
                    }
                }
                Marshal.StructureToPtr(mmi, lParam, true);
                handled = true;
            }
            else if (msg == WM_NCHITTEST && WindowState != WindowState.Maximized)
            {
                int x = (short)(lParam.ToInt32() & 0xffff);
                int y = (short)(lParam.ToInt32() >> 16);
                Point pt = PointFromScreen(new Point(x, y));
                const int b = 6;

                bool left = pt.X <= b;
                bool right = pt.X >= ActualWidth - b;
                bool top = pt.Y <= b;
                bool bottom = pt.Y >= ActualHeight - b;

                if (top && left) { handled = true; return (IntPtr)HTTOPLEFT; }
                if (top && right) { handled = true; return (IntPtr)HTTOPRIGHT; }
                if (bottom && left) { handled = true; return (IntPtr)HTBOTTOMLEFT; }
                if (bottom && right) { handled = true; return (IntPtr)HTBOTTOMRIGHT; }
                if (left) { handled = true; return (IntPtr)HTLEFT; }
                if (right) { handled = true; return (IntPtr)HTRIGHT; }
                if (top) { handled = true; return (IntPtr)HTTOP; }
                if (bottom) { handled = true; return (IntPtr)HTBOTTOM; }
            }
            return IntPtr.Zero;
        }

        public void SetImmersiveDarkMode(bool isDark)
        {
            try
            {
                IntPtr hwnd = new WindowInteropHelper(this).Handle;
                if (hwnd != IntPtr.Zero)
                {
                    int darkMode = isDark ? 1 : 0;
                    DwmSetWindowAttribute(hwnd, 20, ref darkMode, sizeof(int));
                    DwmSetWindowAttribute(hwnd, 19, ref darkMode, sizeof(int));
                    SolidColorBrush bg = (SolidColorBrush)new BrushConverter().ConvertFromString(isDark ? "#141622" : "#f8fafc");
                    Background = bg;
                    if (_rootGrid != null) _rootGrid.Background = bg;
                    if (_splashGrid != null) _splashGrid.Background = bg;
                }
            }
            catch { }
        }

        private void StartBackendServer()
        {
            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(baseDir, @"..\Server.ps1");
                if (!File.Exists(scriptPath))
                {
                    scriptPath = Path.Combine(baseDir, "Server.ps1");
                    if (!File.Exists(scriptPath))
                    {
                        string curDir = Directory.GetCurrentDirectory();
                        scriptPath = Path.Combine(curDir, "gui", "Server.ps1");
                        if (!File.Exists(scriptPath))
                        {
                            scriptPath = Path.Combine(curDir, "Server.ps1");
                        }
                    }
                }
                scriptPath = Path.GetFullPath(scriptPath);

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\" -Headless -ParentPid "
                                + Process.GetCurrentProcess().Id,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true,
                    UseShellExecute = false
                };

                _serverProcess = Process.Start(psi);
            }
            catch { }
        }

        private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (key != null)
                    {
                        object val = key.GetValue("AppsUseLightTheme");
                        bool isDark = (val == null || (int)val == 0);
                        SetImmersiveDarkMode(isDark);
                    }
                }
            }
            catch { }

            try
            {
                string userDataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FedUpDate", "WebViewData");
                Directory.CreateDirectory(userDataDir);

                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, userDataDir, null);
                await _webView.EnsureCoreWebView2Async(env);

                if (_webView.CoreWebView2 != null)
                {
                    _webView.CoreWebView2.WebMessageReceived += (s, args) =>
                    {
                        string msg = args.TryGetWebMessageAsString();
                        if (string.IsNullOrEmpty(msg)) msg = args.WebMessageAsJson;
                        HandleWebMessage(msg);
                    };

                    // A link to an external site must open in the user's browser.
                    // Left unhandled, WebView2 would either replace this window
                    // with the web page or raise a chromeless popup.
                    _webView.CoreWebView2.NewWindowRequested += (s, args) =>
                    {
                        args.Handled = true;
                        OpenInDefaultBrowser(args.Uri);
                    };

                    _webView.CoreWebView2.NavigationStarting += (s, args) =>
                    {
                        if (!IsLocalInterface(args.Uri))
                        {
                            args.Cancel = true;
                            OpenInDefaultBrowser(args.Uri);
                        }
                    };
                }

                // The splash is held for a minimum so the branding is actually
                // seen, and released once the interface reports that its first
                // audit has finished. A ceiling covers the case where that
                // report never arrives, so a stalled backend cannot leave the
                // window showing a splash indefinitely.
                #pragma warning disable 4014
                Task.Delay(SplashMinimumMs).ContinueWith(t =>
                {
                    try
                    {
                        Dispatcher.Invoke(new Action(delegate
                        {
                            _splashMinimumElapsed = true;
                            LogHost("Splash minimum elapsed.");
                            if (_appReported) DismissNativeSplash();
                        }));
                    }
                    catch { }
                });
                Task.Delay(SplashCeilingMs).ContinueWith(t =>
                {
                    try
                    {
                        Dispatcher.Invoke(new Action(DismissNativeSplash));
                    }
                    catch { }
                });
                #pragma warning restore 4014

                // Quick connect to server port in background task
                string serverUrl = await Task.Run(() =>
                {
                    for (int i = 0; i < 100; i++)
                    {
                        for (int p = 58100; p <= 58105; p++)
                        {
                            try
                            {
                                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://localhost:" + p + "/");
                                req.Timeout = 150;
                                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                                {
                                    if (resp.StatusCode == HttpStatusCode.OK)
                                    {
                                        return "http://localhost:" + p + "/";
                                    }
                                }
                            }
                            catch { }
                        }
                        Thread.Sleep(30);
                    }
                    return "http://localhost:58100/";
                });

                if (_webView.CoreWebView2 != null)
                {
                    _webView.CoreWebView2.Navigate(serverUrl);
                }
                else
                {
                    _webView.Source = new Uri(serverUrl);
                }
            }
            catch
            {
                _webView.Source = new Uri("http://localhost:58100/");
            }
        }

        // The host writes into the same rolling log as the engine, so the order
        // of window startup can be read next to the audit it is waiting on.
        // Without this the only way to tell a splash that is waiting from one
        // that is stuck is to sit and watch it.
        private static void LogHost(string message)
        {
            try
            {
                string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\.."));
                string dir = Path.Combine(root, "data", "logs");
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                string line = string.Format("[{0:yyyy-MM-dd HH:mm:ss.fff}] [INFO] [Host] {1}{2}",
                    DateTime.Now, message, Environment.NewLine);
                File.AppendAllText(Path.Combine(dir, "fedupdate.log"), line);
            }
            catch { }
        }

        private Grid CreateNativeSplashView()
        {
            Grid splash = new Grid();
            splash.Background = (SolidColorBrush)new BrushConverter().ConvertFromString("#141622");

            StackPanel panel = new StackPanel();
            panel.HorizontalAlignment = HorizontalAlignment.Center;
            panel.VerticalAlignment = VerticalAlignment.Center;

            // Load high-resolution logo
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string iconPath = Path.Combine(baseDir, @"..\..\assets\app\splash-512.png");
            if (!File.Exists(iconPath))
            {
                iconPath = Path.Combine(baseDir, @"assets\app\splash-512.png");
                if (!File.Exists(iconPath))
                {
                    iconPath = Path.Combine(Directory.GetCurrentDirectory(), @"assets\app\splash-512.png");
                }
            }

            if (File.Exists(iconPath))
            {
                try
                {
                    Image logoImg = new Image();
                    BitmapImage bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.UriSource = new Uri(Path.GetFullPath(iconPath));
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.EndInit();
                    logoImg.Source = bmp;
                    logoImg.Width = 168;
                    logoImg.Height = 168;
                    logoImg.Margin = new Thickness(0, 0, 0, 24);
                    panel.Children.Add(logoImg);
                }
                catch { }
            }

            // Title
            TextBlock titleText = new TextBlock();
            titleText.Text = "FedUpDate";
            titleText.FontSize = 34;
            titleText.FontWeight = FontWeights.Bold;
            titleText.Foreground = (SolidColorBrush)new BrushConverter().ConvertFromString("#F1F5F9");
            titleText.HorizontalAlignment = HorizontalAlignment.Center;
            titleText.Margin = new Thickness(0, 0, 0, 6);
            panel.Children.Add(titleText);

            // Subtitle
            TextBlock subText = new TextBlock();
            subText.Text = "Unified Windows Update & Anti-Tamper Suite";
            subText.FontSize = 15;
            subText.Foreground = (SolidColorBrush)new BrushConverter().ConvertFromString("#94A3B8");
            subText.HorizontalAlignment = HorizontalAlignment.Center;
            subText.Margin = new Thickness(0, 0, 0, 28);
            panel.Children.Add(subText);

            // Indeterminate Progress Bar
            ProgressBar pb = new ProgressBar();
            pb.IsIndeterminate = true;
            pb.Width = 300;
            pb.Height = 4;
            pb.BorderThickness = new Thickness(0);
            pb.Background = (SolidColorBrush)new BrushConverter().ConvertFromString("#1E293B");
            pb.Foreground = (SolidColorBrush)new BrushConverter().ConvertFromString("#D97706");
            pb.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(pb);

            splash.Children.Add(panel);
            return splash;
        }

        private void DismissNativeSplash()
        {
            if (_splashGrid != null && _splashGrid.Visibility == Visibility.Visible)
            {
                LogHost(_appReported
                    ? "Splash released; showing the interface."
                    : "Splash released on the ceiling without the interface reporting in.");
                if (_webView != null) _webView.Visibility = Visibility.Visible;
                DoubleAnimation fade = new DoubleAnimation(1.0, 0.0, new Duration(TimeSpan.FromMilliseconds(260)));
                fade.Completed += (s, e) =>
                {
                    _splashGrid.Visibility = Visibility.Collapsed;
                };
                _splashGrid.BeginAnimation(UIElement.OpacityProperty, fade);
            }
        }

        private static bool IsLocalInterface(string uri)
        {
            if (string.IsNullOrEmpty(uri)) return true;
            return uri.StartsWith("http://localhost", StringComparison.OrdinalIgnoreCase)
                || uri.StartsWith("http://127.0.0.1", StringComparison.OrdinalIgnoreCase)
                || uri.StartsWith("about:", StringComparison.OrdinalIgnoreCase);
        }

        private static void OpenInDefaultBrowser(string uri)
        {
            // Only web addresses are handed to the shell, so a crafted link
            // cannot be used to launch an arbitrary local program.
            if (string.IsNullOrEmpty(uri)) return;
            if (!uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
                && !uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return;

            try
            {
                Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
            }
            catch { }
        }

        private void HandleWebMessage(string msg)
        {
            if (string.IsNullOrEmpty(msg)) return;
            try
            {
                Dispatcher.Invoke(new Action(delegate
                {
                    string cleaned = msg.Trim('\"', ' ', '{', '}');

                    // Checked before the window commands, because "app_ready"
                    // contains no substring any of them match and this is the
                    // message that releases the splash.
                    if (cleaned.Equals("app_ready", StringComparison.OrdinalIgnoreCase))
                    {
                        _appReported = true;
                        LogHost("Interface reported its first audit finished.");
                        if (_splashMinimumElapsed) DismissNativeSplash();
                        return;
                    }

                    if (cleaned.IndexOf("min", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        WindowState = WindowState.Minimized;
                    }
                    else if (cleaned.IndexOf("max", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        if (WindowState == WindowState.Maximized)
                        {
                            WindowState = WindowState.Normal;
                        }
                        else
                        {
                            WindowState = WindowState.Maximized;
                        }
                    }
                    else if (cleaned.IndexOf("close", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        Close();
                    }
                    else if (cleaned.IndexOf("drag", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        IntPtr hwnd = new WindowInteropHelper(this).Handle;
                        ReleaseCapture();
                        SendMessage(hwnd, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
                    }
                    else if (cleaned.IndexOf("theme", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        bool isDark = cleaned.IndexOf("dark", StringComparison.OrdinalIgnoreCase) >= 0;
                        SetImmersiveDarkMode(isDark);
                    }
                }));
            }
            catch { }
        }

        private void MainWindow_Closed(object sender, EventArgs e)
        {
            try
            {
                if (_serverProcess != null && !_serverProcess.HasExited)
                {
                    _serverProcess.Kill();
                }
            }
            catch { }
        }

        [STAThread]
        public static void Main()
        {
            Application app = new Application();
            MainWindow win = new MainWindow();
            app.Run(win);
        }
    }
}
