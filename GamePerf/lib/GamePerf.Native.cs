// GamePerf.Native.cs  -  the hot-path helpers for GamePerf
// ----------------------------------------------------------------
// Compiled once by GamePerf-Common.ps1 (Initialize-GpNative) and cached
// as a DLL, so a session pays the compiler cost one time, not per run.
//
// Everything that runs every second while you are gaming lives here
// rather than in PowerShell, because the logger must cost the game as
// little as possible. The design rules, carried over from FullTrace:
//
//  * Read each performance-counter CATEGORY once per sample and compute
//    every rate from two raw samples (CounterSample.Calculate). The old
//    pattern - one PerformanceCounter object per counter per core, each
//    .NextValue() re-reading the whole category - costs ~100 registry
//    reads a second on a 32-thread chip. This costs three.
//  * Never throw into the sampling loop. A sensor that fails returns
//    NaN / empty and the rest of the row still logs.
//
// Must stay C# 5: Windows PowerShell 5.1's Add-Type uses the .NET
// Framework compiler. No string interpolation, no ?. operator, no
// expression-bodied members, no out-var. tests/test-gameperf.ps1
// compiles this file with -langversion:5 to keep it that way.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace GamePerf.Native
{
    // ================================================================
    //  Small Win32 helpers
    // ================================================================
    public static class Win
    {
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("ntdll.dll")]  static extern int NtQueryTimerResolution(out uint maximum, out uint minimum, out uint current);

        /// <summary>PID that owns the foreground window, or 0.</summary>
        public static int ForegroundPid()
        {
            try
            {
                IntPtr h = GetForegroundWindow();
                if (h == IntPtr.Zero) return 0;
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                return (int)pid;
            }
            catch { return 0; }
        }

        /// <summary>True while the key is physically held. Works with a fullscreen game focused.</summary>
        public static bool KeyDown(int vk)
        {
            try { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
            catch { return false; }
        }

        /// <summary>Current system timer resolution in ms (15.625 default, 0.5 when a game raised it).</summary>
        public static double TimerResolutionMs()
        {
            try
            {
                uint mx, mn, cur;
                if (NtQueryTimerResolution(out mx, out mn, out cur) != 0) return double.NaN;
                return cur / 10000.0;
            }
            catch { return double.NaN; }
        }

        /// <summary>QueryPerformanceCounter. Same clock PresentMon's CPUStartQPC column uses.</summary>
        public static long Qpc() { return Stopwatch.GetTimestamp(); }
        public static long QpcFrequency() { return Stopwatch.Frequency; }

        // ---- power plan, straight from the power API ---------------------
        // FullTrace ran "powercfg /getactivescheme" for this. From a windowless
        // process every such launch can flash a console window over the game,
        // and it costs a process start; the API costs neither.
        [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
        [DllImport("powrprof.dll")] static extern uint PowerReadFriendlyName(IntPtr root, IntPtr scheme, IntPtr subGroup, IntPtr setting, IntPtr buffer, ref uint size);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);

        /// <summary>Name of the active power plan, or "".</summary>
        public static string ActivePowerPlanName()
        {
            IntPtr g = IntPtr.Zero;
            try
            {
                if (PowerGetActiveScheme(IntPtr.Zero, out g) != 0 || g == IntPtr.Zero) return "";
                uint size = 0;
                PowerReadFriendlyName(IntPtr.Zero, g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref size);
                if (size == 0 || size > 4096) return "";
                IntPtr buf = Marshal.AllocHGlobal((int)size);
                try
                {
                    if (PowerReadFriendlyName(IntPtr.Zero, g, IntPtr.Zero, IntPtr.Zero, buf, ref size) != 0) return "";
                    return Marshal.PtrToStringUni(buf) ?? "";
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch { return ""; }
            finally { if (g != IntPtr.Zero) LocalFree(g); }
        }

        // ---- window helpers for the app ----------------------------------
        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);

        [StructLayout(LayoutKind.Sequential)]
        struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
        [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO fi);

        /// <summary>Hide the console window, if this process has one.</summary>
        public static void HideConsole()
        {
            try { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); } catch { }
        }

        /// <summary>Dark title bar on Windows 10 20H1+ / 11.</summary>
        public static void DarkTitleBar(IntPtr hwnd)
        {
            try { int on = 1; if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4); } catch { }
        }

        /// <summary>Flash the taskbar button until the window is brought forward - a quiet "done", no focus stolen.</summary>
        public static void FlashTaskbar(IntPtr hwnd)
        {
            try
            {
                FLASHWINFO fi = new FLASHWINFO();
                fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
                fi.hwnd = hwnd; fi.dwFlags = 0x2 | 0xC; fi.uCount = 0; fi.dwTimeout = 0;   // FLASHW_TRAY | FLASHW_TIMERNOFG
                FlashWindowEx(ref fi);
            }
            catch { }
        }

        /// <summary>Own taskbar identity, so the app does not group with PowerShell windows.</summary>
        public static void SetAppId(string id)
        {
            try { SetCurrentProcessExplicitAppUserModelID(id); } catch { }
        }
    }

    // ================================================================
    //  Start helper programs without ever showing a window
    // ================================================================
    //  The logger has no console. A console program started the ordinary way
    //  (PowerShell's & or Start-Process) from such a process can get a console
    //  window of its own - over the game. CreateNoWindow means it never has one.
    public static class Run
    {
        public static Process Start(string file, string arguments)
        {
            ProcessStartInfo psi = new ProcessStartInfo(file, arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            return Process.Start(psi);
        }

        /// <summary>Run to completion and return stdout, or null on failure / timeout.</summary>
        public static string Capture(string file, string arguments, int timeoutMs)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(file, arguments);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    System.Threading.Tasks.Task<string> o = p.StandardOutput.ReadToEndAsync();
                    System.Threading.Tasks.Task<string> e = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } return null; }
                    p.WaitForExit();
                    try { e.Wait(1000); } catch { }
                    return o.Result;
                }
            }
            catch { return null; }
        }
    }

    // ================================================================
    //  One performance-counter category, read once per sample
    // ================================================================
    public sealed class CategoryReader
    {
        sealed class Entry
        {
            public CounterSample[] S;
            public bool[] Has;
            public Entry(int n) { S = new CounterSample[n]; Has = new bool[n]; }
        }

        readonly PerformanceCounterCategory _cat;
        readonly string[] _counters;
        Dictionary<string, Entry> _prev;

        public bool Ok { get; private set; }
        public string Error { get; private set; }
        public string Category { get; private set; }

        public CategoryReader(string category, string[] counters)
        {
            Category = category;
            _counters = counters;
            try
            {
                _cat = new PerformanceCounterCategory(category);
                _prev = Read();
                Ok = true;
            }
            catch (Exception e) { Ok = false; Error = e.Message; }
        }

        public static bool Exists(string category)
        {
            try { return PerformanceCounterCategory.Exists(category); }
            catch { return false; }
        }

        Dictionary<string, Entry> Read()
        {
            InstanceDataCollectionCollection all = _cat.ReadCategory();
            Dictionary<string, Entry> cur = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < _counters.Length; i++)
            {
                InstanceDataCollection idc = null;
                try { idc = all[_counters[i]]; } catch { }
                if (idc == null) continue;
                foreach (InstanceData d in idc.Values)
                {
                    Entry e;
                    if (!cur.TryGetValue(d.InstanceName, out e)) { e = new Entry(_counters.Length); cur[d.InstanceName] = e; }
                    e.S[i] = d.Sample;
                    e.Has[i] = true;
                }
            }
            return cur;
        }

        /// <summary>instance -> computed value per counter (NaN where a counter is missing).</summary>
        public Dictionary<string, double[]> Sample()
        {
            Dictionary<string, double[]> result = new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase);
            if (!Ok) return result;
            Dictionary<string, Entry> cur;
            try { cur = Read(); }
            catch (Exception e) { Error = e.Message; return result; }

            if (_prev != null)
            {
                foreach (KeyValuePair<string, Entry> kv in cur)
                {
                    Entry old;
                    if (!_prev.TryGetValue(kv.Key, out old)) continue;
                    double[] v = new double[_counters.Length];
                    for (int i = 0; i < v.Length; i++)
                    {
                        v[i] = double.NaN;
                        if (!kv.Value.Has[i] || !old.Has[i]) continue;
                        try { v[i] = CounterSample.Calculate(old.S[i], kv.Value.S[i]); } catch { }
                    }
                    result[kv.Key] = v;
                }
            }
            _prev = cur;
            return result;
        }
    }

    // ================================================================
    //  CPU: per-core load, interrupt/DPC, effective clock
    // ================================================================
    public sealed class CpuSample
    {
        public double Total = double.NaN, Group0 = double.NaN, Group1 = double.NaN;
        public int BusyCore = -1;
        public double BusyPct = double.NaN;
        public double Cpu0Int = double.NaN, Cpu0Dpc = double.NaN;
        public double SplitInt = double.NaN, SplitDpc = double.NaN;
        public double TotInt = double.NaN, TotDpc = double.NaN;
        public double EffMhz = double.NaN;
    }

    public sealed class CpuSampler
    {
        readonly CategoryReader _r;
        readonly string[] _ordered;
        readonly int _split;

        public int LogicalCount { get { return _ordered.Length; } }
        public int Split { get { return _split; } }
        public bool Ok { get { return _r.Ok && _ordered.Length > 0; } }
        public string Error { get { return _r.Error; } }
        public string Category { get { return _r.Category; } }

        public CpuSampler(int split)
        {
            // "Processor Information" sees every processor group; "Processor"
            // stops at group 0 and silently halves a >64-thread machine.
            string cat = CategoryReader.Exists("Processor Information") ? "Processor Information" : "Processor";
            _r = new CategoryReader(cat, new string[] {
                "% Processor Time", "% Interrupt Time", "% DPC Time", "% Processor Performance", "Processor Frequency" });

            List<KeyValuePair<long, string>> list = new List<KeyValuePair<long, string>>();
            try
            {
                foreach (string n in new PerformanceCounterCategory(cat).GetInstanceNames())
                {
                    if (cat == "Processor Information")
                    {
                        string[] p = n.Split(',');
                        int g, c;
                        if (p.Length == 2 && int.TryParse(p[0], out g) && int.TryParse(p[1], out c))
                            list.Add(new KeyValuePair<long, string>((long)g * 4096 + c, n));
                    }
                    else
                    {
                        int c;
                        if (int.TryParse(n, out c)) list.Add(new KeyValuePair<long, string>(c, n));
                    }
                }
            }
            catch { }
            list.Sort(delegate (KeyValuePair<long, string> a, KeyValuePair<long, string> b) { return a.Key.CompareTo(b.Key); });
            _ordered = new string[list.Count];
            for (int i = 0; i < list.Count; i++) _ordered[i] = list[i].Value;
            _split = (split >= 1 && split < _ordered.Length) ? split : _ordered.Length / 2;
        }

        static double At(double[] v, int i) { return (v != null && i < v.Length) ? v[i] : double.NaN; }

        public CpuSample Sample()
        {
            CpuSample s = new CpuSample();
            Dictionary<string, double[]> d = _r.Sample();
            if (d.Count == 0) return s;

            double sum0 = 0, sum1 = 0; int n0 = 0, n1 = 0;
            for (int i = 0; i < _ordered.Length; i++)
            {
                double[] v;
                if (!d.TryGetValue(_ordered[i], out v)) continue;
                double pt = Math.Max(0, Math.Min(100, v[0]));
                if (double.IsNaN(v[0])) continue;
                if (i < _split) { sum0 += pt; n0++; } else { sum1 += pt; n1++; }
                if (s.BusyCore < 0 || pt > s.BusyPct) { s.BusyCore = i; s.BusyPct = pt; }
                if (i == 0) { s.Cpu0Int = v[1]; s.Cpu0Dpc = v[2]; }
                if (i == _split) { s.SplitInt = v[1]; s.SplitDpc = v[2]; }
            }
            if (n0 > 0) s.Group0 = sum0 / n0;
            if (n1 > 0) s.Group1 = sum1 / n1;

            double[] t;
            if (d.TryGetValue("_Total", out t))
            {
                s.Total = Math.Max(0, Math.Min(100, At(t, 0)));
                s.TotInt = At(t, 1);
                s.TotDpc = At(t, 2);
                double perf = At(t, 3), freq = At(t, 4);
                if (!double.IsNaN(perf) && !double.IsNaN(freq) && freq > 0) s.EffMhz = freq * perf / 100.0;
            }
            return s;
        }
    }

    // ================================================================
    //  Memory + disk
    // ================================================================
    public sealed class SysSample
    {
        public double HardFaults = double.NaN, AvailMb = double.NaN, CommitPct = double.NaN;
        public double DiskReadMBs = double.NaN, DiskWriteMBs = double.NaN, DiskBusyPct = double.NaN, DiskQueue = double.NaN;
    }

    public sealed class SysSampler
    {
        readonly CategoryReader _mem;
        readonly CategoryReader _disk;

        public string Error
        {
            get
            {
                if (!_mem.Ok) return "Memory: " + _mem.Error;
                if (!_disk.Ok) return "PhysicalDisk: " + _disk.Error;
                return null;
            }
        }

        public SysSampler()
        {
            _mem = new CategoryReader("Memory", new string[] { "Pages Input/sec", "Available MBytes", "% Committed Bytes In Use" });
            _disk = new CategoryReader("PhysicalDisk", new string[] { "Disk Read Bytes/sec", "Disk Write Bytes/sec", "% Idle Time", "Current Disk Queue Length" });
        }

        public SysSample Sample()
        {
            SysSample s = new SysSample();
            foreach (KeyValuePair<string, double[]> kv in _mem.Sample())
            {
                // single-instance category: one entry, whatever it is called
                s.HardFaults = kv.Value[0];
                s.AvailMb = kv.Value[1];
                s.CommitPct = kv.Value[2];
                break;
            }
            double[] d;
            if (_disk.Sample().TryGetValue("_Total", out d))
            {
                s.DiskReadMBs = d[0] / 1048576.0;
                s.DiskWriteMBs = d[1] / 1048576.0;
                if (!double.IsNaN(d[2])) s.DiskBusyPct = 100.0 - Math.Max(0, Math.Min(100, d[2]));
                s.DiskQueue = d[3];
            }
            return s;
        }
    }

    // ================================================================
    //  GPU fallback for cards nvidia-smi cannot see (AMD / Intel)
    //  Windows' own "GPU Engine" counters. Costlier than nvidia-smi,
    //  so the logger only builds this when nothing better exists.
    // ================================================================
    public sealed class GpuEngineSampler
    {
        readonly CategoryReader _eng;
        readonly CategoryReader _mem;

        public GpuEngineSampler()
        {
            _eng = new CategoryReader("GPU Engine", new string[] { "Utilization Percentage" });
            _mem = new CategoryReader("GPU Adapter Memory", new string[] { "Dedicated Usage" });
        }

        public bool Ok { get { return _eng.Ok; } }

        /// <summary>Busiest adapter's 3D utilisation %, game's own 3D share %, dedicated VRAM MB.</summary>
        public double[] Sample(int gamePid)
        {
            double[] r = new double[] { double.NaN, double.NaN, double.NaN };
            Dictionary<string, double> perLuid = new Dictionary<string, double>();
            double game = 0; bool any = false;
            string gameTag = "pid_" + gamePid.ToString(CultureInfo.InvariantCulture) + "_";
            foreach (KeyValuePair<string, double[]> kv in _eng.Sample())
            {
                string n = kv.Key;
                if (n.IndexOf("engtype_3D", StringComparison.OrdinalIgnoreCase) < 0) continue;
                double v = kv.Value[0];
                if (double.IsNaN(v)) continue;
                any = true;
                int li = n.IndexOf("luid_", StringComparison.OrdinalIgnoreCase);
                int pi = n.IndexOf("_phys", StringComparison.OrdinalIgnoreCase);
                string luid = (li >= 0 && pi > li) ? n.Substring(li, pi - li) : "all";
                double cur;
                perLuid.TryGetValue(luid, out cur);
                perLuid[luid] = cur + v;
                if (gamePid > 0 && n.StartsWith(gameTag, StringComparison.OrdinalIgnoreCase)) game += v;
            }
            if (any)
            {
                double best = 0;
                foreach (double v in perLuid.Values) if (v > best) best = v;
                r[0] = Math.Min(100, best);
                if (gamePid > 0) r[1] = Math.Min(100, game);
            }
            double vram = 0; bool anyMem = false;
            foreach (KeyValuePair<string, double[]> kv in _mem.Sample())
            {
                if (double.IsNaN(kv.Value[0])) continue;
                anyMem = true;
                vram = Math.Max(vram, kv.Value[0]);
            }
            if (anyMem) r[2] = vram / 1048576.0;
            return r;
        }
    }

    // ================================================================
    //  Per-process CPU, memory and busiest thread
    // ================================================================
    public sealed class ProcSample
    {
        public bool Alive;
        public double CpuPct = double.NaN, Cores = double.NaN, TopThreadPct = double.NaN;
        public int TopThreadId;
        public double WorkingSetMb = double.NaN, PrivateMb = double.NaN;
        public int Threads;
        public long Affinity;
    }

    /// <summary>
    /// Process and thread queries through PROCESS_QUERY_LIMITED_INFORMATION
    /// handles. .NET's Process.HasExited / TotalProcessorTime ask for
    /// PROCESS_QUERY_INFORMATION, which a non-elevated logger is refused for an
    /// elevated game (and an anti-cheat protected one): the game would look
    /// "exited" every second. The limited right is granted in both cases.
    /// </summary>
    public static class ProcApi
    {
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, SYNCHRONIZE = 0x00100000, THREAD_QUERY_LIMITED_INFORMATION = 0x0800;
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, int tid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")] static extern bool GetProcessAffinityMask(IntPtr h, out UIntPtr process, out UIntPtr system);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);

        /// <summary>A handle good for liveness, CPU time, affinity and image path. Zero if refused.</summary>
        public static IntPtr Open(int pid) { return OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, pid); }

        public static bool IsRunning(IntPtr h) { return h != IntPtr.Zero && WaitForSingleObject(h, 0) == 258; }   // WAIT_TIMEOUT

        public static double CpuMs(IntPtr h)
        {
            long c, e, k, u;
            return GetProcessTimes(h, out c, out e, out k, out u) ? (k + u) / 10000.0 : double.NaN;
        }

        public static double CpuMsOf(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return double.NaN;
            try { return CpuMs(h); } finally { CloseHandle(h); }
        }

        public static double ThreadMs(int tid)
        {
            IntPtr h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, false, tid);
            if (h == IntPtr.Zero) return double.NaN;
            try { long c, e, k, u; return GetThreadTimes(h, out c, out e, out k, out u) ? (k + u) / 10000.0 : double.NaN; }
            finally { CloseHandle(h); }
        }

        public static long Affinity(IntPtr h)
        {
            UIntPtr p, s;
            return GetProcessAffinityMask(h, out p, out s) ? (long)p.ToUInt64() : 0;
        }

        public static string ImagePath(IntPtr h)
        {
            StringBuilder sb = new StringBuilder(1024);
            int n = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : null;
        }
    }

    public sealed class ProcTracker
    {
        readonly Process _p;      // snapshot data only (name, memory, thread list) - never its handle
        readonly IntPtr _h;
        readonly int _ncpu;
        double _lastCpuMs = double.NaN;
        long _lastQpc;
        Dictionary<int, double> _lastThreads = new Dictionary<int, double>();

        public int Pid { get; private set; }
        public string Name { get; private set; }
        public string Path { get; private set; }
        public bool TrackThreads = true;

        public ProcTracker(int pid, int ncpu)
        {
            Pid = pid;
            _ncpu = Math.Max(1, ncpu);
            _p = Process.GetProcessById(pid);
            Name = _p.ProcessName;
            _h = ProcApi.Open(pid);
            if (_h == IntPtr.Zero) throw new InvalidOperationException("Windows refused even limited access to process " + pid + " (error " + Marshal.GetLastWin32Error() + ").");
            Path = ProcApi.ImagePath(_h);
            _lastQpc = Stopwatch.GetTimestamp();
            _lastCpuMs = ProcApi.CpuMs(_h);
            try { foreach (ProcessThread t in _p.Threads) _lastThreads[t.Id] = ProcApi.ThreadMs(t.Id); } catch { }
        }

        ~ProcTracker() { if (_h != IntPtr.Zero) ProcApi.CloseHandle(_h); }

        public ProcSample Sample()
        {
            ProcSample s = new ProcSample();
            if (!ProcApi.IsRunning(_h)) return s;
            s.Alive = true;
            long now = Stopwatch.GetTimestamp();
            double dtMs = (now - _lastQpc) * 1000.0 / Stopwatch.Frequency;
            if (dtMs <= 0) dtMs = 1000;
            _lastQpc = now;

            double cpuMs = ProcApi.CpuMs(_h);
            if (!double.IsNaN(cpuMs) && !double.IsNaN(_lastCpuMs))
            {
                s.Cores = Math.Max(0, (cpuMs - _lastCpuMs) / dtMs);
                s.CpuPct = s.Cores * 100.0 / _ncpu;
            }
            _lastCpuMs = cpuMs;
            s.Affinity = ProcApi.Affinity(_h);
            try
            {
                _p.Refresh();   // re-reads the system snapshot; no handle involved
                s.WorkingSetMb = _p.WorkingSet64 / 1048576.0;
                s.PrivateMb = _p.PrivateMemorySize64 / 1048576.0;
                if (TrackThreads)
                {
                    Dictionary<int, double> cur = new Dictionary<int, double>();
                    double best = 0; int bestId = 0, n = 0; bool any = false;
                    foreach (ProcessThread t in _p.Threads)
                    {
                        n++;
                        double ms = ProcApi.ThreadMs(t.Id);
                        if (double.IsNaN(ms)) continue;
                        cur[t.Id] = ms;
                        double prev;
                        if (_lastThreads.TryGetValue(t.Id, out prev) && !double.IsNaN(prev))
                        {
                            any = true;
                            double pct = (ms - prev) * 100.0 / dtMs;
                            if (pct > best) { best = pct; bestId = t.Id; }
                        }
                    }
                    _lastThreads = cur;
                    s.Threads = n;
                    if (any) { s.TopThreadPct = Math.Min(100, best); s.TopThreadId = bestId; }
                }
            }
            catch { }   // the snapshot raced with the process exiting; liveness above is what counts
            return s;
        }
    }

    /// <summary>Summed CPU of a set of processes (the VR runtime) found by name.</summary>
    public sealed class ProcGroup
    {
        readonly HashSet<string> _names;
        readonly int _ncpu;
        Dictionary<int, double> _last = new Dictionary<int, double>();
        long _lastQpc;
        public List<string> Found = new List<string>();

        public ProcGroup(string[] names, int ncpu)
        {
            _names = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
            _ncpu = Math.Max(1, ncpu);
            Rescan();
        }

        /// <summary>Re-resolve PIDs. Call every few seconds, not every sample: it snapshots every process.</summary>
        public void Rescan()
        {
            Dictionary<int, double> next = new Dictionary<int, double>();
            List<string> found = new List<string>();
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    if (!_names.Contains(p.ProcessName)) continue;
                    double prev, ms;
                    if (_last.TryGetValue(p.Id, out prev)) ms = prev; else ms = ProcApi.CpuMsOf(p.Id);
                    if (double.IsNaN(ms)) continue;
                    next[p.Id] = ms;
                    if (!found.Contains(p.ProcessName)) found.Add(p.ProcessName);
                }
                catch { }
                finally { p.Dispose(); }
            }
            _last = next;
            Found = found;
            if (_lastQpc == 0) _lastQpc = Stopwatch.GetTimestamp();
        }

        /// <summary>Total CPU % of the whole machine used by the group since the last call.</summary>
        public double Sample()
        {
            if (_last.Count == 0) { _lastQpc = Stopwatch.GetTimestamp(); return double.NaN; }
            long now = Stopwatch.GetTimestamp();
            double dtMs = (now - _lastQpc) * 1000.0 / Stopwatch.Frequency;
            if (dtMs <= 0) dtMs = 1000;
            _lastQpc = now;
            double sum = 0;
            foreach (int pid in new List<int>(_last.Keys))
            {
                double ms = ProcApi.CpuMsOf(pid);
                if (double.IsNaN(ms)) { _last.Remove(pid); continue; }
                sum += Math.Max(0, ms - _last[pid]);
                _last[pid] = ms;
            }
            return sum * 100.0 / dtMs / _ncpu;
        }
    }

    /// <summary>Which background processes ate CPU over an interval. Cheap enough every 30 s.</summary>
    public sealed class CpuCensus
    {
        Dictionary<int, KeyValuePair<string, double>> _last = new Dictionary<int, KeyValuePair<string, double>>();
        long _lastQpc;
        public Dictionary<string, double> Total = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);

        public CpuCensus() { Take(); }

        Dictionary<int, KeyValuePair<string, double>> Snap()
        {
            Dictionary<int, KeyValuePair<string, double>> d = new Dictionary<int, KeyValuePair<string, double>>();
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    double ms = ProcApi.CpuMsOf(p.Id);
                    if (!double.IsNaN(ms)) d[p.Id] = new KeyValuePair<string, double>(p.ProcessName, ms);
                }
                catch { }
                finally { p.Dispose(); }
            }
            return d;
        }

        /// <summary>name -> CPU % of the whole machine since the previous call. Also accumulates Total (cpu-seconds).</summary>
        public Dictionary<string, double> Take()
        {
            Dictionary<string, double> r = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
            Dictionary<int, KeyValuePair<string, double>> cur = Snap();
            long now = Stopwatch.GetTimestamp();
            if (_lastQpc != 0)
            {
                double dtMs = (now - _lastQpc) * 1000.0 / Stopwatch.Frequency;
                int ncpu = Environment.ProcessorCount;
                foreach (KeyValuePair<int, KeyValuePair<string, double>> kv in cur)
                {
                    KeyValuePair<string, double> old;
                    if (!_last.TryGetValue(kv.Key, out old) || old.Key != kv.Value.Key) continue;
                    double used = kv.Value.Value - old.Value;
                    if (used <= 0) continue;
                    double v;
                    r.TryGetValue(kv.Value.Key, out v);
                    r[kv.Value.Key] = v + used * 100.0 / dtMs / ncpu;
                    Total.TryGetValue(kv.Value.Key, out v);
                    Total[kv.Value.Key] = v + used / 1000.0;
                }
            }
            _last = cur;
            _lastQpc = now;
            return r;
        }
    }

    // ================================================================
    //  MSI Afterburner shared memory (MAHM)
    // ================================================================
    public static class Afterburner
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        static extern IntPtr OpenFileMapping(uint access, bool inherit, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr MapViewOfFile(IntPtr h, uint access, uint hi, uint lo, UIntPtr bytes);
        [DllImport("kernel32.dll")] static extern bool UnmapViewOfFile(IntPtr addr);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        const uint FILE_MAP_READ = 0x0004;

        /// <summary>Every published sensor, name -> value. Empty when Afterburner is not running.</summary>
        public static Dictionary<string, double> Read()
        {
            Dictionary<string, double> d = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
            IntPtr hMap = IntPtr.Zero, view = IntPtr.Zero;
            try
            {
                hMap = OpenFileMapping(FILE_MAP_READ, false, "MAHMSharedMemory");
                if (hMap == IntPtr.Zero) return d;
                view = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, UIntPtr.Zero);
                if (view == IntPtr.Zero) return d;
                if (Marshal.ReadInt32(view, 0) == 0xDEAD) return d;   // Afterburner is shutting down
                int headerSize = Marshal.ReadInt32(view, 8);
                int num = Marshal.ReadInt32(view, 12);
                int entrySize = Marshal.ReadInt32(view, 16);
                if (headerSize <= 0 || entrySize < 1304 || num <= 0 || num > 2048) return d;
                for (int i = 0; i < num; i++)
                {
                    IntPtr e = new IntPtr(view.ToInt64() + headerSize + (long)i * entrySize);
                    string name = Marshal.PtrToStringAnsi(e, 260);
                    int z = name.IndexOf('\0');
                    if (z >= 0) name = name.Substring(0, z);
                    if (name.Length == 0 || d.ContainsKey(name)) continue;
                    float v = BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(e, 1300)), 0);
                    if (float.IsNaN(v) || Math.Abs(v) >= 1e37f) continue;   // FLT_MAX = "not available"
                    d[name] = v;
                }
            }
            catch { }
            finally
            {
                if (view != IntPtr.Zero) UnmapViewOfFile(view);
                if (hMap != IntPtr.Zero) CloseHandle(hMap);
            }
            return d;
        }
    }

    // ================================================================
    //  Tail a file another process is still writing
    // ================================================================
    public sealed class FileTail
    {
        readonly string _path;
        long _pos;
        string _partial = "";

        public FileTail(string path) { _path = path; }
        public string FilePath { get { return _path; } }

        /// <summary>Complete new lines since the last call. If more than maxBytes arrived, only the newest are kept.</summary>
        public List<string> ReadLines(int maxBytes)
        {
            List<string> lines = new List<string>();
            try
            {
                if (!File.Exists(_path)) return lines;
                using (FileStream fs = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    long len = fs.Length;
                    if (len < _pos) { _pos = 0; _partial = ""; }
                    if (len == _pos) return lines;
                    bool skipFirst = false;
                    long start = _pos;
                    if (maxBytes > 0 && len - start > maxBytes) { start = len - maxBytes; _partial = ""; skipFirst = true; }
                    fs.Seek(start, SeekOrigin.Begin);
                    int want = (int)(len - start);
                    byte[] buf = new byte[want];
                    int read = 0;
                    while (read < want) { int n = fs.Read(buf, read, want - read); if (n <= 0) break; read += n; }
                    _pos = start + read;
                    string text = _partial + Encoding.UTF8.GetString(buf, 0, read);
                    if (text.IndexOf('\0') >= 0) text = text.Replace("\0", "");
                    int s = 0;
                    for (int i = 0; i < text.Length; i++)
                    {
                        if (text[i] != '\n') continue;
                        string l = text.Substring(s, i - s).TrimEnd('\r').TrimStart('\uFEFF');
                        lines.Add(l);
                        s = i + 1;
                    }
                    _partial = text.Substring(s);
                    if (skipFirst && lines.Count > 0) lines.RemoveAt(0);
                }
            }
            catch { }
            return lines;
        }
    }

    // ================================================================
    //  PresentMon CSV - column layout shared by the live tail and the analyzer
    // ================================================================
    //  Three layouts exist in the wild, all confirmed against the 2.6.0 binary:
    //    v1 (legacy / --v1_metrics): TimeInSeconds, msBetweenPresents, Dropped ...
    //    v2.0 (--v2_metrics):        CPUStartTime, FrameTime, CPUBusy, GPUBusy ...
    //    2.x default:                CPUStartTime, MsBetweenPresents, MsCPUBusy, MsGPUBusy ...
    //  --qpc_time swaps CPUStartTime for CPUStartQPC (raw QueryPerformanceCounter
    //  ticks), which is what lets frames join the 1 Hz system log exactly.
    public sealed class FrameColumns
    {
        public int App = -1, Pid = -1, SwapChain = -1, Ft = -1, GpuBusy = -1, CpuBusy = -1, CpuWait = -1;
        public int DisplayChange = -1, Dropped = -1, Qpc = -1, TimeS = -1, TimeMs = -1, PresentMode = -1, SyncInterval = -1;
        public string FtName, GpuBusyName, CpuBusyName;

        public static FrameColumns Parse(string headerLine)
        {
            string[] h = headerLine.Split(',');
            FrameColumns c = new FrameColumns();
            c.App = Find(h, "Application");
            c.Pid = Find(h, "ProcessID");
            c.SwapChain = Find(h, "SwapChainAddress");
            c.Ft = Find(h, "MsBetweenPresents", "FrameTime", "MsBetweenAppStart");
            if (c.Ft >= 0) c.FtName = h[c.Ft].Trim();
            c.GpuBusy = Find(h, "MsGPUBusy", "GPUBusy", "MsGPUActive");
            if (c.GpuBusy >= 0) c.GpuBusyName = h[c.GpuBusy].Trim();
            c.CpuBusy = Find(h, "MsCPUBusy", "CPUBusy");
            if (c.CpuBusy >= 0) c.CpuBusyName = h[c.CpuBusy].Trim();
            c.CpuWait = Find(h, "MsCPUWait", "CPUWait");
            c.DisplayChange = Find(h, "MsBetweenDisplayChange", "DisplayedTime");
            c.Dropped = Find(h, "Dropped");
            c.Qpc = Find(h, "CPUStartQPC");
            c.TimeS = Find(h, "CPUStartTime", "TimeInSeconds", "CPUStartTimeInSeconds");
            c.TimeMs = Find(h, "CPUStartQPCTime", "CPUStartTimeInMs", "CPUStartQPCTimeInMs");
            c.PresentMode = Find(h, "PresentMode");
            c.SyncInterval = Find(h, "SyncInterval");
            return c;
        }

        public bool Valid { get { return Ft >= 0; } }

        static int Find(string[] h, params string[] names)
        {
            foreach (string n in names)
                for (int i = 0; i < h.Length; i++)
                    if (string.Equals(h[i].Trim(), n, StringComparison.OrdinalIgnoreCase)) return i;
            return -1;
        }

        public static double Num(string[] f, int i)
        {
            if (i < 0 || i >= f.Length) return double.NaN;
            double v;
            if (double.TryParse(f[i], NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
            return double.NaN;   // "NA" and blanks
        }

        public static long Long(string[] f, int i)
        {
            if (i < 0 || i >= f.Length) return 0;
            long v;
            if (long.TryParse(f[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) return v;
            double d;
            if (double.TryParse(f[i], NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return (long)d;
            return 0;
        }

        public static string Str(string[] f, int i)
        {
            if (i < 0 || i >= f.Length) return "";
            return f[i].Trim();
        }
    }

    /// <summary>Per-second summary of the frames PresentMon wrote since the last poll. Drives the live tiles.</summary>
    public sealed class FrameWindow
    {
        public int Frames;
        public double FtAvg = double.NaN, FtMax = double.NaN, GpuBusyAvg = double.NaN, CpuBusyAvg = double.NaN;
        public int OverBudget;
    }

    public sealed class LiveFrames
    {
        readonly FileTail _tail;
        readonly double _budgetMs;
        FrameColumns _c;
        public long TotalFrames;
        public long TotalOverBudget;
        public bool HeaderSeen { get { return _c != null; } }

        public LiveFrames(string path, double budgetMs)
        {
            _tail = new FileTail(path);
            _budgetMs = budgetMs;
        }

        public FrameWindow Poll()
        {
            FrameWindow w = new FrameWindow();
            double sumFt = 0, sumG = 0, sumC = 0; int nG = 0, nC = 0;
            foreach (string line in _tail.ReadLines(8 * 1024 * 1024))
            {
                if (line.Length == 0) continue;
                if (_c == null)
                {
                    if (line.IndexOf("Application", StringComparison.OrdinalIgnoreCase) >= 0) _c = FrameColumns.Parse(line);
                    continue;
                }
                if (!_c.Valid) continue;
                string[] f = line.Split(',');
                double ft = FrameColumns.Num(f, _c.Ft);
                if (double.IsNaN(ft) || ft <= 0) continue;
                w.Frames++;
                sumFt += ft;
                if (double.IsNaN(w.FtMax) || ft > w.FtMax) w.FtMax = ft;
                if (_budgetMs > 0 && ft > _budgetMs * 1.25) w.OverBudget++;
                double g = FrameColumns.Num(f, _c.GpuBusy);
                if (!double.IsNaN(g)) { sumG += g; nG++; }
                double c = FrameColumns.Num(f, _c.CpuBusy);
                if (!double.IsNaN(c)) { sumC += c; nC++; }
            }
            if (w.Frames > 0) w.FtAvg = sumFt / w.Frames;
            if (nG > 0) w.GpuBusyAvg = sumG / nG;
            if (nC > 0) w.CpuBusyAvg = sumC / nC;
            TotalFrames += w.Frames;
            TotalOverBudget += w.OverBudget;
            return w;
        }
    }

    // ================================================================
    //  Analyzer side: load a whole PresentMon CSV, fast
    // ================================================================
    public sealed class FrameData
    {
        public string File;
        public string FtColumn, GpuBusyColumn, CpuBusyColumn;
        public string Application = "";
        public int ProcessId;
        public int SwapChains;
        public int Count;
        public bool HasQpc, HasTime, HasGpuBusy, HasCpuBusy, HasCpuWait, HasDisplay;
        public long[] Qpc;
        public double[] TimeS, Ft, GpuBusy, CpuBusy, CpuWait, DisplayChange;
        public bool[] Dropped;
        public string PresentMode = "";
        public int SyncInterval = -1;
        // SteamVR compositor frames (VrFrameLog). Every frame time is a whole
        // number of headset refreshes, so a frame that misses by 1 ms shows
        // up as a doubled interval - FrameAnalyzer judges those against the
        // budget, not against the doubled interval.
        public bool Vsynced, MatchedGame;
        public int[] Presents, Mispresented, CompDropped, Flags;
        public double[] TotalGpu, CompGpu, CompIdle;
        public int OtherSceneFrames;
    }

    public static class FrameLog
    {
        /// <summary>
        /// Load the dominant swap chain of the file. Games often present a
        /// second chain (a launcher overlay, a VR mirror); mixing them would
        /// interleave two unrelated frame cadences into one bogus series.
        /// </summary>
        public static FrameData Load(string path)
        {
            FrameData d = new FrameData();
            d.File = path;
            // Pass 1: find the dominant swap chain without keeping any rows -
            // an hour of 120 fps VR is ~430,000 lines, which as string[] rows
            // would cost hundreds of MB. Pass 2 parses only that chain.
            FrameColumns c = null;
            Dictionary<string, int> chainCount = new Dictionary<string, int>();
            foreach (string line in ReadLines(path))
            {
                if (c == null)
                {
                    if (line.IndexOf("Application", StringComparison.OrdinalIgnoreCase) >= 0) c = FrameColumns.Parse(line.TrimStart('\uFEFF'));
                    continue;
                }
                if (!c.Valid) break;
                string[] f = line.Split(',');
                if (f.Length <= c.Ft) continue;
                string key = FrameColumns.Str(f, c.Pid) + "|" + FrameColumns.Str(f, c.SwapChain);
                int n;
                chainCount.TryGetValue(key, out n);
                chainCount[key] = n + 1;
            }
            if (c == null || !c.Valid) return d;

            string best = null; int bestN = -1;
            foreach (KeyValuePair<string, int> kv in chainCount) if (kv.Value > bestN) { best = kv.Key; bestN = kv.Value; }
            d.SwapChains = chainCount.Count;
            d.FtColumn = c.FtName; d.GpuBusyColumn = c.GpuBusyName; d.CpuBusyColumn = c.CpuBusyName;
            d.HasQpc = c.Qpc >= 0;
            d.HasTime = c.TimeS >= 0 || c.TimeMs >= 0;
            d.HasGpuBusy = c.GpuBusy >= 0;
            d.HasCpuBusy = c.CpuBusy >= 0;
            d.HasCpuWait = c.CpuWait >= 0;
            d.HasDisplay = c.DisplayChange >= 0 || c.Dropped >= 0;

            List<long> qpc = new List<long>(bestN);
            List<double> t = new List<double>(bestN), ft = new List<double>(bestN), g = new List<double>(bestN);
            List<double> cb = new List<double>(bestN), cw = new List<double>(bestN), dc = new List<double>(bestN);
            List<bool> dr = new List<bool>(bestN);
            Dictionary<string, int> modes = new Dictionary<string, int>();
            bool header = true;
            foreach (string line in ReadLines(path))
            {
                if (header) { if (line.IndexOf("Application", StringComparison.OrdinalIgnoreCase) >= 0) header = false; continue; }
                string[] f = line.Split(',');
                if (f.Length <= c.Ft) continue;
                string key = FrameColumns.Str(f, c.Pid) + "|" + FrameColumns.Str(f, c.SwapChain);
                if (key != best) continue;
                double v = FrameColumns.Num(f, c.Ft);
                if (double.IsNaN(v) || v <= 0) continue;
                if (d.Application.Length == 0)
                {
                    d.Application = FrameColumns.Str(f, c.App);
                    int pid; int.TryParse(FrameColumns.Str(f, c.Pid), out pid); d.ProcessId = pid;
                    double si = FrameColumns.Num(f, c.SyncInterval);
                    if (!double.IsNaN(si)) d.SyncInterval = (int)si;
                }
                ft.Add(v);
                qpc.Add(FrameColumns.Long(f, c.Qpc));
                double ts = FrameColumns.Num(f, c.TimeS);
                if (double.IsNaN(ts)) { double ms = FrameColumns.Num(f, c.TimeMs); if (!double.IsNaN(ms)) ts = ms / 1000.0; }
                t.Add(ts);
                g.Add(FrameColumns.Num(f, c.GpuBusy));
                cb.Add(FrameColumns.Num(f, c.CpuBusy));
                cw.Add(FrameColumns.Num(f, c.CpuWait));
                double disp = FrameColumns.Num(f, c.DisplayChange);
                dc.Add(disp);
                bool dropped;
                if (c.Dropped >= 0) dropped = FrameColumns.Num(f, c.Dropped) == 1;
                else if (c.DisplayChange >= 0) dropped = double.IsNaN(disp) || disp <= 0;
                else dropped = false;
                dr.Add(dropped);
                string pm = FrameColumns.Str(f, c.PresentMode);
                if (pm.Length > 0) { int m; modes.TryGetValue(pm, out m); modes[pm] = m + 1; }
            }
            d.Count = ft.Count;
            d.Qpc = qpc.ToArray(); d.TimeS = t.ToArray(); d.Ft = ft.ToArray(); d.GpuBusy = g.ToArray();
            d.CpuBusy = cb.ToArray(); d.CpuWait = cw.ToArray(); d.DisplayChange = dc.ToArray(); d.Dropped = dr.ToArray();
            int bm = -1;
            foreach (KeyValuePair<string, int> kv in modes) if (kv.Value > bm) { bm = kv.Value; d.PresentMode = kv.Key; }
            return d;
        }

        static IEnumerable<string> ReadLines(string path)
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader sr = new StreamReader(fs, Encoding.UTF8, true, 1 << 16))
            {
                string line;
                while ((line = sr.ReadLine()) != null) if (line.Length > 0) yield return line;
            }
        }
    }

    // ================================================================
    //  SteamVR compositor frames  (vr-frames.csv)
    // ================================================================
    //  The kit's scripts\SteamVR-Timing.ps1 owns the OpenVR connection (a
    //  Background client: it never starts SteamVR, never takes the scene)
    //  and the 1 Hz vr_* columns. VrFrameWriter keeps every frame on top of
    //  that: the compositor remembers only its last 128 frames, so the
    //  logger hands over a GetFrameTimings buffer twice a second and only
    //  the frames not yet written are kept.
    //
    //  Offsets are the Windows x64 Compositor_FrameTiming from openvr.h -
    //  the ones the kit decodes, plus the pose / submit timestamps:
    //    4 frame index   8 presents   12 mispresented   16 dropped   20 flags
    //   24 system time (double)   32 pre-submit GPU   36 post-submit GPU
    //   40 total render GPU   44 compositor GPU   48 compositor CPU
    //   52 compositor idle   56 client frame interval   68 Submit time
    //   76 new poses ready   80 new frame ready (last Submit)   180 vsyncs to view
    public sealed class VrFrameWriter : IDisposable
    {
        public const string Header = "frame,t_s,interval_ms,app_gpu_ms,app_cpu_ms,total_gpu_ms,comp_gpu_ms,comp_cpu_ms,comp_idle_ms,submit_ms,presents,mispresented,dropped,reproj_flags,vsyncs_to_view,scene_pid";
        // Rejects garbage, not hitches: a 400 ms shader-compile frame is exactly
        // what this file is for. (The kit's 250 ms plausibility rule is for
        // proving the struct layout, which SteamVR-Timing.ps1 already does.)
        const double Plausible = 60000.0;
        readonly FileStream _fs;
        readonly double _qpcStartSeconds;
        long _last = -1;
        double _offset = double.NaN;     // session seconds = compositor system time + _offset
        public long Written, Missing, Rejected, Resets;
        public string TimeBase = "";
        public string Path;

        public VrFrameWriter(string path, double qpcStartSeconds)
        {
            Path = path;
            _qpcStartSeconds = qpcStartSeconds;
            _fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            Write(Header + "\r\n");
        }

        // Every cell is a number, so ASCII is the whole encoding (and there is no BOM).
        void Write(string text)
        {
            byte[] b = Encoding.ASCII.GetBytes(text);
            _fs.Write(b, 0, b.Length);
            _fs.Flush();
        }

        static float F(byte[] b, int o) { return BitConverter.ToSingle(b, o); }
        static string N(double v) { return (double.IsNaN(v) || double.IsInfinity(v)) ? "" : v.ToString("0.###", CultureInfo.InvariantCulture); }
        static bool Ok(double v) { return !double.IsNaN(v) && v >= 0 && v <= Plausible; }

        /// <summary>
        /// Append the frames in buf (count frames of `size` bytes) that are
        /// newer than the last one written. sessionNow and qpcNowSeconds are
        /// "now" on the logger's clock; scenePid is the compositor's scene app.
        /// The newest `holdBack` frames are left for the next read: the
        /// compositor is still presenting them, so their present count,
        /// reprojection flags and GPU times are not final yet. The last read
        /// of a session passes 0. Returns the number of frames written.
        /// </summary>
        public int Add(byte[] buf, int size, int count, double sessionNow, double qpcNowSeconds, int scenePid, int holdBack)
        {
            if (buf == null || size < 96 || count <= 0) return 0;
            count = Math.Min(count, buf.Length / size);
            List<int> order = new List<int>(count);
            List<long> idx = new List<long>(count);
            for (int i = 0; i < count; i++) { order.Add(i); idx.Add(BitConverter.ToUInt32(buf, i * size + 4)); }
            order.Sort(delegate(int a, int b) { return idx[a].CompareTo(idx[b]); });
            if (order.Count == 0) return 0;
            long newest = idx[order[order.Count - 1]];
            double newestTime = BitConverter.ToDouble(buf, order[order.Count - 1] * size + 24);
            if (_last >= 0 && newest + 1000 < _last) { _last = -1; _offset = double.NaN; Resets++; }   // SteamVR restarted
            if (_last >= 0 && newest <= _last) return 0;   // nothing new (and the newest frame may be stale)

            // Clock: the compositor's system time is QPC seconds on Windows. Check
            // that rather than assume it; otherwise anchor it to "now".
            if (newestTime > 0)
            {
                if (double.IsNaN(_offset))
                {
                    if (Math.Abs(newestTime - qpcNowSeconds) < 2.0) { _offset = -_qpcStartSeconds; TimeBase = "qpc"; }
                    else { _offset = sessionNow - newestTime; TimeBase = "anchored"; }
                }
                else if (Math.Abs(newestTime + _offset - sessionNow) > 2.0) { _offset = sessionNow - newestTime; TimeBase = "anchored"; }
            }

            int wrote = 0;
            StringBuilder sb = new StringBuilder(160 * order.Count);
            long upTo = newest - Math.Max(0, holdBack);
            foreach (int i in order)
            {
                long index = idx[i];
                if (_last >= 0 && index <= _last) continue;
                if (index > upTo) break;
                if (_last >= 0 && index > _last + 1) Missing += index - _last - 1;
                _last = index;
                int o = i * size;
                double sys = BitConverter.ToDouble(buf, o + 24);
                double pre = F(buf, o + 32), post = F(buf, o + 36), total = F(buf, o + 40), compG = F(buf, o + 44), compC = F(buf, o + 48);
                double idle = F(buf, o + 52), interval = F(buf, o + 56), submit = F(buf, o + 68);
                if (!(sys > 0 && sys < 1e12) || !Ok(pre) || !Ok(total) || !Ok(compG) || !Ok(compC) || !Ok(interval) || !Ok(submit)) { Rejected++; continue; }
                // 0 = the compositor ran without a scene app calling WaitGetPoses: not a frame of the game.
                if (interval <= 0) continue;
                double appCpu = double.NaN;
                double posesReady = F(buf, o + 76), frameReady = F(buf, o + 80);
                double d = frameReady - posesReady;
                if (!double.IsNaN(d) && d > 0 && d < Plausible) appCpu = d;
                double appGpu = pre + (Ok(post) ? post : 0);
                uint vsyncs = size >= 184 ? BitConverter.ToUInt32(buf, o + 180) : 0;
                sb.Append(index.ToString(CultureInfo.InvariantCulture)).Append(',')
                  .Append(N(double.IsNaN(_offset) ? double.NaN : sys + _offset)).Append(',')
                  .Append(N(interval)).Append(',').Append(N(appGpu)).Append(',').Append(N(appCpu)).Append(',')
                  .Append(N(total)).Append(',').Append(N(compG)).Append(',').Append(N(compC)).Append(',')
                  .Append(N(Ok(idle) ? idle : double.NaN)).Append(',').Append(N(submit)).Append(',')
                  .Append(BitConverter.ToUInt32(buf, o + 8).ToString(CultureInfo.InvariantCulture)).Append(',')
                  .Append(BitConverter.ToUInt32(buf, o + 12).ToString(CultureInfo.InvariantCulture)).Append(',')
                  .Append(BitConverter.ToUInt32(buf, o + 16).ToString(CultureInfo.InvariantCulture)).Append(',')
                  .Append(BitConverter.ToUInt32(buf, o + 20).ToString(CultureInfo.InvariantCulture)).Append(',')
                  .Append(vsyncs.ToString(CultureInfo.InvariantCulture)).Append(',')
                  .Append(scenePid.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
                wrote++;
            }
            if (wrote > 0) Write(sb.ToString());
            Written += wrote;
            return wrote;
        }

        public void Dispose() { try { _fs.Dispose(); } catch (Exception) { } }
    }

    /// <summary>SteamVR's own view of a session: what the compositor did with the frames.</summary>
    public sealed class VrStats
    {
        public int Frames, Reprojected, ReprojCpu, ReprojGpu, Motion, Repeated, Throttled, DroppedFrames;
        public long CompDropped, Mispresented;
        public double AppGpuP50 = double.NaN, AppGpuP90 = double.NaN, AppGpuP99 = double.NaN;
        public double AppCpuP50 = double.NaN, AppCpuP90 = double.NaN;
        public double TotalGpuP90 = double.NaN, CompGpuAvg = double.NaN, CompGpuP90 = double.NaN, CompIdleAvg = double.NaN;
    }

    public static class VrFrameLog
    {
        // Reprojection flags on the app-facing Compositor_FrameTiming (openvr.h).
        // 0x04 only says asynchronous reprojection is enabled, not that it happened.
        public const int FlagCpu = 0x01, FlagGpu = 0x02, FlagMotion = 0x08, FlagThrottle = 0xF00;

        /// <summary>
        /// Load vr-frames.csv. Only the game's frames are kept: the scene apps
        /// that match gamePids (every pid the game ran as - iRacing relaunches
        /// the sim per session), else the scene app with the most frames
        /// (SteamVR Home and the dashboard also render through the compositor).
        /// </summary>
        public static FrameData Load(string path, int[] gamePids)
        {
            FrameData d = new FrameData();
            d.File = path;
            d.Vsynced = true;
            d.FtColumn = "interval_ms"; d.GpuBusyColumn = "app_gpu_ms"; d.CpuBusyColumn = "app_cpu_ms";
            CsvTable t = CsvTable.Load(path);
            if (!t.Has("interval_ms")) return d;
            double[] ft = t.Num("interval_ms"), ts = t.Num("t_s"), pid = t.Num("scene_pid");
            Dictionary<int, int> perPid = new Dictionary<int, int>();
            for (int i = 0; i < ft.Length; i++)
            {
                if (double.IsNaN(ft[i]) || ft[i] <= 0) continue;
                int p = double.IsNaN(pid[i]) ? 0 : (int)pid[i];
                int n; perPid.TryGetValue(p, out n); perPid[p] = n + 1;
            }
            HashSet<int> keep = new HashSet<int>();
            int gameFrames = 0;
            if (gamePids != null)
                foreach (int g in gamePids)
                    if (g > 0 && perPid.ContainsKey(g)) { keep.Add(g); gameFrames += perPid[g]; }
            if (gameFrames < 20)
            {
                keep.Clear();
                int dom = -1, best = -1;
                foreach (KeyValuePair<int, int> kv in perPid) if (kv.Value > best) { best = kv.Value; dom = kv.Key; }
                if (dom >= 0) keep.Add(dom);
            }
            List<int> kept = new List<int>(keep);
            kept.Sort();
            d.ProcessId = kept.Count > 0 ? kept[0] : -1;
            d.MatchedGame = gameFrames >= 20;
            d.SwapChains = perPid.Count;
            List<string> names = new List<string>();
            foreach (int k in kept) names.Add(k.ToString(CultureInfo.InvariantCulture));
            d.Application = kept.Count > 0 ? "scene app pid " + string.Join(", ", names.ToArray()) : "";

            double[] gpu = t.Num("app_gpu_ms"), cpu = t.Num("app_cpu_ms"), total = t.Num("total_gpu_ms"), compG = t.Num("comp_gpu_ms"), idle = t.Num("comp_idle_ms");
            double[] pres = t.Num("presents"), mis = t.Num("mispresented"), drop = t.Num("dropped"), flags = t.Num("reproj_flags");
            List<int> rows = new List<int>(ft.Length);
            List<double> times = new List<double>(ft.Length);
            double lastT = double.NaN;
            for (int i = 0; i < ft.Length; i++)
            {
                if (double.IsNaN(ft[i]) || ft[i] <= 0) continue;
                int p = double.IsNaN(pid[i]) ? 0 : (int)pid[i];
                if (!keep.Contains(p)) { d.OtherSceneFrames++; continue; }
                if (double.IsNaN(ts[i])) continue;
                // Time must never run backwards (the analysis binary-searches it):
                // a clock re-anchor mid-session is clamped, not reordered.
                double tv = ts[i];
                if (!double.IsNaN(lastT) && tv < lastT) tv = lastT;
                lastT = tv;
                rows.Add(i); times.Add(tv);
            }
            int c = rows.Count;
            d.Count = c;
            d.Qpc = new long[c]; d.TimeS = new double[c]; d.Ft = new double[c]; d.GpuBusy = new double[c]; d.CpuBusy = new double[c];
            d.CpuWait = new double[c]; d.DisplayChange = new double[c]; d.Dropped = new bool[c];
            d.Presents = new int[c]; d.Mispresented = new int[c]; d.CompDropped = new int[c]; d.Flags = new int[c];
            d.TotalGpu = new double[c]; d.CompGpu = new double[c]; d.CompIdle = new double[c];
            bool anyCpu = false;
            for (int k = 0; k < c; k++)
            {
                int i = rows[k];
                d.TimeS[k] = times[k]; d.Ft[k] = ft[i]; d.GpuBusy[k] = gpu[i]; d.CpuBusy[k] = cpu[i];
                if (!double.IsNaN(cpu[i])) anyCpu = true;
                d.CpuWait[k] = double.NaN; d.DisplayChange[k] = double.NaN;
                d.Presents[k] = double.IsNaN(pres[i]) ? 1 : (int)pres[i];
                d.Mispresented[k] = double.IsNaN(mis[i]) ? 0 : (int)mis[i];
                d.CompDropped[k] = double.IsNaN(drop[i]) ? 0 : (int)drop[i];
                d.Flags[k] = double.IsNaN(flags[i]) ? 0 : (int)flags[i];
                d.Dropped[k] = d.CompDropped[k] > 0;
                d.TotalGpu[k] = total[i]; d.CompGpu[k] = compG[i]; d.CompIdle[k] = idle[i];
            }
            d.HasTime = c > 0; d.HasQpc = false; d.HasGpuBusy = c > 0; d.HasCpuBusy = anyCpu; d.HasCpuWait = false; d.HasDisplay = c > 0;
            d.PresentMode = "SteamVR compositor";
            return d;
        }

        /// <summary>SteamVR's counters over frames [start, Count), loading frames (over 1 s) excluded.</summary>
        public static VrStats Summarize(FrameData d, int start)
        {
            VrStats s = new VrStats();
            if (d == null || d.Presents == null) return s;
            List<double> g = new List<double>(), c = new List<double>(), tg = new List<double>(), cg = new List<double>(), idle = new List<double>();
            for (int i = Math.Max(0, start); i < d.Count; i++)
            {
                if (d.Ft[i] > 1000) continue;
                s.Frames++;
                int f = d.Flags[i];
                bool cpuR = (f & FlagCpu) != 0, gpuR = (f & FlagGpu) != 0, mot = (f & FlagMotion) != 0;
                if (cpuR) s.ReprojCpu++;
                if (gpuR) s.ReprojGpu++;
                if (mot) s.Motion++;
                if ((f & FlagThrottle) != 0) s.Throttled++;
                if (d.Presents[i] > 1) s.Repeated++;
                // The kit's rule (SteamVR-Timing.ps1): shown more than once, or a reprojection flag set.
                if (d.Presents[i] > 1 || cpuR || gpuR || mot) s.Reprojected++;
                s.Mispresented += d.Mispresented[i];
                s.CompDropped += d.CompDropped[i];
                if (d.CompDropped[i] > 0) s.DroppedFrames++;
                if (!double.IsNaN(d.GpuBusy[i])) g.Add(d.GpuBusy[i]);
                if (!double.IsNaN(d.CpuBusy[i])) c.Add(d.CpuBusy[i]);
                if (!double.IsNaN(d.TotalGpu[i])) tg.Add(d.TotalGpu[i]);
                if (!double.IsNaN(d.CompGpu[i])) cg.Add(d.CompGpu[i]);
                if (!double.IsNaN(d.CompIdle[i])) idle.Add(d.CompIdle[i]);
            }
            double[] gs = Stats.SortedFinite(g.ToArray()), cs = Stats.SortedFinite(c.ToArray()), ts = Stats.SortedFinite(tg.ToArray()), cgs = Stats.SortedFinite(cg.ToArray());
            s.AppGpuP50 = Stats.Percentile(gs, 50); s.AppGpuP90 = Stats.Percentile(gs, 90); s.AppGpuP99 = Stats.Percentile(gs, 99);
            s.AppCpuP50 = Stats.Percentile(cs, 50); s.AppCpuP90 = Stats.Percentile(cs, 90);
            s.TotalGpuP90 = Stats.Percentile(ts, 90);
            s.CompGpuAvg = Stats.Mean(cgs); s.CompGpuP90 = Stats.Percentile(cgs, 90);
            s.CompIdleAvg = Stats.Mean(idle.ToArray());
            return s;
        }
    }

    // ================================================================
    //  The logger's own CSVs (system.csv, events.csv)
    // ================================================================
    /// <summary>
    /// Small quote-aware CSV reader. Import-Csv on a six-hour log costs
    /// seconds and hundreds of MB of PSObjects; this keeps raw strings and
    /// converts a column to numbers only when asked.
    /// </summary>
    public sealed class CsvTable
    {
        public string[] Header = new string[0];
        public List<string[]> Rows = new List<string[]>();
        readonly Dictionary<string, int> _idx = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        public int Count { get { return Rows.Count; } }

        public static CsvTable Load(string path)
        {
            CsvTable t = new CsvTable();
            if (!File.Exists(path)) return t;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader sr = new StreamReader(fs, Encoding.UTF8, true, 1 << 16))
            {
                string line;
                bool first = true;
                while ((line = sr.ReadLine()) != null)
                {
                    if (line.Length == 0) continue;
                    string[] f = Split(line);
                    if (first)
                    {
                        if (f.Length > 0) f[0] = f[0].TrimStart('\uFEFF');
                        t.Header = f;
                        for (int i = 0; i < f.Length; i++) if (!t._idx.ContainsKey(f[i])) t._idx[f[i]] = i;
                        first = false;
                        continue;
                    }
                    t.Rows.Add(f);
                }
            }
            return t;
        }

        public static string[] Split(string line)
        {
            List<string> f = new List<string>();
            StringBuilder sb = new StringBuilder();
            bool q = false;
            for (int i = 0; i < line.Length; i++)
            {
                char ch = line[i];
                if (q)
                {
                    if (ch == '"')
                    {
                        if (i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; }
                        else q = false;
                    }
                    else sb.Append(ch);
                }
                else if (ch == '"') q = true;
                else if (ch == ',') { f.Add(sb.ToString()); sb.Length = 0; }
                else sb.Append(ch);
            }
            f.Add(sb.ToString());
            return f.ToArray();
        }

        public bool Has(string column) { return _idx.ContainsKey(column); }

        public double[] Num(string column)
        {
            double[] r = new double[Rows.Count];
            int i;
            if (!_idx.TryGetValue(column, out i)) { for (int k = 0; k < r.Length; k++) r[k] = double.NaN; return r; }
            for (int k = 0; k < r.Length; k++) r[k] = FrameColumns.Num(Rows[k], i);
            return r;
        }

        public string[] Str(string column)
        {
            string[] r = new string[Rows.Count];
            int i;
            if (!_idx.TryGetValue(column, out i)) { for (int k = 0; k < r.Length; k++) r[k] = ""; return r; }
            for (int k = 0; k < r.Length; k++) r[k] = i < Rows[k].Length ? Rows[k][i] : "";
            return r;
        }
    }

    // ================================================================
    //  Statistics
    // ================================================================
    public static class Stats
    {
        /// <summary>
        /// First frame of "real" play in a capture: the point after which
        /// the next ~3 s run near the capture's typical frame time. Loading
        /// screens and the first seconds of a session produce huge frame
        /// times that are not the stutter you are hunting.
        /// </summary>
        public static int SettleIndex(double[] ft, double minSeconds)
        {
            int n = ft.Length;
            if (n < 50) return 0;
            double[] s = SortedFinite(ft);
            double med = Percentile(s, 50);
            double elapsed = 0;
            int start = 0;
            // skip at least minSeconds of wall time
            while (start < n && elapsed < minSeconds * 1000.0) { elapsed += ft[start]; start++; }
            int window = Math.Max(20, (int)(3000.0 / Math.Max(1.0, med)));
            for (int i = start; i + window < n; i += Math.Max(1, window / 4))
            {
                double[] w = new double[window];
                Array.Copy(ft, i, w, 0, window);
                Array.Sort(w);
                if (w[window / 2] <= med * 1.5) return i;
            }
            return Math.Min(start, n - 1);
        }

        /// <summary>Finite values only, sorted ascending.</summary>
        public static double[] SortedFinite(double[] a)
        {
            List<double> l = new List<double>(a.Length);
            foreach (double v in a) if (!double.IsNaN(v) && !double.IsInfinity(v)) l.Add(v);
            l.Sort();
            return l.ToArray();
        }

        /// <summary>Linear-interpolated percentile (0-100) of an ascending array.</summary>
        public static double Percentile(double[] sorted, double p)
        {
            if (sorted == null || sorted.Length == 0) return double.NaN;
            if (sorted.Length == 1) return sorted[0];
            double rank = Math.Max(0, Math.Min(100, p)) / 100.0 * (sorted.Length - 1);
            int lo = (int)Math.Floor(rank);
            int hi = Math.Min(sorted.Length - 1, lo + 1);
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo);
        }

        public static double Mean(double[] a)
        {
            double s = 0; int n = 0;
            foreach (double v in a) if (!double.IsNaN(v) && !double.IsInfinity(v)) { s += v; n++; }
            return n > 0 ? s / n : double.NaN;
        }

        /// <summary>Count of values strictly above a threshold.</summary>
        public static int CountAbove(double[] a, double threshold)
        {
            int n = 0;
            foreach (double v in a) if (v > threshold) n++;
            return n;
        }

        /// <summary>
        /// Indices of frames that stand out from their neighbourhood: at least
        /// `ratio` times the rolling median of the surrounding `window` frames
        /// AND at least `minDeltaMs` slower in absolute terms. The absolute
        /// floor stops a 3 ms frame in a 1.2 ms menu being called a stutter;
        /// the ratio stops a steady 30 fps scene being called one long stutter.
        /// </summary>
        public static int[] Stutters(double[] ft, int window, double ratio, double minDeltaMs, double[] medianOut)
        {
            List<int> hits = new List<int>();
            int n = ft.Length;
            if (n == 0) return hits.ToArray();
            int half = Math.Max(2, window / 2);
            double[] buf = new double[half * 2 + 1];
            for (int i = 0; i < n; i++)
            {
                int a = Math.Max(0, i - half), b = Math.Min(n - 1, i + half);
                int m = 0;
                for (int j = a; j <= b; j++) if (j != i) buf[m++] = ft[j];
                double med = ft[i];
                if (m > 0)
                {
                    Array.Sort(buf, 0, m);
                    med = (m % 2 == 1) ? buf[m / 2] : (buf[m / 2 - 1] + buf[m / 2]) / 2.0;
                }
                if (medianOut != null && i < medianOut.Length) medianOut[i] = med;
                if (ft[i] >= med * ratio && ft[i] - med >= minDeltaMs) hits.Add(i);
            }
            return hits.ToArray();
        }

        public static double[] Pick(double[] a, int[] idx)
        {
            double[] r = new double[idx.Length];
            for (int i = 0; i < idx.Length; i++) r[i] = (idx[i] >= 0 && idx[i] < a.Length) ? a[idx[i]] : double.NaN;
            return r;
        }

        /// <summary>[n, mean, p50, p95, max, min] over the finite values.</summary>
        public static double[] Summary(double[] a)
        {
            double[] s = SortedFinite(a);
            if (s.Length == 0) return new double[] { 0, double.NaN, double.NaN, double.NaN, double.NaN, double.NaN };
            double sum = 0;
            foreach (double v in s) sum += v;
            return new double[] { s.Length, sum / s.Length, Percentile(s, 50), Percentile(s, 95), s[s.Length - 1], s[0] };
        }

        /// <summary>Share (0-1) of finite values that are >= threshold.</summary>
        public static double FractionAtLeast(double[] a, double threshold)
        {
            int n = 0, hit = 0;
            foreach (double v in a)
            {
                if (double.IsNaN(v) || double.IsInfinity(v)) continue;
                n++;
                if (v >= threshold) hit++;
            }
            return n > 0 ? (double)hit / n : double.NaN;
        }

        /// <summary>[n, mean, max, min] of v where t is within [from, to]. t must be ascending.</summary>
        public static double[] Window(double[] t, double[] v, double from, double to)
        {
            int lo = 0, hi = t.Length;
            while (lo < hi) { int mid = (lo + hi) / 2; if (t[mid] < from) lo = mid + 1; else hi = mid; }
            double sum = 0, max = double.NaN, min = double.NaN; int n = 0;
            for (int i = lo; i < t.Length && t[i] <= to; i++)
            {
                double x = v[i];
                if (double.IsNaN(x)) continue;
                n++; sum += x;
                if (double.IsNaN(max) || x > max) max = x;
                if (double.IsNaN(min) || x < min) min = x;
            }
            return new double[] { n, n > 0 ? sum / n : double.NaN, max, min };
        }

        /// <summary>PresentMon QPC ticks -> seconds since the session's own QPC start.</summary>
        public static double[] QpcToSeconds(long[] qpc, double qpcStart, double freq)
        {
            double[] r = new double[qpc.Length];
            for (int i = 0; i < qpc.Length; i++) r[i] = qpc[i] > 0 ? (qpc[i] - qpcStart) / freq : double.NaN;
            return r;
        }

        public static double[] AddOffset(double[] a, double offset)
        {
            double[] r = new double[a.Length];
            for (int i = 0; i < a.Length; i++) r[i] = a[i] + offset;
            return r;
        }

        /// <summary>Synthesise frame timestamps from the frame times themselves.</summary>
        public static double[] CumulativeSeconds(double[] ft, double start)
        {
            double[] r = new double[ft.Length];
            double t = start;
            for (int i = 0; i < ft.Length; i++) { r[i] = t; if (!double.IsNaN(ft[i])) t += ft[i] / 1000.0; }
            return r;
        }

        /// <summary>
        /// Bucket a per-frame series by time. Returns [bucketStart, avg, max, count]
        /// rows - the chart and the per-second join use this.
        /// </summary>
        public static double[][] Buckets(double[] t, double[] v, double width)
        {
            List<double[]> rows = new List<double[]>();
            if (t.Length == 0 || width <= 0) return rows.ToArray();
            double cur = double.NaN, sum = 0, max = double.NaN; int cnt = 0;
            for (int i = 0; i < t.Length; i++)
            {
                if (double.IsNaN(t[i]) || double.IsNaN(v[i])) continue;
                double b = Math.Floor(t[i] / width) * width;
                if (!double.IsNaN(cur) && b != cur)
                {
                    rows.Add(new double[] { cur, sum / cnt, max, cnt });
                    sum = 0; max = double.NaN; cnt = 0;
                }
                cur = b;
                sum += v[i]; cnt++;
                if (double.IsNaN(max) || v[i] > max) max = v[i];
            }
            if (cnt > 0) rows.Add(new double[] { cur, sum / cnt, max, cnt });
            return rows.ToArray();
        }
    }
    // ================================================================
    //  Whole-session frame analysis
    // ================================================================
    public sealed class StutterInfo
    {
        public double T, Ft, Median, GpuBusy = double.NaN, CpuBusy = double.NaN;
        public int Segment;
        public string Kind = "unknown";
    }

    public sealed class FrameAnalysis
    {
        public int Frames, ExcludedFrames, LongPauses, Segments;
        public double Seconds, FpsAvg = double.NaN;
        public double P50 = double.NaN, P90 = double.NaN, P95 = double.NaN, P99 = double.NaN, P999 = double.NaN, Max = double.NaN;
        public double Low1Fps = double.NaN, Low01Fps = double.NaN;
        public int StutterCount, MajorStutters, Missed, Dropped;
        public bool HasGpuBusy, HasCpuBusy;
        public double GpuBusyAvg = double.NaN, GpuBusyP90 = double.NaN, CpuBusyAvg = double.NaN, CpuBusyP90 = double.NaN;
        public int GpuBound, CpuBound, Capped, Classified;
        public int MissedGpuBound, MissedCpuSide;
        public int StutterGpu, StutterCpu, StutterStall;
        public List<StutterInfo> Stutters = new List<StutterInfo>();
        public double[] T = new double[0], Ft = new double[0], Gpu = new double[0], Cpu = new double[0];
    }

    public static class FrameAnalyzer
    {
        // A stutter: >= 2x the local median frame time AND >= 6 ms slower.
        // At 90 Hz VR one missed frame (11.1 -> 22.2 ms) qualifies; at 144 Hz
        // a doubled frame (6.9 -> 13.9 ms) just does; jitter of a few ms never does.
        public const double StutterRatio = 2.0;
        public const double StutterMinDeltaMs = 6.0;
        public const int StutterWindow = 61;
        public const int MaxStoredStutters = 5000;

        /// <summary>
        /// data[i] is one PresentMon capture, times[i] its frame timestamps in
        /// session seconds, starts[i] the first frame of real play (SettleIndex).
        /// Frames over 1 s are pauses or loads, counted but excluded.
        /// </summary>
        public static FrameAnalysis Analyze(FrameData[] data, double[][] times, int[] starts, double budgetMs)
        {
            FrameAnalysis a = new FrameAnalysis();
            List<double> T = new List<double>(), F = new List<double>(), G = new List<double>(), C = new List<double>();
            bool anyGpu = false, anyCpu = false, vsynced = false;
            for (int s = 0; s < data.Length; s++)
            {
                FrameData d = data[s];
                if (d == null || d.Count == 0) continue;
                a.Segments++;
                anyGpu |= d.HasGpuBusy;
                anyCpu |= d.HasCpuBusy;
                vsynced |= d.Vsynced;
                int st = Math.Max(0, Math.Min(d.Count, starts[s]));
                a.ExcludedFrames += st;
                List<double> segFt = new List<double>(), segT = new List<double>(), segG = new List<double>(), segC = new List<double>();
                for (int i = st; i < d.Count; i++)
                {
                    double ft = d.Ft[i];
                    if (ft > 1000) { a.LongPauses++; a.ExcludedFrames++; continue; }
                    segFt.Add(ft); segT.Add(times[s][i]); segG.Add(d.GpuBusy[i]); segC.Add(d.CpuBusy[i]);
                    if (d.Dropped[i]) a.Dropped++;
                }
                double[] sf = segFt.ToArray();
                double[] med = new double[sf.Length];
                int[] hits = Stats.Stutters(sf, StutterWindow, StutterRatio, StutterMinDeltaMs, med);
                foreach (int h in hits)
                {
                    a.StutterCount++;
                    StutterInfo si = new StutterInfo();
                    si.T = segT[h]; si.Ft = sf[h]; si.Median = med[h]; si.GpuBusy = segG[h]; si.CpuBusy = segC[h]; si.Segment = s;
                    if (si.Ft >= Math.Max(50.0, si.Median * 3.0)) a.MajorStutters++;
                    if (!double.IsNaN(si.GpuBusy))
                    {
                        double sref = Reference(si.Ft, budgetMs, d.Vsynced);
                        if (si.GpuBusy >= 0.8 * sref) { si.Kind = "gpu"; a.StutterGpu++; }
                        else if (!double.IsNaN(si.CpuBusy) && si.CpuBusy >= 0.7 * sref) { si.Kind = "cpu"; a.StutterCpu++; }
                        else { si.Kind = "stall"; a.StutterStall++; }
                    }
                    if (a.Stutters.Count < MaxStoredStutters) a.Stutters.Add(si);
                }
                T.AddRange(segT); F.AddRange(segFt); G.AddRange(segG); C.AddRange(segC);
            }
            a.HasGpuBusy = anyGpu; a.HasCpuBusy = anyCpu;
            a.T = T.ToArray(); a.Ft = F.ToArray(); a.Gpu = G.ToArray(); a.Cpu = C.ToArray();
            a.Frames = a.Ft.Length;
            if (a.Frames == 0) return a;

            double sum = 0;
            foreach (double v in a.Ft) sum += v;
            a.Seconds = sum / 1000.0;
            a.FpsAvg = a.Frames / a.Seconds;
            double[] sorted = Stats.SortedFinite(a.Ft);
            a.P50 = Stats.Percentile(sorted, 50); a.P90 = Stats.Percentile(sorted, 90); a.P95 = Stats.Percentile(sorted, 95);
            a.P99 = Stats.Percentile(sorted, 99); a.P999 = Stats.Percentile(sorted, 99.9); a.Max = sorted[sorted.Length - 1];
            a.Low1Fps = 1000.0 / a.P99; a.Low01Fps = 1000.0 / a.P999;
            if (budgetMs > 0) a.Missed = Stats.CountAbove(a.Ft, budgetMs * 1.25);

            if (anyGpu)
            {
                double[] g = Stats.SortedFinite(a.Gpu);
                if (g.Length > 0) { a.GpuBusyAvg = Stats.Mean(g); a.GpuBusyP90 = Stats.Percentile(g, 90); }
            }
            if (anyCpu)
            {
                double[] c = Stats.SortedFinite(a.Cpu);
                if (c.Length > 0) { a.CpuBusyAvg = Stats.Mean(c); a.CpuBusyP90 = Stats.Percentile(c, 90); }
            }
            // What held each frame back. GPU busy for ~all of the frame = GPU-bound.
            // Otherwise the GPU sat idle part of the frame: either the frame met
            // its target and the rest is headroom (capped), or the CPU side - game
            // thread, driver, sync - was late.
            for (int i = 0; i < a.Frames; i++)
            {
                double g = a.Gpu[i], ft = a.Ft[i];
                if (double.IsNaN(g) || ft <= 0) continue;
                a.Classified++;
                double c = a.Cpu[i];
                bool missed = budgetMs > 0 && ft > budgetMs * 1.25;
                double r = Reference(ft, budgetMs, vsynced);
                if (g >= 0.9 * r) { a.GpuBound++; if (missed) a.MissedGpuBound++; }
                else if (!double.IsNaN(c) && c >= 0.85 * r) { a.CpuBound++; if (missed) a.MissedCpuSide++; }
                else if (budgetMs > 0 && ft <= budgetMs * 1.15) a.Capped++;
                else { a.CpuBound++; if (missed) a.MissedCpuSide++; }
            }
            return a;
        }

        /// <summary>
        /// What "busy for the whole frame" is measured against. Normally the
        /// frame time. On a vsynced source (the SteamVR compositor) a frame
        /// that misses its refresh is held to the next one, so a GPU that took
        /// 12 ms at 90 Hz shows a 22.2 ms frame: against the frame time it
        /// would look idle half the frame; against the 11.1 ms budget it is
        /// what made the frame late.
        /// </summary>
        public static double Reference(double ft, double budgetMs, bool vsynced)
        {
            if (vsynced && budgetMs > 0 && ft > budgetMs) return budgetMs;
            return ft;
        }
    }
}

