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

        // Where the interface is served from is read from the server, not
        // guessed. The server binds the first free port in its range and
        // writes it to a file named after this process; this window reads
        // that file. Before, the window probed six ports while the server
        // could take any of fifty one, and a busy first port left the window
        // pointed at nothing, borderless, with no way to close it.
        private const int ServerPortLow = 58100;
        private const int ServerPortHigh = 58150;
        private const int PortFileWaitMs = 30000;
        private Grid _failureGrid;
        private TextBlock _failureReason;
        private TextBlock _failureDetail;
        private bool _failureShown;
        private bool _awaitingInterface;
        private int _attempt;
        private string _serverStartError;

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

            _failureGrid = CreateFailureView();
            _rootGrid.Children.Add(_failureGrid);

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

                // A file left by an earlier process with this same id would
                // be read as this server's answer.
                try { File.Delete(ServerPortFilePath()); } catch { }
                _serverStartError = null;

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
            catch (Exception ex)
            {
                _serverProcess = null;
                _serverStartError = ex.Message;
            }
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

                    // The first load of the interface either arrives or it
                    // does not, and one that did not used to leave the
                    // browser's own error page inside a window that draws no
                    // frame. Only the load this window asked for is judged;
                    // a link cancelled on its way to the browser is not a
                    // failure.
                    _webView.CoreWebView2.NavigationCompleted += (s, args) =>
                    {
                        if (!_awaitingInterface) return;
                        _awaitingInterface = false;
                        if (!args.IsSuccess && args.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                        {
                            ShowFailure("The interface page could not be loaded.",
                                "The browser control reported " + args.WebErrorStatus + ".");
                        }
                    };
                }

            }
            catch (Exception ex)
            {
                // Without the browser runtime there is nothing to load the
                // page into. Said as such, rather than left as a blank window.
                ShowFailure("The Microsoft Edge WebView2 runtime could not be started on this computer.", ex.Message);
                return;
            }

            BeginConnect();
        }

        // One attempt to bring the interface up: show the splash, learn where
        // the server is, load the page. The splash is held for a minimum so
        // the branding is actually seen, and released once the interface
        // reports that its first audit has finished; a ceiling covers the case
        // where that report never arrives, so a stalled backend cannot leave
        // the window showing a splash indefinitely. Refresh on the failure
        // screen runs all of this again, starting a server that has gone.
        private async void BeginConnect()
        {
            int attempt = ++_attempt;
            _appReported = false;
            _splashMinimumElapsed = false;
            _awaitingInterface = false;
            ShowSplash();

            #pragma warning disable 4014
            Task.Delay(SplashMinimumMs).ContinueWith(t =>
            {
                try
                {
                    Dispatcher.Invoke(new Action(delegate
                    {
                        if (attempt != _attempt) return;
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
                    Dispatcher.Invoke(new Action(delegate
                    {
                        if (attempt != _attempt) return;
                        DismissNativeSplash();
                    }));
                }
                catch { }
            });
            #pragma warning restore 4014

            if (_serverProcess == null || _serverProcess.HasExited)
            {
                StartBackendServer();
            }

            ServerLookup lookup = await Task.Run(() => LocateServer());
            if (attempt != _attempt) return;

            if (lookup.Url == null)
            {
                ShowFailure(lookup.Reason, lookup.Detail);
                return;
            }

            LogHost("Interface server found at " + lookup.Url);
            _awaitingInterface = true;
            if (_webView.CoreWebView2 != null)
            {
                _webView.CoreWebView2.Navigate(lookup.Url);
            }
            else
            {
                _webView.Source = new Uri(lookup.Url);
            }
        }

        private class ServerLookup
        {
            public string Url;
            public string Reason;
            public string Detail;
        }

        private static string ServerPortFilePath()
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FedUpDate");
            return Path.Combine(dir, "gui-port-" + Process.GetCurrentProcess().Id + ".txt");
        }

        // Where the server is, or why it cannot be found. The server writes
        // the port it took to a file named after this process as soon as it
        // has one, and the window reads that rather than guessing. A server
        // that stopped, or never wrote, is reported as that.
        private ServerLookup LocateServer()
        {
            ServerLookup found = new ServerLookup();
            if (_serverProcess == null)
            {
                found.Reason = "The interface server could not be started.";
                found.Detail = string.IsNullOrEmpty(_serverStartError) ? "Windows PowerShell did not start." : _serverStartError;
                return found;
            }

            string portFile = ServerPortFilePath();
            Stopwatch clock = Stopwatch.StartNew();
            int port = 0;
            while (clock.ElapsedMilliseconds < PortFileWaitMs)
            {
                if (_serverProcess.HasExited)
                {
                    found.Reason = "The interface server stopped before the interface came up.";
                    found.Detail = "It exited with code " + _serverProcess.ExitCode + ". The log in data\\logs\\fedupdate.log says why.";
                    return found;
                }
                if (port == 0) port = ReadPortFile(portFile);
                if (port > 0 && ServerAnswers(port, 1000))
                {
                    found.Url = "http://localhost:" + port + "/";
                    return found;
                }
                Thread.Sleep(100);
            }

            // A server that never said which port it took is looked for on
            // every port it could have taken.
            for (int p = ServerPortLow; p <= ServerPortHigh; p++)
            {
                if (ServerAnswers(p, 150))
                {
                    found.Url = "http://localhost:" + p + "/";
                    return found;
                }
            }

            if (port > 0)
            {
                found.Reason = "The interface server is not answering.";
                found.Detail = "It took port " + port + " but did not answer there within " + (PortFileWaitMs / 1000) + " seconds.";
            }
            else
            {
                found.Reason = "The interface server did not say where it is.";
                found.Detail = "No port was reported within " + (PortFileWaitMs / 1000) + " seconds, and nothing answered on ports " + ServerPortLow + " to " + ServerPortHigh + ".";
            }
            return found;
        }

        private static int ReadPortFile(string path)
        {
            try
            {
                if (!File.Exists(path)) return 0;
                int port;
                if (int.TryParse(File.ReadAllText(path).Trim(), out port) && port > 0 && port < 65536) return port;
            }
            catch { }
            return 0;
        }

        private static bool ServerAnswers(int port, int timeoutMs)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://localhost:" + port + "/");
                req.Timeout = timeoutMs;
                // Never through a proxy. A hotspot or a corporate network can
                // hand the machine one, and a request for this computer's own
                // address must not leave it.
                req.Proxy = null;
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    return resp.StatusCode == HttpStatusCode.OK;
                }
            }
            catch
            {
                return false;
            }
        }

        private void ShowSplash()
        {
            _failureShown = false;
            if (_failureGrid != null) _failureGrid.Visibility = Visibility.Collapsed;
            if (_webView != null) _webView.Visibility = Visibility.Hidden;
            if (_splashGrid != null)
            {
                _splashGrid.BeginAnimation(UIElement.OpacityProperty, null);
                _splashGrid.Opacity = 1.0;
                _splashGrid.Visibility = Visibility.Visible;
            }
        }

        // Shown instead of the interface when the interface cannot be shown.
        // The window draws no frame; the page draws the title bar, and with no
        // page there was no way to close the window from inside it. This says
        // what went wrong, offers to try again, and can be closed. It is drawn
        // by the window itself, so it needs nothing from the server or the
        // browser to appear, and it draws no frame either.
        private void ShowFailure(string reason, string detail)
        {
            try
            {
                Dispatcher.Invoke(new Action(delegate
                {
                    _failureShown = true;
                    _awaitingInterface = false;
                    LogHost("The interface could not be shown: " + reason + " " + (detail ?? ""));
                    if (_failureReason != null) _failureReason.Text = reason ?? "";
                    if (_failureDetail != null) _failureDetail.Text = detail ?? "";
                    if (_webView != null) _webView.Visibility = Visibility.Hidden;
                    if (_splashGrid != null)
                    {
                        _splashGrid.BeginAnimation(UIElement.OpacityProperty, null);
                        _splashGrid.Visibility = Visibility.Collapsed;
                    }
                    if (_failureGrid != null) _failureGrid.Visibility = Visibility.Visible;
                }));
            }
            catch { }
        }

        private static SolidColorBrush MakeBrush(string hex)
        {
            return (SolidColorBrush)new BrushConverter().ConvertFromString(hex);
        }

        private Grid CreateFailureView()
        {
            Grid view = new Grid();
            view.Background = MakeBrush("#141622");
            view.Visibility = Visibility.Collapsed;

            StackPanel panel = new StackPanel();
            panel.HorizontalAlignment = HorizontalAlignment.Center;
            panel.VerticalAlignment = VerticalAlignment.Center;
            panel.MaxWidth = 560;
            panel.Margin = new Thickness(24);

            TextBlock title = new TextBlock();
            title.Text = "FedUpDate could not open its interface";
            title.FontSize = 22;
            title.FontWeight = FontWeights.Bold;
            title.Foreground = MakeBrush("#F1F5F9");
            title.TextWrapping = TextWrapping.Wrap;
            title.TextAlignment = TextAlignment.Center;
            title.Margin = new Thickness(0, 0, 0, 14);
            panel.Children.Add(title);

            _failureReason = new TextBlock();
            _failureReason.FontSize = 15;
            _failureReason.Foreground = MakeBrush("#F1F5F9");
            _failureReason.TextWrapping = TextWrapping.Wrap;
            _failureReason.TextAlignment = TextAlignment.Center;
            _failureReason.Margin = new Thickness(0, 0, 0, 8);
            panel.Children.Add(_failureReason);

            _failureDetail = new TextBlock();
            _failureDetail.FontSize = 13;
            _failureDetail.Foreground = MakeBrush("#94A3B8");
            _failureDetail.TextWrapping = TextWrapping.Wrap;
            _failureDetail.TextAlignment = TextAlignment.Center;
            _failureDetail.Margin = new Thickness(0, 0, 0, 26);
            panel.Children.Add(_failureDetail);

            StackPanel buttons = new StackPanel();
            buttons.Orientation = Orientation.Horizontal;
            buttons.HorizontalAlignment = HorizontalAlignment.Center;

            Button refresh = MakeFailureButton("Refresh", "#D97706", "#141622");
            refresh.Click += (s, e) => BeginConnect();
            buttons.Children.Add(refresh);

            Button exit = MakeFailureButton("Exit", "#1E293B", "#F1F5F9");
            exit.Click += (s, e) => Close();
            buttons.Children.Add(exit);

            panel.Children.Add(buttons);
            view.Children.Add(panel);
            return view;
        }

        private static Button MakeFailureButton(string label, string background, string foreground)
        {
            Button button = new Button();
            button.Content = label;
            button.MinWidth = 120;
            button.Padding = new Thickness(18, 8, 18, 8);
            button.Margin = new Thickness(8, 0, 8, 0);
            button.FontSize = 14;
            button.BorderThickness = new Thickness(0);
            button.Background = MakeBrush(background);
            button.Foreground = MakeBrush(foreground);
            button.Cursor = Cursors.Hand;
            return button;
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
            if (_failureShown) return;
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
                        LogHost("Interface finished loading.");
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
            try { File.Delete(ServerPortFilePath()); } catch { }
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
