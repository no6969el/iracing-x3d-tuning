// GamePerfLauncher.cs  -  GamePerf.exe
// ----------------------------------------------------------------
// The thing you double-click. A windowless .NET Framework program that
// runs GamePerf inside its own process, using the Windows PowerShell 5.1
// engine every Windows 10/11 PC already has - so there is no PowerShell
// window, no console flash, and Task Manager, the taskbar and the UAC
// prompt all say "GamePerf" with its icon.
//
//   GamePerf.exe                         the app (one instance; a second
//                                        launch brings the first forward)
//   GamePerf.exe --logger  <session>     the recorder, silent and windowless
//                                        (the app starts this; elevated when
//                                        per-frame timing needs it)
//   GamePerf.exe --analyze <session>     re-run the analysis, windowless
//   GamePerf.exe --grant-perflog <sid>   one-time, elevated: add an account to
//                                        "Performance Log Users" so per-frame
//                                        timing no longer needs an admin prompt
//
// The scripts it runs sit next to it (GamePerf.ps1, lib\). Built by
// launcher\Build-Launcher.ps1; tests\test-gameperf.ps1 checks that the
// committed GamePerf.exe was built from this exact source.
//
// C# 5 only: Build-Launcher.ps1 uses the .NET Framework compiler on Windows.

using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

[assembly: AssemblyTitle("GamePerf")]
[assembly: AssemblyDescription("Frame-time logger and AI analyst for any game, monitor or VR")]
[assembly: AssemblyCompany("iRacing X3D Tuning kit")]
[assembly: AssemblyProduct("GamePerf")]
[assembly: AssemblyCopyright("MIT licence")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("dev")]

namespace GamePerf.Launcher
{
    /// <summary>Runs a PowerShell script in this process on the Windows PowerShell 5.1 engine.</summary>
    public static class ScriptHost
    {
        /// <summary>Windows PowerShell 5.1's engine is System.Management.Automation 3.0.0.0, in the GAC of every Windows 10/11.</summary>
        public static Assembly LoadEngine()
        {
            try { return Assembly.Load("System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"); }
            catch (Exception) { }
            foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
                if (a.GetName().Name == "System.Management.Automation") return a;
            throw new FileNotFoundException("Windows PowerShell 5.1 was not found on this PC (System.Management.Automation 3.0).");
        }

        static object Get(object o, string name) { return o.GetType().GetProperty(name).GetValue(o, null); }
        static void Set(object o, string name, object v) { o.GetType().GetProperty(name).SetValue(o, v, null); }
        static object Call(object o, string name) { return NoArgs(o.GetType(), name).Invoke(o, null); }

        /// <summary>
        /// The parameterless, non-generic overload. Type.GetMethod(name, EmptyTypes)
        /// is ambiguous for PowerShell.Invoke, which also has Invoke&lt;T&gt;().
        /// </summary>
        static MethodInfo NoArgs(Type t, string name)
        {
            foreach (MethodInfo m in t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static))
                if (m.Name == name && !m.IsGenericMethodDefinition && m.GetParameters().Length == 0) return m;
            throw new MissingMethodException(t.FullName, name);
        }

        /// <summary>
        /// Run script text to completion on the calling thread (STA for WPF).
        /// Returns the script's output as strings; errors are appended to `errors`.
        /// Throws if the script throws a terminating error.
        /// </summary>
        public static string[] Run(string script, StringBuilder errors)
        {
            // What powershell.exe -ExecutionPolicy Bypass does: a process-scope
            // policy. The scripts are local files; nothing here lowers the
            // machine or user policy.
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");
            Assembly sma = LoadEngine();
            Type factory = sma.GetType("System.Management.Automation.Runspaces.RunspaceFactory", true);
            object rs = NoArgs(factory, "CreateRunspace").Invoke(null, null);
            try { Set(rs, "ApartmentState", Thread.CurrentThread.GetApartmentState()); } catch (Exception) { }
            Type opts = sma.GetType("System.Management.Automation.Runspaces.PSThreadOptions", true);
            Set(rs, "ThreadOptions", Enum.Parse(opts, "UseCurrentThread"));
            Call(rs, "Open");
            object ps = null;
            try
            {
                Type psType = sma.GetType("System.Management.Automation.PowerShell", true);
                ps = NoArgs(psType, "Create").Invoke(null, null);
                Set(ps, "Runspace", rs);
                psType.GetMethod("AddScript", new Type[] { typeof(string) }).Invoke(ps, new object[] { script });
                object results;
                try { results = NoArgs(psType, "Invoke").Invoke(ps, null); }
                catch (TargetInvocationException e) { throw e.InnerException ?? e; }
                ArrayList output = new ArrayList();
                foreach (object r in (IEnumerable)results) if (r != null) output.Add(r.ToString());
                if (errors != null)
                    foreach (object err in (IEnumerable)Get(Get(ps, "Streams"), "Error")) errors.AppendLine(err.ToString());
                return (string[])output.ToArray(typeof(string));
            }
            finally
            {
                IDisposable d = ps as IDisposable;
                if (d != null) d.Dispose();
                IDisposable r = rs as IDisposable;
                if (r != null) r.Dispose();
            }
        }

        /// <summary>A PowerShell single-quoted string literal.</summary>
        public static string Quote(string s) { return "'" + (s ?? "").Replace("'", "''") + "'"; }
    }

    static class Program
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr h, string text, string caption, uint type);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string cls, string title);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);

        static string Dir { get { return AppDomain.CurrentDomain.BaseDirectory; } }

        static void Log(string text)
        {
            try
            {
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GamePerf");
                Directory.CreateDirectory(d);
                string f = Path.Combine(d, "launcher.log");
                if (File.Exists(f) && new FileInfo(f).Length > 262144) File.Delete(f);
                File.AppendAllText(f, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + Environment.NewLine);
            }
            catch (Exception) { }
        }

        static void Fail(string text)
        {
            Log(text);
            MessageBoxW(IntPtr.Zero, text, "GamePerf", 0x10);   // MB_ICONERROR
        }

        static string Script(string relative)
        {
            string p = Path.Combine(Dir, relative);
            if (!File.Exists(p)) throw new FileNotFoundException("GamePerf is missing " + relative + ". Keep GamePerf.exe in the GamePerf folder, next to GamePerf.ps1 and the lib folder.");
            return p;
        }

        static string SessionArg(string[] args)
        {
            if (args.Length < 2 || !Directory.Exists(args[1])) throw new ArgumentException("No session folder given, or it does not exist.");
            return Path.GetFullPath(args[1]);
        }

        [STAThread]
        static int Main(string[] args)
        {
            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "";
            Environment.SetEnvironmentVariable("GAMEPERF_LAUNCHER", Assembly.GetExecutingAssembly().Location);
            StringBuilder errors = new StringBuilder();
            try
            {
                if (mode == "--logger")
                {
                    ScriptHost.Run("& " + ScriptHost.Quote(Script(@"lib\GamePerf-Logger.ps1")) + " -SessionDir " + ScriptHost.Quote(SessionArg(args)) + " -Quiet", errors);
                    if (errors.Length > 0) Log("logger: " + errors);
                    return 0;
                }
                if (mode == "--analyze")
                {
                    ScriptHost.Run("& " + ScriptHost.Quote(Script(@"lib\GamePerf-Analyze.ps1")) + " -SessionDir " + ScriptHost.Quote(SessionArg(args)) + " -Quiet", errors);
                    if (errors.Length > 0) { Log("analyze: " + errors); return 1; }
                    return 0;
                }
                if (mode == "--grant-perflog")
                {
                    if (args.Length < 2 || !Regex.IsMatch(args[1], @"^S-1-[0-9]+(-[0-9]+)+$")) throw new ArgumentException("Expected an account SID.");
                    string[] r = ScriptHost.Run(GrantScript(args[1]), errors);
                    string result = r.Length > 0 ? r[r.Length - 1] : "";
                    Log("grant-perflog: " + result + " " + errors);
                    return result == "added" ? 0 : result == "member" ? 2 : 1;
                }

                // ---- the app ---------------------------------------------
                bool first;
                using (Mutex single = new Mutex(true, @"Local\GamePerf.App", out first))
                {
                    if (!first)
                    {
                        IntPtr w = FindWindowW(null, "GamePerf");
                        if (w != IntPtr.Zero) { ShowWindow(w, 9); SetForegroundWindow(w); }   // SW_RESTORE
                        return 0;
                    }
                    try { SetCurrentProcessExplicitAppUserModelID("GamePerf.App"); } catch (Exception) { }
                    ScriptHost.Run("& " + ScriptHost.Quote(Script("GamePerf.ps1")), errors);
                    if (errors.Length > 0) Log("app: " + errors);
                    return 0;
                }
            }
            catch (Exception e)
            {
                string msg = e.Message;
                if (mode == "" || mode == "--grant-perflog") Fail("GamePerf could not start.\n\n" + msg);
                else Log(mode + ": " + msg);
                return 1;
            }
        }

        /// <summary>
        /// Add an account to Performance Log Users (S-1-5-32-559, a name that is
        /// localised, so always by SID). Prints "added", "member" or "failed".
        /// </summary>
        static string GrantScript(string sid)
        {
            return
                "$ErrorActionPreference = 'Stop'\n" +
                "$sid = [Security.Principal.SecurityIdentifier]" + ScriptHost.Quote(sid) + "\n" +
                "$grp = [Security.Principal.SecurityIdentifier]'S-1-5-32-559'\n" +
                "try {\n" +
                "  $g = Get-LocalGroup -SID $grp\n" +
                "  if (@(Get-LocalGroupMember -Group $g | Where-Object { $_.SID -eq $sid }).Count) { 'member'; return }\n" +
                "  Add-LocalGroupMember -Group $g -Member $sid\n" +
                "  'added'\n" +
                "} catch {\n" +
                "  try {\n" +
                "    $name = $grp.Translate([Security.Principal.NTAccount]).Value.Split('\\')[-1]\n" +
                "    $de = [ADSI](\"WinNT://./\" + $name + \",group\")\n" +
                "    $de.Add(\"WinNT://\" + $sid.Value)\n" +
                "    'added'\n" +
                "  } catch { if (\"$_\" -match 'already a member') { 'member' } else { 'failed'; \"$_\" } }\n" +
                "}\n";
        }
    }
}
