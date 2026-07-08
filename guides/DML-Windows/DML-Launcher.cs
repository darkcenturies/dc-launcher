// DML-Launcher.cs -- darkcenturies WotLK Launcher (fork of Dad's MMO Lab)
// Compiled at install time: csc.exe /target:winexe /r:System.Windows.Forms.dll /r:System.Drawing.dll

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

class DmlLauncherEntry
{
    static Mutex _mutex;

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e) {
            if (!TrayApp.IsInstalledInstance())
                MessageBox.Show("Unhandled error:\n\n" + e.Exception.ToString(),
                    "DC Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
        };
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());

        // Uninstall never needs the mutex or tray
        if (args.Length > 0 && args[0] == "--uninstall")
        {
            TrayApp.RunUninstall();
            return;
        }

        bool createdNew;
        _mutex = new Mutex(true, "Global\\DCLauncher_SingleInstance", out createdNew);

        if (!createdNew)
        {
            // Tray is already running.
            // If we are the downloaded/external exe, offer to update the running install.
            // If we ARE the installed instance the user somehow launched twice, exit silently.
            if (!TrayApp.IsInstalledInstance())
                TrayApp.OfferUpdate();
            _mutex.Dispose();
            return;
        }

        try
        {
            if (!TrayApp.IsInstalledInstance())
            {
                try
                {
                    if (TrayApp.IsAlreadyInstalled())
                        TrayApp.OfferUpdate();
                    else
                        TrayApp.RunSetupWizard();
                }
                catch (Exception ex)
                {
                    MessageBox.Show("Startup error:\n\n" + ex.ToString(),
                        "DC Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return;
            }

            Application.Run(new TrayApp());
        }
        finally
        {
            try { _mutex.ReleaseMutex(); } catch { }
            _mutex.Dispose();
        }
    }
}

// Invisible UI-thread marshal target for the tray. ShowInTaskbar=false alone still lets
// Windows list it as a blank Alt+Tab entry once it becomes the active window (e.g. right
// after showing the context menu); WS_EX_TOOLWINDOW excludes it from Alt+Tab entirely.
class SyncHostForm : Form
{
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW
            return cp;
        }
    }
}

class TrayApp : ApplicationContext
{
    const string DISTRO   = "dml-arch";
    const string VERSION  = "1.0.2";

    enum ServerDisplayState { Stopped, Running, Loading }

    string TrayTooltip(bool serverActive)
    {
        return serverActive
            ? "DC Launcher v" + VERSION + " — Server Active"
            : "DC Launcher v" + VERSION;
    }

    string TitlesCachePath {
        get {
            return System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),
                "dml-titles.cache");
        }
    }

    string ManageScriptCachePath {
        get {
            return System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),
                "dml-manage-titles.cache");
        }
    }

    string StoppedMarkerPath {
        get {
            return System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),
                ".dml-servers-stopped");
        }
    }

    bool ServersIntentionallyStopped()
    {
        try { return System.IO.File.Exists(StoppedMarkerPath); }
        catch { return false; }
    }

    // After stop, tray/doctor must not boot WSL for status — that leaves VmmemWSL ~2 GB idle.
    string GetStatusOutput()
    {
        if (ServersIntentionallyStopped() || !IsDistroRunning())
            return BuildStoppedStatusOutput();
        return WslRun("dml status");
    }

    void MaybeReReleaseWsl()
    {
        if (ServersIntentionallyStopped() && IsDistroRunning())
            TriggerReleaseWsl(0);
    }

    // True only when dml-arch is Running — wsl -l -v does NOT boot the distro.
    static bool IsDistroRunning()
    {
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName               = "wsl.exe";
            psi.Arguments              = "-l -v";
            psi.UseShellExecute        = false;
            psi.RedirectStandardOutput = true;
            psi.CreateNoWindow         = true;
            // wsl -l -v emits UTF-16 LE; UTF-8 decoding breaks "Running" matching
            psi.StandardOutputEncoding = Encoding.Unicode;
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(5000);
                foreach (var line in output.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string trimmed = line.Trim();
                    if (trimmed.StartsWith(DISTRO, StringComparison.OrdinalIgnoreCase)
                        || trimmed.StartsWith("* " + DISTRO, StringComparison.OrdinalIgnoreCase))
                        return trimmed.IndexOf("Running", StringComparison.OrdinalIgnoreCase) >= 0;
                }
            }
        }
        catch { }
        return false;
    }

    void SaveTitleCache(System.Collections.Generic.IEnumerable<string> titles)
    {
        try
        {
            System.IO.File.WriteAllLines(TitlesCachePath, titles);
        }
        catch { }
    }

    string[] LoadTitleCache()
    {
        try
        {
            if (System.IO.File.Exists(TitlesCachePath))
                return System.IO.File.ReadAllLines(TitlesCachePath);
        }
        catch { }
        return new string[0];
    }

    string BuildStoppedStatusOutput()
    {
        var titles = LoadTitleCache();
        if (titles.Length == 0) return "";
        var lines = new System.Collections.Generic.List<string>();
        foreach (var t in titles)
        {
            string title = (t ?? "").Trim();
            if (title.Length > 0) lines.Add(title + ":stopped");
        }
        return string.Join("\n", lines);
    }

    // Prevents Windows from sleeping while a server is running.
    // ES_CONTINUOUS makes the state persist until explicitly released.
    // ES_SYSTEM_REQUIRED blocks sleep without requiring the display to stay on.
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint esFlags);
    const uint ES_CONTINUOUS      = 0x80000000;
    const uint ES_SYSTEM_REQUIRED = 0x00000001;

    // --- WSL keepalive (lazy) -----------------------------------------------
    // WSL2 tears down the distro after the last Windows-side wsl.exe session
    // exits -- measured at ~13s on Windows 11 (docs suggest up to a minute).
    // Processes INSIDE the distro (dockerd, game containers) do NOT hold it
    // open. While a server is RUNNING we keep one hidden
    // "wsl --exec sleep infinity" process alive so servers survive after
    // installer/terminal windows close.
    // Lazy on purpose: the tray must never boot the distro on its own --
    // at logon the user may not want yesterday's server eating RAM. All
    // polling is gated on "wsl --list --running", which never boots WSL.
    // The keepalive lives in a Job Object with KILL_ON_JOB_CLOSE so it can
    // never outlive the tray, even if the tray process is killed forcibly.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    const int  JobObjectExtendedLimitInformation  = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long    PerProcessUserTimeLimit;
        public long    PerJobUserTimeLimit;
        public uint    LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint    ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint    PriorityClass;
        public uint    SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    // --- Fields -------------------------------------------------------------
    NotifyIcon _tray;
    ContextMenuStrip _menu;
    System.Windows.Forms.Timer _menuTimer;
    System.Windows.Forms.Timer _loadingAnimTimer;
    Form _syncForm;
    string _lastStatusOut = "";
    int _loadingDotFrame;
    readonly Dictionary<string, string> _pendingTitleStatus =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    HashSet<string> _manageScriptTitles =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    const int WslQuickTimeoutMs = 15000;
    const int WslLongTimeoutMs  = 600000;

    static readonly Color ColorRunning = Color.FromArgb(30, 160, 60);
    static readonly Color ColorStopped = Color.FromArgb(110, 110, 110);
    static readonly Color ColorLoading = Color.FromArgb(200, 150, 0);

    // Keepalive state
    IntPtr _job        = IntPtr.Zero;
    Process _keepalive;
    bool    _serversRunning;
    object  _kaLock    = new object();
    int     _idleChecks;
    bool    _dormant;
    int     _dormantTicks;

    // --- Constructor --------------------------------------------------------

    public TrayApp()
    {
        // Hidden form gives a stable UI thread marshal target (ApplicationContext alone can leave _uiSync null).
        _syncForm = new SyncHostForm();
        _syncForm.FormBorderStyle = FormBorderStyle.None;
        _syncForm.ShowInTaskbar   = false;
        _syncForm.StartPosition   = FormStartPosition.Manual;
        _syncForm.Size            = new Size(0, 0);
        _syncForm.Opacity         = 0;
        _syncForm.Show();

        _tray = new NotifyIcon();
        try { _tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
        catch { _tray.Icon = SystemIcons.Application; }
        _tray.Text    = TrayTooltip(false);
        _tray.Visible = true;

        _menu = new ContextMenuStrip();
        _menu.Closed += OnMenuClosed;
        // Win11: show menu only on right-click (not ContextMenuStrip — avoids left-click open)
        _tray.MouseUp += OnTrayMouseUp;

        // Re-release if something woke WSL after an intentional stop (doctor, old tray poll).
        MaybeReReleaseWsl();

        // Check server state at startup so sleep is blocked immediately
        // if a server is already running when the tray loads.
        var startupTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        startupTimer.Tick += delegate {
            startupTimer.Stop(); startupTimer.Dispose();
            string[] r = { null };
            var pollTimer = new System.Windows.Forms.Timer { Interval = 150 };
            pollTimer.Tick += delegate {
                if (r[0] == null) return;
                pollTimer.Stop(); pollTimer.Dispose();
                ApplyStatusResult(r[0]);
            };
            pollTimer.Start();
            System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                try { r[0] = GetStatusOutput(); }
                catch { r[0] = BuildStoppedStatusOutput(); }
            });
        };
        startupTimer.Start();

        // Start the WSL keepalive job object so servers survive terminal-close.
        InitKeepalive();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            StopKeepalive();
            try { if (_syncForm != null) { _syncForm.Close(); _syncForm.Dispose(); } } catch { }
        }
        base.Dispose(disposing);
    }

    // --- WSL keepalive methods ----------------------------------------------

    void InitKeepalive()
    {
        _job = CreateJobObject(IntPtr.Zero, null);
        if (_job != IntPtr.Zero)
        {
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int    size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr mem  = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, mem, false);
                SetInformationJobObject(_job, JobObjectExtendedLimitInformation, mem, (uint)size);
            }
            finally { Marshal.FreeHGlobal(mem); }
        }
    }

    void EnsureKeepalive()
    {
        lock (_kaLock)
        {
            bool dead = true;
            try { dead = (_keepalive == null || _keepalive.HasExited); } catch { }
            if (!dead) return;
            try
            {
                if (_keepalive != null) _keepalive.Dispose();
                var psi = new ProcessStartInfo();
                psi.FileName        = "wsl.exe";
                psi.Arguments       = "-d " + DISTRO + " --exec /usr/bin/sleep infinity";
                psi.UseShellExecute = false;
                psi.CreateNoWindow  = true;
                _keepalive = Process.Start(psi);
                if (_job != IntPtr.Zero && _keepalive != null)
                    AssignProcessToJobObject(_job, _keepalive.Handle);
            }
            catch { _keepalive = null; }  // next poll retries
        }
    }

    void StopKeepalive()
    {
        lock (_kaLock)
        {
            try { if (_keepalive != null && !_keepalive.HasExited) _keepalive.Kill(); } catch { }
            try { if (_keepalive != null) { _keepalive.Dispose(); _keepalive = null; } } catch { }
        }
    }

    // ------------------------------------------------------------------------

    void PostToUi(Action action)
    {
        if (action == null) return;
        try
        {
            if (_syncForm != null && !_syncForm.IsDisposed)
            {
                if (_syncForm.InvokeRequired)
                    _syncForm.BeginInvoke(action);
                else
                    action();
                return;
            }
        }
        catch { }
        try { action(); } catch { }
    }

    void DeferCloseMenu()
    {
        PostToUi(delegate {
            try { if (_menu != null && _menu.Visible) _menu.Close(); } catch { }
        });
    }

    // Blocks or releases Windows sleep based on how many servers are running.
    void UpdateSleepLock(int runningCount)
    {
        _serversRunning = runningCount > 0;
        if (runningCount > 0)
        {
            EnsureKeepalive();
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
            _tray.Text = TrayTooltip(true);
        }
        else
        {
            StopKeepalive();
            SetThreadExecutionState(ES_CONTINUOUS);  // release
            _tray.Text = TrayTooltip(false);
        }
    }

    static int CountRunning(string statusOut)
    {
        int count = 0;
        foreach (var line in statusOut.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            int colon = line.Trim().IndexOf(':');
            if (colon <= 0) continue;
            string state = line.Trim().Substring(colon + 1).Trim();
            if (state.Equals("running", StringComparison.OrdinalIgnoreCase)
                || state.Equals("loading", StringComparison.OrdinalIgnoreCase))
                count++;
        }
        return count;
    }

    void OnTrayMouseUp(object sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Right) return;
        try
        {
            if (_menu == null || _menu.IsDisposed) return;
            if (_menu.Visible)
            {
                _menu.Close();
                return;
            }
            try
            {
                PopulateMenu(_menu);
            }
            catch
            {
                _menu.Items.Clear();
                var err = new ToolStripMenuItem("DC Launcher");
                err.Enabled = false;
                _menu.Items.Add(err);
                _menu.Items.Add(new ToolStripSeparator());
                AddStaticItems(_menu);
            }
            _menu.Show(Cursor.Position);
        }
        catch { }
    }

    void OnMenuClosed(object sender, ToolStripDropDownClosedEventArgs e)
    {
        if (_menuTimer != null)
        {
            _menuTimer.Stop();
            _menuTimer.Dispose();
            _menuTimer = null;
        }
        if (_loadingAnimTimer != null && _pendingTitleStatus.Count == 0)
        {
            _loadingAnimTimer.Stop();
            _loadingAnimTimer.Dispose();
            _loadingAnimTimer = null;
        }
    }

    string LoadingDots()
    {
        // Fixed width (padded with spaces) so the animation doesn't change the
        // menu item's text length -- a variable-length suffix makes the whole
        // ToolStripMenuItem (and the dropdown) resize every tick, which looks broken.
        int n = (_loadingDotFrame % 3) + 1;
        return new string('.', n).PadRight(3);
    }

    string FormatTitleText(string title, ServerDisplayState state)
    {
        switch (state)
        {
            case ServerDisplayState.Running:
                return title + "  ● Running";
            case ServerDisplayState.Loading:
                return title + "  ◌ Loading" + LoadingDots();
            default:
                return title + "  ○ Stopped";
        }
    }

    Color ColorForState(ServerDisplayState state)
    {
        switch (state)
        {
            case ServerDisplayState.Running: return ColorRunning;
            case ServerDisplayState.Loading: return ColorLoading;
            default: return ColorStopped;
        }
    }

    ServerDisplayState GetDisplayState(string title, string reportedStatus)
    {
        if (string.Equals(reportedStatus, "loading", StringComparison.OrdinalIgnoreCase))
            return ServerDisplayState.Loading;

        string expected;
        bool hasPending = _pendingTitleStatus.TryGetValue(title, out expected);

        if (string.Equals(reportedStatus, "stopped", StringComparison.OrdinalIgnoreCase))
        {
            // While a start/restart is pending, "dml status" can briefly still read
            // "stopped" before the container flips to loading (e.g. the console tab
            // hasn't finished opening yet). Treat that as still-loading instead of
            // flashing "Stopped" for one poll cycle.
            if (hasPending && !string.Equals(expected, "stopped", StringComparison.OrdinalIgnoreCase))
                return ServerDisplayState.Loading;
            return ServerDisplayState.Stopped;
        }

        if (hasPending && !string.Equals(reportedStatus, expected, StringComparison.OrdinalIgnoreCase))
            return ServerDisplayState.Loading;

        return string.Equals(reportedStatus, "running", StringComparison.OrdinalIgnoreCase)
            ? ServerDisplayState.Running : ServerDisplayState.Stopped;
    }

    void ApplyTitleActionEnabled(ToolStripMenuItem start, ToolStripMenuItem restart,
        ToolStripMenuItem stop, ServerDisplayState state)
    {
        bool running = state == ServerDisplayState.Running;
        bool loading = state == ServerDisplayState.Loading;
        start.Enabled   = !running && !loading;
        restart.Enabled =  running && !loading;
        stop.Enabled    =  running || loading;
    }

    void RefreshManageScriptCache()
    {
        if (!IsDistroRunning())
        {
            // Don't wipe the list just because WSL is offline right now (e.g. after
            // "Stop WSL (release RAM)") — Manage should stay available while a title
            // is stopped, since wow-manage.sh doesn't require the server to be running.
            _manageScriptTitles = LoadManageScriptCache();
            return;
        }
        var titles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            string output = WslRun(
                "for d in \"$HOME\"/games/*/; do [ -f \"${d}wow-manage.sh\" ] && basename \"$d\"; done");
            foreach (var line in output.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string title = line.Trim();
                if (title.Length > 0) titles.Add(title);
            }
            SaveManageScriptCache(titles);
        }
        catch { }
        _manageScriptTitles = titles;
    }

    void SaveManageScriptCache(IEnumerable<string> titles)
    {
        try { System.IO.File.WriteAllLines(ManageScriptCachePath, titles); }
        catch { }
    }

    HashSet<string> LoadManageScriptCache()
    {
        var titles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            if (System.IO.File.Exists(ManageScriptCachePath))
                foreach (var line in System.IO.File.ReadAllLines(ManageScriptCachePath))
                {
                    string title = (line ?? "").Trim();
                    if (title.Length > 0) titles.Add(title);
                }
        }
        catch { }
        return titles;
    }

    bool TitleHasManageScript(string title)
    {
        return _manageScriptTitles != null && _manageScriptTitles.Contains(title);
    }

    void SyncPendingWithStatus(string statusOut)
    {
        var map = ParseStatusMap(statusOut);
        var done = new System.Collections.Generic.List<string>();
        foreach (var kv in _pendingTitleStatus)
        {
            string reported;
            if (!map.TryGetValue(kv.Key, out reported)) continue;
            if (string.Equals(reported, "stopped", StringComparison.OrdinalIgnoreCase)
                || (string.Equals(reported, kv.Value, StringComparison.OrdinalIgnoreCase)
                    && !string.Equals(reported, "loading", StringComparison.OrdinalIgnoreCase)))
                done.Add(kv.Key);
        }
        foreach (var t in done) _pendingTitleStatus.Remove(t);
        if (_pendingTitleStatus.Count == 0 && _loadingAnimTimer != null)
        {
            _loadingAnimTimer.Stop();
            _loadingAnimTimer.Dispose();
            _loadingAnimTimer = null;
        }
    }

    void MarkTitlePending(string title, string expectedStatus)
    {
        _pendingTitleStatus[title] = expectedStatus;
        EnsureLoadingAnimTimer();
    }

    void MarkAllTitlesPending(string expectedStatus)
    {
        foreach (var line in _lastStatusOut.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string trimmed = line.Trim();
            int colon = trimmed.IndexOf(':');
            if (colon > 0)
                _pendingTitleStatus[trimmed.Substring(0, colon)] = expectedStatus;
        }
        if (_pendingTitleStatus.Count == 0)
        {
            foreach (var t in LoadTitleCache())
            {
                string title = (t ?? "").Trim();
                if (title.Length > 0) _pendingTitleStatus[title] = expectedStatus;
            }
        }
        EnsureLoadingAnimTimer();
    }

    void EnsureLoadingAnimTimer()
    {
        if (_loadingAnimTimer != null) return;
        _loadingAnimTimer = new System.Windows.Forms.Timer { Interval = 450 };
        _loadingAnimTimer.Tick += delegate {
            _loadingDotFrame++;
            if (_menu != null && _menu.Visible && _pendingTitleStatus.Count > 0)
                UpdateTitleRowsInOpenMenu(_lastStatusOut);
        };
        _loadingAnimTimer.Start();
    }

    void UpdateTitleRowsInOpenMenu(string statusOut)
    {
        if (_menu == null || _menu.IsDisposed || !_menu.Visible) return;
        var statusMap = ParseStatusMap(statusOut);
        PostToUi(delegate {
            try
            {
                if (_menu == null || _menu.IsDisposed || !_menu.Visible) return;
                foreach (ToolStripItem item in _menu.Items)
                {
                    string title = item.Tag as string;
                    if (string.IsNullOrEmpty(title)) continue;
                    if ("placeholder".Equals(title)) continue; // "Checking servers..." row, not a real title
                    var gameMenu = item as ToolStripMenuItem;
                    if (gameMenu == null) continue;
                    string reported;
                    if (!statusMap.TryGetValue(title, out reported)) reported = "stopped";
                    var state = GetDisplayState(title, reported);
                    gameMenu.Text = FormatTitleText(title, state);
                    gameMenu.ForeColor = ColorForState(state);
                    if (gameMenu.DropDownItems.Count >= 3)
                        ApplyTitleActionEnabled(
                            gameMenu.DropDownItems[0] as ToolStripMenuItem,
                            gameMenu.DropDownItems[1] as ToolStripMenuItem,
                            gameMenu.DropDownItems[2] as ToolStripMenuItem,
                            state);
                }
            }
            catch { }
        });
    }

    Dictionary<string, string> ParseStatusMap(string statusOut)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in statusOut.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string trimmed = line.Trim();
            int colon = trimmed.IndexOf(':');
            if (colon > 0)
                map[trimmed.Substring(0, colon)] = trimmed.Substring(colon + 1).Trim();
        }
        return map;
    }

    void ApplyStatusResult(string statusOut)
    {
        _lastStatusOut = statusOut ?? "";
        SyncPendingWithStatus(_lastStatusOut);
        UpdateSleepLock(CountRunning(_lastStatusOut));
        UpdateTitleRowsInOpenMenu(_lastStatusOut);
    }

    void PopulateMenu(ContextMenuStrip menu)
    {
        if (_menuTimer != null)
        {
            _menuTimer.Stop();
            _menuTimer.Dispose();
            _menuTimer = null;
        }

        menu.Items.Clear();

        var header = new ToolStripMenuItem("DC Launcher v" + VERSION);
        header.Enabled = false;
        try { header.Font = new Font(SystemFonts.MenuFont, FontStyle.Bold); }
        catch { }
        menu.Items.Add(header);
        menu.Items.Add(new ToolStripSeparator());

        var placeholder = new ToolStripMenuItem("Checking servers...");
        placeholder.Enabled = false;
        placeholder.Tag = "placeholder";
        menu.Items.Add(placeholder);

        menu.Items.Add(new ToolStripSeparator());
        AddStaticItems(menu);

        string[] result = new string[1];

        _menuTimer = new System.Windows.Forms.Timer();
        _menuTimer.Interval = 150;
        _menuTimer.Tick += delegate
        {
            if (result[0] == null) return;
            _menuTimer.Stop();
            _menuTimer.Dispose();
            _menuTimer = null;
            if (menu.IsDisposed) return;

            int idx = -1;
            for (int i = 0; i < menu.Items.Count; i++)
                if ("placeholder".Equals(menu.Items[i].Tag as string)) { idx = i; break; }
            if (idx < 0) return;

            menu.Items.RemoveAt(idx);
            ApplyStatusResult(result[0]);
            var items = BuildTitleItems(result[0]);
            for (int i = items.Count - 1; i >= 0; i--)
                menu.Items.Insert(idx, items[i]);
        };
        _menuTimer.Start();

        System.Threading.ThreadPool.QueueUserWorkItem(delegate
        {
            try { result[0] = GetStatusOutput(); }
            catch { result[0] = BuildStoppedStatusOutput(); }
        });
        System.Threading.ThreadPool.QueueUserWorkItem(delegate { RefreshManageScriptCache(); });
    }

    System.Collections.Generic.List<ToolStripItem> BuildTitleItems(string statusOut)
    {
        var items     = new System.Collections.Generic.List<ToolStripItem>();
        var statusMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        int runningCount = 0;

        foreach (var line in statusOut.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string trimmed = line.Trim();
            int colon = trimmed.IndexOf(':');
            if (colon > 0)
                statusMap[trimmed.Substring(0, colon)] = trimmed.Substring(colon + 1);
        }

        if (statusMap.Count == 0)
        {
            var empty = new ToolStripMenuItem("No titles installed");
            empty.Enabled = false;
            items.Add(empty);
            UpdateSleepLock(0);
            return items;
        }

        foreach (var kv in statusMap)
        {
            string title    = kv.Key;
            string reported = kv.Value;
            var displayState = GetDisplayState(title, reported);
            if (displayState == ServerDisplayState.Running) runningCount++;

            var gameMenu = new ToolStripMenuItem(FormatTitleText(title, displayState));
            gameMenu.Tag = title;
            gameMenu.ForeColor = ColorForState(displayState);

            var startItem   = new ToolStripMenuItem("Start");
            var restartItem = new ToolStripMenuItem("Restart");
            var stopItem    = new ToolStripMenuItem("Stop");
            ApplyTitleActionEnabled(startItem, restartItem, stopItem, displayState);

            string captured = title;
            startItem.Click   += delegate { RunAndReport("start",   captured); };
            restartItem.Click += delegate { RunAndReport("restart", captured); };
            stopItem.Click    += delegate { RunAndReport("stop",    captured); };

            gameMenu.DropDownItems.Add(startItem);
            gameMenu.DropDownItems.Add(restartItem);
            gameMenu.DropDownItems.Add(stopItem);

            // --- From upstream: Attach to Console + LAN Play submenu --------
            bool isRunning = displayState == ServerDisplayState.Running;

            if (TitleHasManageScript(title))
            {
                var manageItem = new ToolStripMenuItem("Manage");
                manageItem.Enabled = isRunning;
                string capturedManage = title;
                manageItem.Click += delegate { OpenManageConsole(capturedManage); };
                gameMenu.DropDownItems.Add(manageItem);

                var backupItem = new ToolStripMenuItem("Backup...");
                backupItem.Enabled = isRunning;
                string capturedBackup = title;
                backupItem.Click += delegate { OpenBackupConsole(capturedBackup); };
                gameMenu.DropDownItems.Add(backupItem);
            }

            gameMenu.DropDownItems.Add(new ToolStripSeparator());

            var attachItem = new ToolStripMenuItem("Attach to Console");
            attachItem.Enabled = isRunning;
            attachItem.Click += delegate { AttachToConsole(captured); };
            gameMenu.DropDownItems.Add(attachItem);

            var lanMenu    = new ToolStripMenuItem("LAN Play");
            var lanEnable  = new ToolStripMenuItem("Enable LAN Play...");
            var lanDisable = new ToolStripMenuItem("Disable LAN Play");
            var lanStatus  = new ToolStripMenuItem("Status");
            lanEnable.Enabled  = isRunning;
            lanDisable.Enabled = isRunning;
            lanStatus.Enabled  = isRunning;
            lanEnable.Click  += delegate { LanEnable(captured); };
            lanDisable.Click += delegate { LanRun("off",    captured); };
            lanStatus.Click  += delegate { LanRun("status", captured); };
            lanMenu.DropDownItems.Add(lanEnable);
            lanMenu.DropDownItems.Add(lanDisable);
            lanMenu.DropDownItems.Add(lanStatus);
            gameMenu.DropDownItems.Add(lanMenu);
            // ----------------------------------------------------------------

            items.Add(gameMenu);
        }

        SaveTitleCache(statusMap.Keys);
        UpdateSleepLock(runningCount);
        return items;
    }

    void AddStaticItems(ContextMenuStrip menu)
    {
        menu.Items.Add(new ToolStripSeparator());

        var extrasMenu = new ToolStripMenuItem("Extras");

        var installItem = new ToolStripMenuItem("Install New Title...");
        installItem.Click += delegate { ShowInstallDialog(); };
        extrasMenu.DropDownItems.Add(installItem);

        var dcMenu = new ToolStripMenuItem("Dark Centuries");
        var dcInstallItem = new ToolStripMenuItem("Install Dark Centuries");
        dcInstallItem.Click += delegate {
            DeferCloseMenu();
            OpenLiveConsole(
                "curl -fsSL https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/dark-centuries/install.sh | bash",
                "Install Dark Centuries");
        };
        var dcUninstallItem = new ToolStripMenuItem("Uninstall Dark Centuries");
        dcUninstallItem.Click += delegate {
            DeferCloseMenu();
            if (MessageBox.Show(
                    "This will remove the Dark Centuries Lua script, SQL data, and NPC templates from your server.\n\nContinue?",
                    "Uninstall Dark Centuries", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                return;
            OpenLiveConsole(
                "curl -fsSL https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/dark-centuries/uninstall.sh | bash",
                "Uninstall Dark Centuries");
        };
        dcMenu.DropDownItems.Add(dcInstallItem);
        dcMenu.DropDownItems.Add(dcUninstallItem);
        extrasMenu.DropDownItems.Add(dcMenu);

        var shellItem = new ToolStripMenuItem("Open DCL Shell");
        shellItem.Click += delegate { OpenTerminal("-d " + DISTRO); };
        extrasMenu.DropDownItems.Add(shellItem);

        var doctorItem = new ToolStripMenuItem("Run DCL Doctor");
        doctorItem.Click += delegate
        {
            DeferCloseMenu();
            SetTrayProgress("Running doctor...");
            System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                try {
                    string result = WslRun("dml doctor", WslLongTimeoutMs);
                    MaybeReReleaseWsl();
                    bool warn = result.Contains("[WARN]");
                    PostToUi(delegate {
                        RefreshTrayFromStatus();
                        MessageBoxIcon icon = warn ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
                        MessageBox.Show(result, "DCL Doctor", MessageBoxButtons.OK, icon);
                    });
                } catch (Exception ex) {
                    PostToUi(delegate {
                        MessageBox.Show("[error] " + ex.Message, "DCL Doctor", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    });
                }
            });
        };
        extrasMenu.DropDownItems.Add(doctorItem);

        var updateItem = new ToolStripMenuItem("Check for Updates...");
        updateItem.Click += delegate { CheckForUpdates(); };
        extrasMenu.DropDownItems.Add(updateItem);

        var recompileItem = new ToolStripMenuItem("Recompile Launcher");
        recompileItem.Click += delegate { RecompileLauncher(); };
        extrasMenu.DropDownItems.Add(recompileItem);

        var importItem = new ToolStripMenuItem("Import Backup...");
        importItem.Click += delegate { ShowImportBackupDialog(); };
        extrasMenu.DropDownItems.Add(importItem);

        extrasMenu.DropDownItems.Add(new ToolStripSeparator());

        var restartActiveItem = new ToolStripMenuItem("Restart active server/s");
        restartActiveItem.Click += delegate { RestartActiveServers(); };
        extrasMenu.DropDownItems.Add(restartActiveItem);

        var releaseItem = new ToolStripMenuItem("Stop WSL (release RAM)");
        releaseItem.Click += delegate { ConfirmAndReleaseWsl(); };
        extrasMenu.DropDownItems.Add(releaseItem);

        menu.Items.Add(extrasMenu);

        var minimizeItem = new ToolStripMenuItem("Minimize");
        minimizeItem.Click += delegate { if (_menu != null && _menu.Visible) _menu.Close(); };
        menu.Items.Add(minimizeItem);

        var exitItem = new ToolStripMenuItem("Exit");
        exitItem.Click += delegate {
            if (_serversRunning)
            {
                var choice = MessageBox.Show(
                    "A game server is still running.\n\n" +
                    "Closing DC Launcher releases the WSL keepalive -- running " +
                    "servers will shut down within seconds of exiting.\n\n" +
                    "Exit anyway?",
                    "DC Launcher", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (choice != DialogResult.Yes) return;
            }
            StopKeepalive();
            SetThreadExecutionState(ES_CONTINUOUS);  // always release before exit
            TriggerReleaseWsl(0);                    // stop dml-keepalive.service + wsl --shutdown
            _tray.Visible = false;
            _tray.Dispose();
            Application.Exit();
        };
        menu.Items.Add(exitItem);
    }

    const string UpdateScriptUrl =
        "https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/guides/DML-Windows/Install-DML.ps1";
    const string UpdatePageUrl =
        "https://github.com/darkcenturies/dc-launcher/blob/main/guides/DML-Windows/Install-DML.ps1";

    // Notify-only by design: this checks and compares versions automatically,
    // but never downloads-and-executes anything itself. Install-DML.ps1 needs
    // Administrator rights, so updating always goes through a manual,
    // explicit re-run -- the same trust model as the original install.
    void CheckForUpdates()
    {
        DeferCloseMenu();
        SetTrayProgress("Checking for updates...");
        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            string versionLine;
            try
            {
                // .NET Framework doesn't always enable TLS 1.2 by default; GitHub requires it.
                System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
                using (var wc = new System.Net.WebClient())
                {
                    wc.Headers.Add("User-Agent", "DML-Launcher");
                    versionLine = wc.DownloadString(UpdateScriptUrl);
                }
            }
            catch (Exception ex)
            {
                PostToUi(delegate {
                    RefreshTrayFromStatus();
                    MessageBox.Show("[error] Could not reach GitHub: " + ex.Message,
                        "Check for Updates", MessageBoxButtons.OK, MessageBoxIcon.Error);
                });
                return;
            }

            var match = System.Text.RegularExpressions.Regex.Match(
                versionLine, @"\$DmlCliVersion\s*=\s*'([\d.]+)'");
            Version remoteVersion, localVersion;
            if (!match.Success
                || !Version.TryParse(match.Groups[1].Value, out remoteVersion)
                || !Version.TryParse(VERSION, out localVersion))
            {
                PostToUi(delegate {
                    RefreshTrayFromStatus();
                    MessageBox.Show("Could not determine the latest version from GitHub.",
                        "Check for Updates", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                });
                return;
            }

            string remoteVersionStr = match.Groups[1].Value;

            if (remoteVersion.CompareTo(localVersion) <= 0)
            {
                PostToUi(delegate {
                    RefreshTrayFromStatus();
                    MessageBox.Show("You're already on the latest version (v" + VERSION + ").",
                        "Check for Updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                });
                return;
            }

            PostToUi(delegate {
                RefreshTrayFromStatus();
                DialogResult result = MessageBox.Show(
                    "A newer version is available: v" + remoteVersionStr + " (you have v" + VERSION + ").\n\n"
                    + "Updating means downloading and re-running Install-DML.ps1 yourself (it needs "
                    + "Administrator rights) -- same as the original install. Your servers and their "
                    + "data are not touched, only the Windows-side install and this launcher.\n\n"
                    + "Open the installer's page on GitHub now?",
                    "Update Available", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (result != DialogResult.Yes) return;

                try { Process.Start(new ProcessStartInfo(UpdatePageUrl) { UseShellExecute = true }); }
                catch (Exception ex)
                {
                    MessageBox.Show("[error] Could not open the page: " + ex.Message,
                        "Update Available", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            });
        });
    }

    void RestartActiveServers()
    {
        if (!IsDistroRunning())
        {
            MessageBox.Show(
                "WSL is not running.\n\nUse Start on a title to boot the server first.",
                "Restart active server/s", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        int running = 0;
        try { running = CountRunning(WslRun("dml status")); } catch { }

        if (running == 0)
        {
            MessageBox.Show(
                "No active servers to restart.",
                "Restart active server/s", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        string msg = running == 1
            ? "Restart the 1 active server now?"
            : "Restart all " + running + " active servers now?";

        if (MessageBox.Show(msg, "Restart active server/s",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
            return;

        DeferCloseMenu();
        MarkAllTitlesPending("running");
        SetTrayProgress("Restarting active server(s) — see console");
        OpenLiveConsole("dml restart-active", "Restart active server/s");
        StartStatusPolling(900);
    }

    void ConfirmAndReleaseWsl()
    {
        int running = 0;
        try {
            if (IsDistroRunning())
                running = CountRunning(WslRun("dml status"));
        } catch { }

        string msg =
            "This will stop any running game servers cleanly (docker compose down), "
            + "then shut down WSL and return RAM to Windows.\n\n"
            + "• Running titles are stopped with docker compose down\n"
            + "• Docker and DML services are then stopped\n"
            + "• Vmmem RAM should drop within a few seconds\n\n"
            + "Use Start on a title when you want to play again.";

        if (running > 0)
            msg += "\n\n" + running + " server(s) will be stopped gracefully first.";

        if (MessageBox.Show(msg, "Stop WSL", MessageBoxButtons.YesNo, MessageBoxIcon.Warning)
                != DialogResult.Yes)
            return;

        try { System.IO.File.WriteAllText(StoppedMarkerPath, DateTime.Now.ToString("o")); }
        catch { }

        MarkAllTitlesPending("stopped");
        UpdateSleepLock(0);
        DeferCloseMenu();

        if (IsDistroRunning())
        {
            SetTrayProgress("Stopping servers + releasing WSL...");
            System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                try {
                    string result = WslRun("dml release-wsl", WslLongTimeoutMs);
                    bool warn = result.Contains("[WARN]") || result.ToLower().Contains("error");
                    PostToUi(delegate {
                        UpdateSleepLock(0);
                        _tray.Text = TrayTooltip(false);
                        MessageBoxIcon icon = warn ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
                        MessageBox.Show(result, "Stop WSL", MessageBoxButtons.OK, icon);
                    });
                } catch (Exception ex) {
                    PostToUi(delegate {
                        MessageBox.Show("[error] " + ex.Message, "Stop WSL", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    });
                }
            });
        }
        else
        {
            TriggerReleaseWsl(0);
            MessageBox.Show(
                "WSL is shutting down — RAM should free in a few seconds.\n"
                + "Use Start when you want to bring the server back.",
                "Stop WSL", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    void TriggerReleaseWsl(int delaySeconds)
    {
        try
        {
            string ps1 = System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),
                "DML-Release-WSL.ps1");
            if (!System.IO.File.Exists(ps1)) return;
            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -WindowStyle Hidden -File \"" + ps1 + "\" -DelaySeconds " + delaySeconds;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
        }
        catch { }
    }

    void RecompileLauncher()
    {
        DeferCloseMenu();
        string exeDir = System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        string csPath  = System.IO.Path.Combine(exeDir, "DML-Launcher.cs");
        string exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string tmpExe  = exePath + ".new.exe";

        if (!System.IO.File.Exists(csPath))
        {
            MessageBox.Show("DML-Launcher.cs not found in " + exeDir + "\n\nCannot recompile.",
                "Recompile Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string csc = @"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe";
        if (!System.IO.File.Exists(csc))
        {
            MessageBox.Show("csc.exe not found at:\n" + csc,
                "Recompile Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        SetTrayProgress("Recompiling launcher...");
        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try
            {
                string args = "/nologo /optimize+ /target:winexe"
                    + " /reference:System.dll,System.Drawing.dll,System.Windows.Forms.dll,System.Net.dll"
                    + " /out:\"" + tmpExe + "\""
                    + " \"" + csPath + "\"";
                var psi = new ProcessStartInfo(csc, args);
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError  = true;
                psi.CreateNoWindow = true;
                var proc = Process.Start(psi);
                string output = proc.StandardOutput.ReadToEnd() + proc.StandardError.ReadToEnd();
                proc.WaitForExit();

                if (proc.ExitCode != 0 || !System.IO.File.Exists(tmpExe))
                {
                    PostToUi(delegate {
                        RefreshTrayFromStatus();
                        MessageBox.Show("Compile failed:\n\n" + output.Trim(),
                            "Recompile Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    });
                    return;
                }

                PostToUi(delegate {
                    RefreshTrayFromStatus();
                    var choice = MessageBox.Show(
                        "Recompile successful.\n\nThe launcher will close and restart to apply the update.",
                        "Recompile Launcher", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
                    if (choice != DialogResult.OK) { try { System.IO.File.Delete(tmpExe); } catch { } return; }

                    // Spawn a cmd that waits for us to exit, swaps the exe, then restarts
                    string bat = System.IO.Path.Combine(
                        System.IO.Path.GetTempPath(), "dml-recompile-swap.cmd");
                    System.IO.File.WriteAllText(bat,
                        "@echo off\r\n"
                        + ":wait\r\ntasklist /fi \"pid eq " + Process.GetCurrentProcess().Id + "\" | find \"" + Process.GetCurrentProcess().Id + "\" >nul 2>&1\r\n"
                        + "if not errorlevel 1 (timeout /t 1 /nobreak >nul && goto wait)\r\n"
                        + "copy /y \"" + tmpExe + "\" \"" + exePath + "\" >nul\r\n"
                        + "del \"" + tmpExe + "\" >nul 2>&1\r\n"
                        + "start \"\" \"" + exePath + "\"\r\n"
                        + "del \"%~f0\"\r\n");
                    Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"") { CreateNoWindow = true, UseShellExecute = false });

                    StopKeepalive();
                    SetThreadExecutionState(ES_CONTINUOUS);
                    _tray.Visible = false;
                    _tray.Dispose();
                    Application.Exit();
                });
            }
            catch (Exception ex)
            {
                PostToUi(delegate {
                    RefreshTrayFromStatus();
                    MessageBox.Show("[error] " + ex.Message, "Recompile Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                });
            }
        });
    }

    void CloseMenuIfOpen()
    {
        try { if (_menu != null && _menu.Visible) _menu.Close(); } catch { }
    }

    void SetTrayProgress(string detail)
    {
        try { _tray.Text = "DC Launcher v" + VERSION + " — " + detail; } catch { }
    }

    void ShowTrayBalloon(string title, string text, ToolTipIcon icon)
    {
        try
        {
            _tray.BalloonTipTitle = title;
            _tray.BalloonTipText  = TruncateForBalloon(text);
            _tray.BalloonTipIcon  = icon;
            _tray.ShowBalloonTip(5000);
        }
        catch { }
    }

    string TruncateForBalloon(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        text = text.Trim();
        return text.Length <= 240 ? text : text.Substring(0, 237) + "...";
    }

    void RefreshTrayFromStatus()
    {
        string[] r = { null };
        var pollTimer = new System.Windows.Forms.Timer { Interval = 150 };
        pollTimer.Tick += delegate {
            if (r[0] == null) return;
            pollTimer.Stop(); pollTimer.Dispose();
            ApplyStatusResult(r[0]);
        };
        pollTimer.Start();
        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try { r[0] = GetStatusOutput(); }
            catch { r[0] = BuildStoppedStatusOutput(); }
        });
    }

    void StartStatusPolling(int durationSeconds)
    {
        var deadline = DateTime.UtcNow.AddSeconds(durationSeconds);
        var timer = new System.Windows.Forms.Timer { Interval = 3000 };
        timer.Tick += delegate {
            RefreshTrayFromStatus();
            if (DateTime.UtcNow >= deadline) {
                timer.Stop();
                timer.Dispose();
            }
        };
        timer.Start();
        RefreshTrayFromStatus();
    }

    // Same terminal + dml-arch path as "Open DCL Shell" (wt -> cmd -> PowerShell).
    bool OpenShell(string wslArguments, string errorTitle)
    {
        try {
            // wt.exe treats ';' as a command separator -- use 'new-tab --' so the
            // remainder is passed intact to wsl (live-console scripts use '&&' not ';').
            var psi = new ProcessStartInfo("wt.exe", "new-tab -- wsl " + wslArguments);
            psi.UseShellExecute = true;
            Process.Start(psi);
            return true;
        }
        catch { }
        try {
            var psi = new ProcessStartInfo("cmd.exe", "/k wsl " + wslArguments);
            psi.UseShellExecute = true;
            Process.Start(psi);
            return true;
        }
        catch { }
        try {
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoExit -Command \"wsl " + wslArguments + "\"");
            psi.UseShellExecute = true;
            Process.Start(psi);
            return true;
        }
        catch (Exception ex) {
            MessageBox.Show("[error] Could not open console: " + ex.Message, errorTitle,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    void OpenLiveConsole(string wslInnerCmd, string windowTitle)
    {
        // Staged start/stop and wow-manage.sh keep the console open themselves.
        // Other commands: land in login bash when done.
        string bashScript = wslInnerCmd;
        if (!KeepsConsoleOpen(wslInnerCmd))
            bashScript = wslInnerCmd + " && exec bash -l";
        string wslArgs = "-d " + DISTRO + " -e bash -lic \"" + bashScript.Replace("\"", "\\\"") + "\"";
        OpenShell(wslArgs, windowTitle);
    }

    static bool KeepsConsoleOpen(string wslInnerCmd)
    {
        return wslInnerCmd.IndexOf("wow-server-playerbots", StringComparison.OrdinalIgnoreCase) >= 0
            || wslInnerCmd.IndexOf("wow-manage.sh", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    void OpenManageConsole(string title)
    {
        DeferCloseMenu();
        OpenLiveConsole("cd ~/games/" + title + " && ./wow-manage.sh", "Manage " + title);
    }

    void OpenBackupConsole(string title)
    {
        DeferCloseMenu();
        // Opens wow-manage.sh — navigate to Server Maintenance (14) → Backup databases (2)
        OpenLiveConsole(
            "cd ~/games/" + title + " && echo '[dml] Backup: Server Maintenance -> option 14 -> option 2' && ./wow-manage.sh",
            "Backup " + title);
    }

    void RunAndReport(string cmd, string title)
    {
        DeferCloseMenu();
        string expected = (cmd == "stop") ? "stopped" : "running";
        MarkTitlePending(title, expected);
        try { System.IO.File.Delete(StoppedMarkerPath); } catch { }
        string caption = (cmd == "start" ? "Start " : cmd == "restart" ? "Restart " : "Stop ") + title;
        string verb = cmd == "start" ? "Starting" : cmd == "restart" ? "Restarting" : "Stopping";
        SetTrayProgress(verb + " " + title + " — see console");
        OpenLiveConsole("dml " + cmd + " " + title, caption);

        // After a start, re-point the realm at the host's current LAN IP in case DHCP
        // assigned a new address since last session. 'dml lan refresh' is a no-op when
        // LAN play is off, and waits internally for the realm DB to come up.
        if (cmd == "start")
        {
            string lanIp = GetLanIp();
            if (lanIp != null)
            {
                string capturedTitle = title;
                string capturedIp    = lanIp;
                System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                    try { WslRun("dml lan " + capturedTitle + " refresh " + capturedIp); } catch { }
                });
            }
        }

        StartStatusPolling(900);
    }

    string WslRun(string wslCmd)
    {
        return WslRun(wslCmd, WslQuickTimeoutMs);
    }

    string WslRun(string wslCmd, int timeoutMs)
    {
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName               = "wsl.exe";
            psi.Arguments              = "-d " + DISTRO + " -- " + wslCmd;
            psi.UseShellExecute        = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError  = true;
            psi.CreateNoWindow         = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding  = Encoding.UTF8;
            using (var p = Process.Start(psi))
            {
                var stdout = new System.Text.StringBuilder();
                var stderr = new System.Text.StringBuilder();
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) {
                    if (e.Data != null) stdout.AppendLine(e.Data);
                };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) {
                    if (e.Data != null) stderr.AppendLine(e.Data);
                };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutMs))
                {
                    string partial = stdout.ToString().Trim();
                    if (string.IsNullOrEmpty(partial)) partial = stderr.ToString().Trim();
                    if (!string.IsNullOrEmpty(partial)) partial += "\n";
                    return partial + "[WARN] Still running — use Open DML Shell to monitor progress.";
                }
                p.WaitForExit();
                string output = stdout.ToString().Trim();
                if (string.IsNullOrEmpty(output)) output = stderr.ToString().Trim();
                return output;
            }
        }
        catch (Exception ex)
        {
            return "[error] Could not run WSL: " + ex.Message;
        }
    }

    void OpenTerminal(string wslArgs)
    {
        OpenShell(wslArgs, "Open DCL Shell");
    }

    void ShowInstallDialog()
    {
        DeferCloseMenu();
        using (var form = new Form())
        {
            form.Text            = "Install New Server";
            form.Size            = new Size(440, 260);
            form.StartPosition   = FormStartPosition.CenterScreen;
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox     = false;
            form.MinimizeBox     = false;

            var lbl = new Label();
            lbl.Text   = "What do you want to install?";
            lbl.Left   = 16; lbl.Top = 16; lbl.Width = 400; lbl.Height = 20;
            try { lbl.Font = new Font(SystemFonts.MenuFont, FontStyle.Bold); } catch { }

            var rbWotlk = new RadioButton();
            rbWotlk.Text    = "WotLK 3.3.5a — AzerothCore + Playerbots (new server)";
            rbWotlk.Left    = 16; rbWotlk.Top = 50; rbWotlk.Width = 400; rbWotlk.Checked = true;

            var rbDC = new RadioButton();
            rbDC.Text  = "Install Dark Centuries (zone control warfare plugin)";
            rbDC.Left  = 16; rbDC.Top = 78; rbDC.Width = 400;

            bool hasWotlk = LoadTitleCache().Length > 0;
            bool dcInstalled = false;
            if (hasWotlk)
            {
                try {
                    string dc = WslRun("[ -f ~/games/wow-server-playerbots/env/dist/etc/modules/lua_scripts/dark_centuries.lua ] && echo yes || echo no");
                    dcInstalled = dc.Trim().Equals("yes", StringComparison.OrdinalIgnoreCase);
                } catch { }
            }
            rbDC.Enabled = hasWotlk && !dcInstalled;
            if (!rbDC.Enabled)
                rbDC.Text += dcInstalled ? " (already installed)" : " (install WotLK first)";

            var note = new Label();
            note.Left = 16; note.Top = 112; note.Width = 400; note.Height = 36;
            note.ForeColor = Color.FromArgb(100, 100, 100);
            note.Text = "A setup window will open. Follow the prompts.\nThis may take 10-30 minutes on first install.";

            var btnInstall = new Button();
            btnInstall.Text = "Install"; btnInstall.Left = 236; btnInstall.Top = 168;
            btnInstall.Width = 85; btnInstall.DialogResult = DialogResult.OK;

            var btnCancel = new Button();
            btnCancel.Text = "Cancel"; btnCancel.Left = 332; btnCancel.Top = 168;
            btnCancel.Width = 85; btnCancel.DialogResult = DialogResult.Cancel;

            form.Controls.AddRange(new Control[] { lbl, rbWotlk, rbDC, note, btnInstall, btnCancel });
            form.AcceptButton = btnInstall;
            form.CancelButton = btnCancel;

            if (form.ShowDialog() != DialogResult.OK) return;

            if (rbWotlk.Checked)
                DownloadAndRunInstaller(
                    "https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/guides/wow-wotlk/Install-WoW-WotLK.ps1",
                    "Install-WoW-WotLK.ps1");
            else
                OpenLiveConsole(
                    "curl -fsSL https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/dark-centuries/install.sh | bash",
                    "Install Dark Centuries");
        }
    }

    void DownloadAndRunInstaller(string url, string fileName)
    {
        SetTrayProgress("Downloading " + fileName + "...");
        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            string tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), fileName);
            try
            {
                System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
                using (var wc = new System.Net.WebClient())
                { wc.Headers.Add("User-Agent", "DC-Launcher"); wc.DownloadFile(url, tmp); }
            }
            catch (Exception ex)
            {
                PostToUi(delegate {
                    RefreshTrayFromStatus();
                    MessageBox.Show("Download failed:\n" + ex.Message, "Install", MessageBoxButtons.OK, MessageBoxIcon.Error);
                });
                return;
            }
            PostToUi(delegate {
                RefreshTrayFromStatus();
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + tmp + "\"");
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                try { Process.Start(psi); }
                catch (Exception ex2) {
                    MessageBox.Show("Could not launch installer:\n" + ex2.Message, "Install", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            });
        });
    }

    // --- AttachToConsole (from upstream) ------------------------------------

    void AttachToConsole(string title)
    {
        string[] result = { null };

        var timer = new System.Windows.Forms.Timer { Interval = 150 };
        timer.Tick += delegate {
            if (result[0] == null) return;
            timer.Stop(); timer.Dispose();

            string container = result[0].Trim();
            if (string.IsNullOrEmpty(container)) {
                MessageBox.Show(
                    "No worldserver container found for '" + title + "'.\nIs the server running?",
                    "Attach to Console", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string wslArgs = "-d " + DISTRO + " -u dml -- bash -c \"printf '\\n"
                + "  === WoW Server Console ==================================\\n"
                + "  Title:   " + title + "\\n"
                + "  Exit:    Ctrl+P then Ctrl+Q  (detach safely)\\n"
                + "  WARNING: Ctrl+C will STOP the server!\\n"
                + "\\n' && docker attach " + container + "\"";
            OpenTerminal(wslArgs);
        };
        timer.Start();

        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try {
                string raw = WslRun("docker ps --format {{.Names}}");
                string found = "";
                foreach (var line in raw.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)) {
                    if (line.Trim().IndexOf("worldserver", StringComparison.OrdinalIgnoreCase) >= 0) {
                        found = line.Trim();
                        break;
                    }
                }
                result[0] = found;
            } catch {
                result[0] = "";
            }
        });
    }

    // --- LAN play (from upstream) -------------------------------------------
    // The realm's advertised address lives in the title's database; the
    // Windows plumbing (portproxy + firewall) is set up once by the
    // installer. These just drive 'dml lan' inside the distro.

    void LanEnable(string title)
    {
        string ip = GetLanIp();
        if (ip == null)
        {
            MessageBox.Show(
                "Could not detect this PC's LAN IP address.\n\n" +
                "Are you connected to your home network? If yes, run\n" +
                "'ipconfig' in a terminal, find your IPv4 address, and enable\n" +
                "LAN play from a DML shell instead:\n\n" +
                "    dml lan " + title + " on <your-ip>",
                "Enable LAN Play", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // The installer pins the Windows port proxy to the LAN IP it saw at
        // install time (it must be specific -- see Install-DML.ps1 Step 12).
        // If DHCP has moved this PC since then, or the rules are missing,
        // say so HERE -- otherwise the realm advertises an address nothing
        // is listening on and LAN clients fail with no clue why.
        string plumbingNote = "";
        var proxyListeners = GetLanProxyListeners();
        if (proxyListeners.Count == 0)
            plumbingNote = "\n\nWARNING: Windows LAN forwarding rules were not found.\n" +
                           "Re-run Install-DML.ps1 once, or other PCs cannot reach the server.";
        else if (!proxyListeners.Contains(ip))
            plumbingNote = "\n\nWARNING: Windows is forwarding LAN traffic for " +
                           string.Join(", ", proxyListeners.ToArray()) + ",\n" +
                           "but this PC's address is now " + ip + ".\n" +
                           "Re-run Install-DML.ps1 once to refresh the rules.";

        var choice = MessageBox.Show(
            "This lets other PCs on your home network play on '" + title + "'.\n\n" +
            "This PC's LAN address:  " + ip + "\n\n" +
            "On each other PC, open realmlist.wtf in the WoW client folder\n" +
            "and set:\n\n" +
            "    set realmlist " + ip + "\n\n" +
            "(This PC keeps working with 127.0.0.1 -- no change needed here.)" +
            plumbingNote + "\n\n" +
            "Enable LAN play now?",
            "Enable LAN Play -- " + title, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (choice != DialogResult.Yes) return;

        LanRun("on " + ip, title);
    }

    // Runs 'dml lan <title> <action>' off the UI thread and reports the
    // result. 'dml lan' may wait up to ~90s for the realm database right
    // after a start, so the AttachToConsole timer pattern is used rather
    // than RunAndReport's synchronous call.
    void LanRun(string action, string title)
    {
        string[] result = { null };

        var timer = new System.Windows.Forms.Timer { Interval = 150 };
        timer.Tick += delegate {
            if (result[0] == null) return;
            timer.Stop(); timer.Dispose();
            string text = result[0].Trim();
            if (text.Length == 0) text = "[error] No response from dml -- is the server running?";
            MessageBoxIcon icon = (text.Contains("ERROR") || text.Contains("[error]") || text.Contains("not supported"))
                ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
            MessageBox.Show(text, "LAN Play -- " + title, MessageBoxButtons.OK, icon);
        };
        timer.Start();

        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try   { result[0] = WslRun("dml lan " + title + " " + action); }
            catch { result[0] = "[error] Could not run dml lan."; }
        });
    }

    // Listen addresses of Windows portproxy rules that forward the WoW auth
    // port to 127.0.0.1 -- i.e., the addresses LAN clients can actually
    // reach. Reading rules needs no elevation (only changing them does).
    static System.Collections.Generic.List<string> GetLanProxyListeners()
    {
        var found = new System.Collections.Generic.List<string>();
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName               = "netsh.exe";
            psi.Arguments              = "interface portproxy show v4tov4";
            psi.UseShellExecute        = false;
            psi.RedirectStandardOutput = true;
            psi.CreateNoWindow         = true;
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(10000);
                foreach (var line in output.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var tok = line.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    // listenAddr listenPort connectAddr connectPort
                    if (tok.Length == 4 && tok[1] == "3724" && tok[2] == "127.0.0.1" && !found.Contains(tok[0]))
                        found.Add(tok[0]);
                }
            }
        }
        catch { }
        return found;
    }

    // Best-guess LAN IPv4: an up, non-loopback adapter that has an IPv4
    // default gateway (WSL/Hyper-V virtual switches never do). Prefers
    // private-range addresses so a VPN adapter's address doesn't win.
    static string GetLanIp()
    {
        string fallback = null;
        try
        {
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;

                var props = nic.GetIPProperties();
                bool hasV4Gateway = false;
                foreach (var gw in props.GatewayAddresses)
                    // Disconnected adapters can report a 0.0.0.0 "gateway" --
                    // that's not a route to the LAN, don't let it qualify.
                    if (gw.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
                        && gw.Address.ToString() != "0.0.0.0")
                        hasV4Gateway = true;
                if (!hasV4Gateway) continue;

                foreach (var ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                    string ip = ua.Address.ToString();
                    if (IsPrivateIp(ip)) return ip;
                    if (fallback == null) fallback = ip;
                }
            }
        }
        catch { }
        return fallback;
    }

    static bool IsPrivateIp(string ip)
    {
        if (ip.StartsWith("192.168.") || ip.StartsWith("10.")) return true;
        if (ip.StartsWith("172."))
        {
            var parts = ip.Split('.');
            int second;
            if (parts.Length == 4 && int.TryParse(parts[1], out second))
                return second >= 16 && second <= 31;
        }
        return false;
    }

    // =========================================================================
    // Self-install / uninstall
    // =========================================================================

    // All locations we recognise as a valid install
    public static readonly string[] KnownInstallDirs = new string[] {
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "DC Launcher"),
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DC Launcher"),
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DC-Launcher"),
        @"C:\DCL",
        @"C:\DML",
    };

    // All exe names we might be installed as (legacy DML-Launcher.exe or current DC-Launcher.exe)
    static readonly string[] KnownExeNames = new string[] {
        "DC-Launcher.exe",
        "DML-Launcher.exe",
    };

    // Default install target (Program Files)
    public static readonly string InstallDir =
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "DC Launcher");

    const string AppRegKey =
        @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DCLauncher";

    public static bool IsInstalledInstance()
    {
        string loc = System.Reflection.Assembly.GetExecutingAssembly().Location;
        foreach (var dir in KnownInstallDirs)
            if (loc.StartsWith(dir, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    public static bool IsAlreadyInstalled()
    {
        return FindInstalledExe() != null;
    }

    public static string FindInstalledExe()
    {
        foreach (var dir in KnownInstallDirs)
            foreach (var exe in KnownExeNames)
            {
                string p = System.IO.Path.Combine(dir, exe);
                if (System.IO.File.Exists(p)) return p;
            }
        return null;
    }

    public static void OfferUpdate()
    {
        string current   = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string foundExe  = FindInstalledExe();

        // If we cannot find any existing install, offer a fresh install instead
        if (foundExe == null)
        {
            var doFresh = MessageBox.Show(
                "An existing DC Launcher install was detected in the registry but the\n" +
                "exe could not be found on disk.\n\n" +
                "Run the setup wizard to install fresh?",
                "DC Launcher", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (doFresh == DialogResult.Yes) RunSetupWizard();
            return;
        }

        // Always update to DC-Launcher.exe in the same folder the old exe lives in
        string installDir = System.IO.Path.GetDirectoryName(foundExe);
        string installed  = System.IO.Path.Combine(installDir, "DC-Launcher.exe");

        var choice = MessageBox.Show(
            "DC Launcher is already installed on this PC.\n\n" +
            "Installed at: " + installDir + "\n\n" +
            "Update to this version (v" + VERSION + ")?",
            "DC Launcher", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (choice != DialogResult.Yes) return;

        foreach (var p in Process.GetProcessesByName("DC-Launcher"))
            try { if (p.Id != Process.GetCurrentProcess().Id) p.Kill(); } catch { }
        foreach (var p in Process.GetProcessesByName("DML-Launcher"))
            try { if (p.Id != Process.GetCurrentProcess().Id) p.Kill(); } catch { }

        string bat = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "dc-update.cmd");
        System.IO.File.WriteAllText(bat,
            "@echo off\r\ntimeout /t 2 /nobreak >nul\r\n" +
            "copy /y \"" + current + "\" \"" + installed + "\" >nul\r\n" +
            "start \"\" \"" + installed + "\"\r\ndel \"%~f0\"\r\n");
        Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"")
            { CreateNoWindow = true, UseShellExecute = false });
    }

    public static bool IsElevated()
    {
        try {
            var id = System.Security.Principal.WindowsIdentity.GetCurrent();
            var p  = new System.Security.Principal.WindowsPrincipal(id);
            return p.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        } catch { return false; }
    }

    public static bool NeedsElevationForPath(string dir)
    {
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string pfx = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        return dir.StartsWith(pf, StringComparison.OrdinalIgnoreCase) ||
               dir.StartsWith(pfx, StringComparison.OrdinalIgnoreCase);
    }

    public static void RelaunhElevated(string[] args)
    {
        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string argStr = args.Length > 0 ? string.Join(" ", args) : "";
        try {
            Process.Start(new ProcessStartInfo(exe, argStr) {
                Verb = "runas", UseShellExecute = true
            });
        } catch { }
    }

    public static void RunSetupWizard()
    {
        try
        {
            var wiz = new SetupWizardForm();
            Application.Run(wiz);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Setup wizard failed:\n\n" + ex.ToString(),
                "DC Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    public static void RunUninstall()
    {
        var choice = MessageBox.Show(
            "This will remove DC Launcher from your PC.\n\n" +
            "Your WoW server data in WSL will NOT be deleted.\n\n" +
            "Uninstall DC Launcher?",
            "DC Launcher", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (choice != DialogResult.Yes) return;

        try {
            string startMenu = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DC Launcher");
            if (System.IO.Directory.Exists(startMenu))
                System.IO.Directory.Delete(startMenu, true);
        } catch { }
        try {
            string desktop = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DC Launcher.lnk");
            if (System.IO.File.Exists(desktop)) System.IO.File.Delete(desktop);
        } catch { }

        try {
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKey(AppRegKey, false);
        } catch { }
        try {
            using (var run = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true))
                if (run != null) run.DeleteValue("DC Launcher", false);
        } catch { }

        string dir = InstallDir;
        string bat = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "dc-uninstall.cmd");
        System.IO.File.WriteAllText(bat,
            "@echo off\r\ntimeout /t 2 /nobreak >nul\r\nrd /s /q \"" + dir + "\" >nul 2>&1\r\ndel \"%~f0\"\r\n");
        Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"")
            { CreateNoWindow = true, UseShellExecute = false });

        MessageBox.Show("DC Launcher has been uninstalled.\nYour WSL server data is untouched.",
            "DC Launcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    public static void RegisterUninstallEntry(string exePath)
    {
        try
        {
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(AppRegKey))
            {
                if (key == null) return;
                key.SetValue("DisplayName",     "DC Launcher");
                key.SetValue("DisplayVersion",  VERSION);
                key.SetValue("Publisher",       "darkcenturies");
                key.SetValue("InstallLocation", InstallDir);
                key.SetValue("DisplayIcon",     exePath + ",0");
                key.SetValue("UninstallString", "\"" + exePath + "\" --uninstall");
                key.SetValue("NoModify",  1, Microsoft.Win32.RegistryValueKind.DWord);
                key.SetValue("NoRepair",  1, Microsoft.Win32.RegistryValueKind.DWord);
                key.SetValue("EstimatedSize", 4096, Microsoft.Win32.RegistryValueKind.DWord);
            }
        }
        catch { }
    }

    public static void CreateShortcuts(string exePath)
    {
        string startMenuDir = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DC Launcher");
        try { System.IO.Directory.CreateDirectory(startMenuDir); } catch { }

        string startLnk  = System.IO.Path.Combine(startMenuDir, "DC Launcher.lnk");
        string desktopLnk = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DC Launcher.lnk");

        string ps = "$s=New-Object -COM WScript.Shell;" +
            "$sc=$s.CreateShortcut('" + startLnk.Replace("'","''") + "');" +
            "$sc.TargetPath='" + exePath.Replace("'","''") + "';$sc.Save();" +
            "$sc=$s.CreateShortcut('" + desktopLnk.Replace("'","''") + "');" +
            "$sc.TargetPath='" + exePath.Replace("'","''") + "';$sc.Save()";
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -NonInteractive -Command \"" + ps + "\"");
        psi.CreateNoWindow = true; psi.UseShellExecute = false;
        try { var pr = Process.Start(psi); if (pr != null) pr.WaitForExit(10000); } catch { }
    }

    // =========================================================================
    // Import Backup
    // =========================================================================

    void ShowImportBackupDialog()
    {
        DeferCloseMenu();

        string backupPath;
        using (var ofd = new OpenFileDialog())
        {
            ofd.Title  = "Select a server backup file";
            ofd.Filter = "Backup files (*.sql.gz;*.sql;*.zip)|*.sql.gz;*.sql;*.zip|All files (*.*)|*.*";
            if (ofd.ShowDialog() != DialogResult.OK) return;
            backupPath = ofd.FileName;
        }

        string[] titles = LoadTitleCache();
        string target = "";
        if (titles.Length == 0)
        {
            MessageBox.Show(
                "No installed server found.\nInstall a server first, then import a backup.",
                "Import Backup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (titles.Length == 1)
        {
            target = titles[0].Trim();
        }
        else
        {
            using (var pick = new Form())
            {
                pick.Text = "Import Backup — Select Server";
                pick.Size = new Size(360, 160);
                pick.StartPosition = FormStartPosition.CenterScreen;
                pick.FormBorderStyle = FormBorderStyle.FixedDialog;
                pick.MaximizeBox = false; pick.MinimizeBox = false;
                var lbl2   = new Label  { Text = "Restore into:", Left = 12, Top = 16, Width = 320, Height = 20 };
                var combo  = new ComboBox { Left = 12, Top = 40, Width = 320, DropDownStyle = ComboBoxStyle.DropDownList };
                foreach (var t in titles) combo.Items.Add(t.Trim());
                combo.SelectedIndex = 0;
                var ok2  = new Button { Text = "OK",     Left = 160, Top = 85, Width = 80, DialogResult = DialogResult.OK };
                var can2 = new Button { Text = "Cancel", Left = 250, Top = 85, Width = 80, DialogResult = DialogResult.Cancel };
                pick.Controls.AddRange(new Control[] { lbl2, combo, ok2, can2 });
                pick.AcceptButton = ok2; pick.CancelButton = can2;
                if (pick.ShowDialog() != DialogResult.OK) return;
                target = (combo.SelectedItem as string ?? "").Trim();
            }
        }
        if (string.IsNullOrEmpty(target)) return;

        string fileName = System.IO.Path.GetFileName(backupPath);
        string wslTmp   = @"\\wsl$\" + DISTRO + @"\tmp\dc-import";
        string linuxTmp = "/tmp/dc-import";
        try
        {
            if (!System.IO.Directory.Exists(wslTmp)) System.IO.Directory.CreateDirectory(wslTmp);
            System.IO.File.Copy(backupPath, System.IO.Path.Combine(wslTmp, fileName), true);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Could not copy backup into WSL:\n" + ex.Message,
                "Import Backup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string lower = fileName.ToLower();
        string restoreCmd;
        if (lower.EndsWith(".sql.gz"))
            restoreCmd =
                "echo '[DC] Starting restore of " + fileName + " into " + target + "...' && " +
                "gunzip -c " + linuxTmp + "/" + fileName + " | docker exec -i ac-database mysql -u root -ppassword && " +
                "echo '[DC] Restore complete.' && exec bash -l";
        else if (lower.EndsWith(".zip"))
            restoreCmd =
                "mkdir -p " + linuxTmp + "/x && unzip -o " + linuxTmp + "/" + fileName + " -d " + linuxTmp + "/x && " +
                "find " + linuxTmp + "/x -name '*.sql' | sort | while read f; do " +
                "echo \"[DC] Importing $(basename $f)...\"; docker exec -i ac-database mysql -u root -ppassword < \"$f\"; done && " +
                "echo '[DC] Restore complete.' && exec bash -l";
        else
            restoreCmd =
                "echo '[DC] Starting restore of " + fileName + "...' && " +
                "docker exec -i ac-database mysql -u root -ppassword < " + linuxTmp + "/" + fileName + " && " +
                "echo '[DC] Restore complete.' && exec bash -l";

        OpenLiveConsole(restoreCmd, "Import Backup — " + target);
    }

    static string ToWslPath(string input)
    {
        // Convert C:\path\to\folder -> /mnt/c/path/to/folder
        if (input.Length >= 3 && input[1] == ':' && (input[2] == '\\' || input[2] == '/'))
            return "/mnt/" + input.Substring(0, 1).ToLower() + "/" + input.Substring(3).Replace('\\', '/');
        return input;
    }
}

// =============================================================================
// Setup Wizard - shown on first run when not yet installed
// =============================================================================
class SetupWizardForm : Form
{
    Panel[]  _pages;
    int      _page = 0;
    Button   _btnNext, _btnBack;
    Label    _stepLabel;
    Label    _stCopy, _stShortcut, _stRegistry;
    string   _chosenInstallDir;

    const string BASE_URL = "https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/";

    public SetupWizardForm()
    {
        _chosenInstallDir = TrayApp.InstallDir;  // default = Program Files
        Text            = "DC Launcher Setup";
        Size            = new Size(520, 380);
        StartPosition   = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox     = false;
        MinimizeBox     = false;
        try {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        } catch { }

        _stepLabel = new Label {
            Left = 0, Top = 320, Width = 520, Height = 20,
            TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = Color.FromArgb(120, 120, 120)
        };
        Controls.Add(_stepLabel);

        _btnBack = new Button { Text = "<< Back", Left = 296, Top = 308, Width = 90 };
        _btnNext = new Button { Text = "Next >>",  Left = 400, Top = 308, Width = 90 };
        _btnBack.Click += delegate { GoPage(_page - 1); };
        _btnNext.Click += delegate { OnNext(); };
        Controls.Add(_btnBack);
        Controls.Add(_btnNext);

        _pages = new Panel[] { BuildPage0(), BuildPage1(), BuildPage2(), BuildPage3(), BuildPage4() };
        foreach (var pg in _pages) { pg.Visible = false; Controls.Add(pg); }
        GoPage(0);
    }

    void GoPage(int n)
    {
        if (n < 0 || n >= _pages.Length) return;
        if (_page >= 0 && _page < _pages.Length) _pages[_page].Visible = false;
        _page = n;
        _pages[_page].Visible = true;
        _btnBack.Enabled = (_page > 0 && _page < 4);
        _btnNext.Text    = (_page == 4) ? "Finish" : "Next >>";
        _stepLabel.Text  = (_page > 0 && _page < 4) ? "Step " + _page + " of 3" : "";
    }

    void OnNext()
    {
        if (_page == 4) { LaunchInstalled(); Close(); return; }
        GoPage(_page + 1);
        if (_page == 1) RunSelfInstall();
    }

    void LaunchInstalled()
    {
        string dest = System.IO.Path.Combine(_chosenInstallDir, "DC-Launcher.exe");
        string found = TrayApp.FindInstalledExe();
        if (found != null) dest = found;
        if (System.IO.File.Exists(dest))
            try { System.Diagnostics.Process.Start(dest); } catch { }
    }

    // Page 0: Welcome + install location picker
    Panel BuildPage0()
    {
        var p = MakePage();
        p.Controls.Add(BigLabel("Welcome to DC Launcher", 20, 20));
        p.Controls.Add(MakeLabel(
            "This sets up your WoW: Wrath of the Lich King private server on Windows.\n\n" +
            "What gets installed:\n" +
            "  * DC Launcher (system tray app, shows in Apps & Features)\n" +
            "  * WSL2 + Docker (one-time environment)\n" +
            "  * AzerothCore WotLK 3.3.5a + Playerbots\n\n" +
            "Total time: 20-30 minutes first run.",
            20, 60, 460, 150));

        p.Controls.Add(MakeLabel("Install location:", 20, 215, 140, 20));

        var txtDir = new TextBox {
            Left = 20, Top = 235, Width = 380, Height = 24,
            Text = _chosenInstallDir
        };
        var btnBrowse = new Button {
            Text = "Browse...", Left = 410, Top = 233, Width = 80
        };
        btnBrowse.Click += delegate {
            using (var dlg = new FolderBrowserDialog()) {
                dlg.Description     = "Choose where to install DC Launcher";
                dlg.SelectedPath    = txtDir.Text;
                dlg.ShowNewFolderButton = true;
                if (dlg.ShowDialog() == DialogResult.OK)
                    txtDir.Text = dlg.SelectedPath;
            }
        };
        txtDir.TextChanged += delegate { _chosenInstallDir = txtDir.Text.Trim(); };

        p.Controls.AddRange(new Control[] { txtDir, btnBrowse });
        return p;
    }

    // Page 1: Self-install (automatic)
    Panel BuildPage1()
    {
        var p = MakePage();
        p.Controls.Add(BigLabel("Installing DC Launcher...", 20, 20));
        _stCopy     = StatusLabel("Copying files...",                    20, 70);
        _stShortcut = StatusLabel("Creating shortcuts...",              20, 100);
        _stRegistry = StatusLabel("Registering in Apps & Features...", 20, 130);
        p.Controls.AddRange(new Control[] { _stCopy, _stShortcut, _stRegistry });
        return p;
    }

    void RunSelfInstall()
    {
        // If target needs admin rights and we are not elevated, restart elevated
        if (TrayApp.NeedsElevationForPath(_chosenInstallDir) && !TrayApp.IsElevated())
        {
            MessageBox.Show(
                "Installing to Program Files requires administrator rights.\n\n" +
                "You will be prompted by Windows to allow this.",
                "DC Launcher Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
            TrayApp.RelaunhElevated(new string[0]);
            Close();
            return;
        }

        _btnNext.Enabled = false;
        _btnBack.Enabled = false;
        System.Threading.ThreadPool.QueueUserWorkItem(delegate {
            string src  = System.Reflection.Assembly.GetExecutingAssembly().Location;
            string installDir = _chosenInstallDir;
            string dest = System.IO.Path.Combine(installDir, "DC-Launcher.exe");

            try {
                System.IO.Directory.CreateDirectory(installDir);
                System.IO.File.Copy(src, dest, true);
                SetStatus(_stCopy, "OK - Copied to " + installDir, Color.FromArgb(30,160,60));
            } catch (Exception ex) {
                SetStatus(_stCopy, "FAILED: " + ex.Message, Color.Red);
                PostUi(delegate { _btnNext.Enabled = true; });
                return;
            }

            try {
                TrayApp.CreateShortcuts(dest);
                SetStatus(_stShortcut, "OK - Shortcuts created (Start Menu + Desktop)", Color.FromArgb(30,160,60));
            } catch {
                SetStatus(_stShortcut, "OK - Shortcuts skipped", Color.FromArgb(150,150,0));
            }

            try {
                TrayApp.RegisterUninstallEntry(dest);
                SetStatus(_stRegistry, "OK - Visible in Settings > Apps", Color.FromArgb(30,160,60));
            } catch {
                SetStatus(_stRegistry, "OK - Registry skipped", Color.FromArgb(150,150,0));
            }

            System.Threading.Thread.Sleep(800);
            PostUi(delegate { _btnNext.Enabled = true; _btnBack.Enabled = false; GoPage(2); });
        });
    }

    // Page 2: Base environment
    Panel BuildPage2()
    {
        var p = MakePage();
        p.Controls.Add(BigLabel("Step 1 of 3 - Base Environment", 20, 20));
        p.Controls.Add(MakeLabel(
            "Installs WSL2, Arch Linux, Docker, and the dml tools.\n" +
            "A setup window opens - follow the on-screen prompts.\n" +
            "This runs once and takes about 10 minutes.",
            20, 60, 460, 65));

        var btnRun  = new Button { Text = "Run Base Setup",    Left = 20,  Top = 160, Width = 160 };
        var btnSkip = new Button { Text = "Skip (already done)", Left = 196, Top = 160, Width = 160 };
        bool[] busy = { false };
        btnRun.Click += delegate {
            if (busy[0]) return; busy[0] = true; btnRun.Enabled = false;
            DownloadAndRun(BASE_URL + "guides/DML-Windows/Install-DML.ps1", "Install-DML.ps1", true,
                delegate { PostUi(delegate { btnRun.Enabled = true; busy[0] = false; }); });
        };
        btnSkip.Click += delegate { GoPage(3); };
        p.Controls.AddRange(new Control[] { btnRun, btnSkip });
        return p;
    }

    // Page 3: WoW server
    Panel BuildPage3()
    {
        var p = MakePage();
        p.Controls.Add(BigLabel("Step 2 of 3 - Install WoW Server", 20, 20));
        p.Controls.Add(MakeLabel(
            "Installs WotLK 3.3.5a (AzerothCore + Playerbots).\n" +
            "Downloads ~10 GB - takes 10-20 minutes.",
            20, 60, 460, 50));

        var chkDC = new CheckBox {
            Text = "Also install Dark Centuries (zone control warfare plugin)",
            Left = 20, Top = 120, Width = 460, Height = 24
        };

        var btnRun  = new Button { Text = "Install WotLK Server", Left = 20,  Top = 168, Width = 180 };
        var btnSkip = new Button { Text = "Skip (already done)",  Left = 216, Top = 168, Width = 160 };
        bool[] busy2 = { false };
        btnRun.Click += delegate {
            if (busy2[0]) return; busy2[0] = true; btnRun.Enabled = false;
            bool addDC = chkDC.Checked;
            DownloadAndRun(BASE_URL + "guides/wow-wotlk/Install-WoW-WotLK.ps1",
                "Install-WoW-WotLK.ps1", true, delegate {
                    PostUi(delegate { btnRun.Enabled = true; busy2[0] = false; });
                    if (addDC)
                        PostUi(delegate {
                            DownloadAndRun(
                                BASE_URL + "dark-centuries/install.sh",
                                "dc-install.sh", false, null);
                        });
                });
        };
        btnSkip.Click += delegate { GoPage(4); };
        p.Controls.AddRange(new Control[] { chkDC, btnRun, btnSkip });
        return p;
    }

    // Page 4: Done
    Panel BuildPage4()
    {
        var p = MakePage();
        p.Controls.Add(BigLabel("All done!", 20, 20));
        p.Controls.Add(MakeLabel(
            "DC Launcher is installed on this PC.\n\n" +
            "Click Finish to start it - the icon will appear in your system tray.\n\n" +
            "Right-click the tray icon to start, stop, or manage your server.\n\n" +
            "To uninstall: Settings > Apps > DC Launcher > Uninstall",
            20, 60, 460, 180));
        return p;
    }

    void DownloadAndRun(string url, string fileName, bool elevated, Action onDone)
    {
        System.Threading.ThreadPool.QueueUserWorkItem(delegate {
            string tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), fileName);
            try {
                System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
                using (var wc = new System.Net.WebClient())
                { wc.Headers.Add("User-Agent", "DC-Launcher"); wc.DownloadFile(url, tmp); }
            } catch (Exception ex) {
                PostUi(delegate {
                    MessageBox.Show("Download failed:\n" + ex.Message,
                        "DC Launcher Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    if (onDone != null) onDone();
                });
                return;
            }
            PostUi(delegate {
                System.Diagnostics.ProcessStartInfo psi;
                if (fileName.EndsWith(".ps1"))
                {
                    psi = new System.Diagnostics.ProcessStartInfo("powershell.exe",
                        "-NoProfile -ExecutionPolicy Bypass -File \"" + tmp + "\"");
                    psi.UseShellExecute = true;
                    if (elevated) psi.Verb = "runas";
                }
                else
                {
                    psi = new System.Diagnostics.ProcessStartInfo("wt.exe",
                        "new-tab -- wsl -d dml-arch -- bash -c \"curl -fsSL " + url + " | bash\"");
                    psi.UseShellExecute = true;
                }
                try { System.Diagnostics.Process.Start(psi); } catch { }
                if (onDone != null) onDone();
            });
        });
    }

    Panel MakePage()
    {
        return new Panel { Location = new System.Drawing.Point(0, 0), Size = new Size(520, 300) };
    }

    Label BigLabel(string text, int x, int y)
    {
        var l = new Label { Text = text, Left = x, Top = y, Width = 460, Height = 30 };
        try { l.Font = new Font(SystemFonts.MenuFont.FontFamily, 13f, FontStyle.Bold); } catch { }
        return l;
    }

    Label MakeLabel(string text, int x, int y, int w, int h)
    {
        return new Label { Text = text, Left = x, Top = y, Width = w, Height = h };
    }

    Label StatusLabel(string text, int x, int y)
    {
        return new Label {
            Text = "  " + text, Left = x, Top = y, Width = 460, Height = 22,
            ForeColor = Color.FromArgb(140, 140, 140)
        };
    }

    void SetStatus(Label lbl, string text, Color col)
    {
        PostUi(delegate { lbl.Text = text; lbl.ForeColor = col; });
    }

    void PostUi(Action a)
    {
        if (IsDisposed) return;
        if (InvokeRequired) BeginInvoke(a);
        else a();
    }
}
