using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.ServiceProcess;
using System.Threading;

namespace CaddyGateway
{
    /// <summary>
    /// Windows Service wrapper for the native Caddy gateway and its seven
    /// loopback MCP bridges. All real work is done by the existing manual
    /// scripts so there is a single source of truth for startup and shutdown.
    /// </summary>
    public sealed class GatewayService : ServiceBase
    {
        private const int WatchdogIntervalSeconds = 60;

        private readonly string rootDir;
        private readonly string logPath;
        private readonly string startScript;
        private readonly string stopScript;
        private readonly ManualResetEvent stopRequested = new ManualResetEvent(false);
        private Thread worker;
        private Process activeScriptProcess;
        private readonly object processLock = new object();

        public GatewayService()
        {
            ServiceName = "CaddyGateway";
            CanStop = true;
            CanShutdown = true;
            CanPauseAndContinue = false;
            AutoLog = true;

            string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            DirectoryInfo parent = Directory.GetParent(exeDir);
            rootDir = parent != null ? parent.FullName : exeDir;
            logPath = Path.Combine(rootDir, "logs", "service.log");
            startScript = Path.Combine(rootDir, "Start-CaddyGateway.ps1");
            stopScript = Path.Combine(rootDir, "Stop-CaddyGateway.ps1");
        }

        protected override void OnStart(string[] args)
        {
            Log("Service starting. Root: " + rootDir);
            stopRequested.Reset();
            worker = new Thread(WorkerLoop);
            worker.IsBackground = true;
            worker.Name = "CaddyGatewayStartupWatchdog";
            worker.Start();
        }

        protected override void OnStop()
        {
            Log("Service stop requested.");
            stopRequested.Set();
            KillActiveScriptTree();
            RunScript(stopScript, "", 60);

            if (worker != null && worker.IsAlive)
            {
                if (!worker.Join(TimeSpan.FromSeconds(15)))
                {
                    Log("Startup/watchdog thread did not exit within 15 seconds.");
                }
            }
            Log("Service stopped.");
        }

        protected override void OnShutdown()
        {
            OnStop();
        }

        private void WorkerLoop()
        {
            try
            {
                int attempt = 0;
                while (!stopRequested.WaitOne(0))
                {
                    attempt++;
                    Log("Running startup script (attempt " + attempt + ").");
                    int exitCode = RunScript(startScript, "", 600);
                    if (exitCode == 0)
                    {
                        Log("Startup script completed successfully.");
                    }
                    else
                    {
                        Log("Startup script exited with code " + exitCode + ".");
                    }

                    while (!stopRequested.WaitOne(WatchdogIntervalSeconds * 1000))
                    {
                        if (IsGatewayHealthy())
                        {
                            continue;
                        }

                        Log("Gateway health check failed; running startup script again.");
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("Fatal watchdog error: " + ex.Message);
            }
            finally
            {
                Log("Startup/watchdog thread exited.");
            }
        }

        private bool IsGatewayHealthy()
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:8081/mcp/servers");
                request.Method = "GET";
                request.Timeout = 5000;
                request.ReadWriteTimeout = 5000;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    return response.StatusCode == HttpStatusCode.OK;
                }
            }
            catch
            {
                return false;
            }
        }

        private int RunScript(string script, string arguments, int timeoutSeconds)
        {
            if (!File.Exists(script))
            {
                Log("Script not found: " + script);
                return 1;
            }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershell))
            {
                powershell = "powershell.exe";
            }

            string args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"";
            if (!string.IsNullOrWhiteSpace(arguments))
            {
                args += " " + arguments;
            }

            ProcessStartInfo psi = new ProcessStartInfo(powershell, args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.WorkingDirectory = rootDir;

            int exitCode = 1;
            try
            {
                using (Process proc = new Process())
                {
                    proc.StartInfo = psi;
                    proc.OutputDataReceived += (sender, e) => { if (e.Data != null) Log("  " + e.Data); };
                    proc.ErrorDataReceived += (sender, e) => { if (e.Data != null) Log("  ERR " + e.Data); };

                    lock (processLock)
                    {
                        activeScriptProcess = proc;
                    }

                    if (!proc.Start())
                    {
                        Log("Could not start PowerShell for " + Path.GetFileName(script));
                        return 1;
                    }

                    proc.BeginOutputReadLine();
                    proc.BeginErrorReadLine();
                    if (!proc.WaitForExit(timeoutSeconds * 1000))
                    {
                        Log("Script timed out after " + timeoutSeconds + "s: " + Path.GetFileName(script));
                        KillProcessTree(proc.Id);
                        proc.WaitForExit(5000);
                    }
                    exitCode = proc.HasExited ? proc.ExitCode : 1;
                }
            }
            catch (Exception ex)
            {
                Log("Failed to run " + Path.GetFileName(script) + ": " + ex.Message);
            }
            finally
            {
                lock (processLock)
                {
                    activeScriptProcess = null;
                }
            }

            return exitCode;
        }

        private void KillActiveScriptTree()
        {
            Process proc;
            lock (processLock)
            {
                proc = activeScriptProcess;
            }
            if (proc != null && !proc.HasExited)
            {
                KillProcessTree(proc.Id);
            }
        }

        private static void KillProcessTree(int processId)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("taskkill.exe", "/PID " + processId + " /T /F");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                using (Process killer = Process.Start(psi))
                {
                    if (killer != null)
                    {
                        killer.WaitForExit(10000);
                    }
                }
            }
            catch (Exception ex)
            {
                LogStatic("Could not kill process tree " + processId + ": " + ex.Message);
            }
        }

        private void Log(string message)
        {
            LogStatic(message);
        }

        private static void LogStatic(string message)
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                DirectoryInfo parent = Directory.GetParent(exeDir);
                string root = parent != null ? parent.FullName : exeDir;
                string path = Path.Combine(root, "logs", "service.log");
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine);
            }
            catch
            {
                // Logging must never stop the service.
            }
        }

        public static void Main()
        {
            ServiceBase.Run(new GatewayService());
        }
    }
}
