using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;

namespace Toolkit.App
{
    public enum LogLevel { Info, Ok, Warn, Error, Debug }

    public class ScriptOutputEventArgs : EventArgs
    {
        public LogLevel Level { get; set; }
        public string Text { get; set; }
    }

    /// <summary>
    /// Ejecuta los scripts embebidos en un runspace EN PROCESO.
    ///
    /// Por que en proceso y no lanzando powershell.exe:
    ///   - No hay archivos .ps1 en disco que alguien pueda leer o modificar
    ///   - ExecutionPolicy no aplica al texto de script ejecutado en un runspace propio
    ///   - Se capturan los flujos de salida en vivo para pintarlos en la GUI
    ///   - Un unico proceso: mas facil de controlar con tiempo limite y de auditar
    /// </summary>
    public sealed class ScriptHost : IDisposable
    {
        private Runspace _runspace;
        private bool _modulesLoaded;

        /// <summary>Tiempo limite global de una ejecucion completa.</summary>
        public int TimeoutMinutes { get; set; } = 30;

        public event EventHandler<ScriptOutputEventArgs> Output;

        private void Emit(LogLevel level, string text)
        {
            var h = Output;
            if (h != null && !string.IsNullOrEmpty(text))
                h(this, new ScriptOutputEventArgs { Level = level, Text = text });
        }

        public void Open()
        {
            var iss = InitialSessionState.CreateDefault2();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            // ReuseThread, no UseCurrentThread: el runspace se crea en un hilo del
            // pool (Task.Run desde la GUI) y se invoca varias veces. UseCurrentThread
            // rompe el estado del apartment si el hilo de origen cambia.
            iss.ThreadOptions = PSThreadOptions.ReuseThread;

            _runspace = RunspaceFactory.CreateRunspace(iss);
            _runspace.Open();
        }

        /// <summary>
        /// Carga los modulos embebidos como modulos dinamicos en memoria.
        /// Equivale a Import-Module, pero sin que el .psm1 toque el disco.
        /// </summary>
        public void LoadModules()
        {
            if (_modulesLoaded) return;

            foreach (var name in EmbeddedScripts.ModuleOrder)
            {
                var body = EmbeddedScripts.ReadModule(name);

                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = _runspace;
                    ps.AddScript(
                        "param($Name, $Body) " +
                        "$m = New-Module -Name $Name -ScriptBlock ([scriptblock]::Create($Body)); " +
                        "Import-Module $m -Global -Force -DisableNameChecking")
                      .AddParameter("Name", name)
                      .AddParameter("Body", body);

                    ps.Invoke();

                    if (ps.HadErrors && ps.Streams.Error.Count > 0)
                    {
                        var sb = new StringBuilder();
                        foreach (var e in ps.Streams.Error)
                            sb.AppendLine(e.ToString());
                        throw new InvalidOperationException(
                            "Fallo al cargar el modulo embebido " + name + ":" + Environment.NewLine + sb);
                    }
                }
                Emit(LogLevel.Debug, "Modulo cargado: " + name);
            }

            _modulesLoaded = true;
        }

        /// <summary>
        /// Ejecuta Invoke-ToolkitRun.ps1 (embebido) y devuelve su codigo de salida.
        /// </summary>
        public int Run(RunOptions options)
        {
            if (_runspace == null) Open();
            LoadModules();

            using (var ps = PowerShell.Create())
            {
                ps.Runspace = _runspace;
                WireStreams(ps);

                ps.AddScript(EmbeddedScripts.ReadRunner());

                ps.AddParameter("Modules", options.Modules);
                ps.AddParameter("ConfigJson", options.CatalogJson);
                ps.AddParameter("Root", options.Root);

                if (options.Apps != null && options.Apps.Length > 0) ps.AddParameter("Apps", options.Apps);
                if (!string.IsNullOrWhiteSpace(options.SharePath))   ps.AddParameter("SharePath", options.SharePath);
                if (options.ReportOnly)              ps.AddParameter("ReportOnly", true);
                if (options.Silent)                  ps.AddParameter("Silent", true);
                if (options.NoLockDown)              ps.AddParameter("NoLockDown", true);
                if (options.IgnoreMaintenanceWindow) ps.AddParameter("IgnoreMaintenanceWindow", true);

                Collection<PSObject> results;
                try
                {
                    // Tiempo limite global. Sin esto, un instalador de terceros que
                    // se cuelga deja el proceso vivo para siempre: en 400 equipos eso
                    // es una tarea programada que nunca vuelve a ejecutarse.
                    var async = ps.BeginInvoke();
                    if (!async.AsyncWaitHandle.WaitOne(TimeSpan.FromMinutes(TimeoutMinutes)))
                    {
                        Emit(LogLevel.Error,
                            "Tiempo limite global de " + TimeoutMinutes + " min superado. Abortando.");
                        try { ps.Stop(); } catch { }
                        return 1;
                    }
                    results = ps.EndInvoke(async);
                }
                catch (Exception ex)
                {
                    Emit(LogLevel.Error, "Error ejecutando el orquestador: " + ex.Message);
                    return 1;
                }

                foreach (var r in results)
                {
                    if (r == null) continue;
                    var prop = r.Properties["ExitCode"];
                    if (prop != null && prop.Value != null)
                    {
                        int code;
                        if (int.TryParse(prop.Value.ToString(), out code)) return code;
                    }
                }

                return ps.HadErrors ? 1 : 0;
            }
        }

        /// <summary>
        /// Invoca un comando suelto de los modulos (lo usa la GUI para los
        /// diagnosticos rapidos que no pasan por el orquestador).
        /// </summary>
        public Collection<PSObject> Invoke(string script, IDictionary<string, object> parameters = null)
        {
            if (_runspace == null) Open();
            LoadModules();

            using (var ps = PowerShell.Create())
            {
                ps.Runspace = _runspace;
                WireStreams(ps);
                ps.AddScript(script);
                if (parameters != null)
                    foreach (var kv in parameters) ps.AddParameter(kv.Key, kv.Value);
                return ps.Invoke();
            }
        }

        /// <summary>
        /// Engancha los flujos de PowerShell para ver la salida en vivo.
        /// Write-Host de PS 5.1 va al flujo Information: de ahi sale todo el log.
        /// </summary>
        private void WireStreams(PowerShell ps)
        {
            ps.Streams.Information.DataAdded += (s, e) =>
            {
                var rec = ((PSDataCollection<InformationRecord>)s)[e.Index];
                Emit(ClassifyByContent(rec.MessageData?.ToString()), rec.MessageData?.ToString());
            };
            ps.Streams.Warning.DataAdded += (s, e) =>
            {
                var rec = ((PSDataCollection<WarningRecord>)s)[e.Index];
                Emit(LogLevel.Warn, rec.Message);
            };
            ps.Streams.Error.DataAdded += (s, e) =>
            {
                var rec = ((PSDataCollection<ErrorRecord>)s)[e.Index];
                Emit(LogLevel.Error, rec.ToString());
            };
            ps.Streams.Verbose.DataAdded += (s, e) =>
            {
                var rec = ((PSDataCollection<VerboseRecord>)s)[e.Index];
                Emit(LogLevel.Debug, rec.Message);
            };
        }

        // Los scripts ya etiquetan cada linea ("... [OK   ] ..."): se reaprovecha
        // esa etiqueta para colorear en la GUI sin duplicar la logica de niveles.
        private static LogLevel ClassifyByContent(string line)
        {
            if (string.IsNullOrEmpty(line)) return LogLevel.Info;
            if (line.Contains("[ERROR]")) return LogLevel.Error;
            if (line.Contains("[WARN ]")) return LogLevel.Warn;
            if (line.Contains("[OK   ]")) return LogLevel.Ok;
            if (line.Contains("[DEBUG]")) return LogLevel.Debug;
            return LogLevel.Info;
        }

        public void Dispose()
        {
            if (_runspace != null)
            {
                try { _runspace.Close(); } catch { }
                _runspace.Dispose();
                _runspace = null;
            }
        }
    }

    public sealed class RunOptions
    {
        public string[] Modules { get; set; } = { "location", "apps", "network", "users" };
        public string[] Apps { get; set; }
        public string CatalogJson { get; set; }
        public string SharePath { get; set; }
        public string Root { get; set; } = @"C:\ProgramData\Toolkit";
        public bool ReportOnly { get; set; }
        public bool Silent { get; set; }
        public bool NoLockDown { get; set; }
        public bool IgnoreMaintenanceWindow { get; set; }
    }
}
