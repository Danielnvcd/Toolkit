using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows.Forms;

namespace Toolkit.App
{
    internal static class Program
    {
        // Codigos de salida (seccion 9 del PLAN). Los consume cualquier RMM,
        // GPO o tarea programada para medir cobertura sin entrar equipo por equipo.
        public const int ExitOk            = 0;
        public const int ExitGeneric       = 1;
        public const int ExitNotElevated   = 5;
        public const int ExitRebootNeeded  = 3010;

        [DllImport("kernel32.dll")] private static extern bool AttachConsole(int pid);
        [DllImport("kernel32.dll")] private static extern bool AllocConsole();
        private const int AttachParentProcess = -1;

        [STAThread]
        private static int Main(string[] rawArgs)
        {
            var args = CommandLine.Parse(rawArgs);

            if (args.ShowHelp)
            {
                EnsureConsole();
                CommandLine.PrintUsage();
                return ExitOk;
            }

            // --- Modo GUI: sin argumentos, doble clic del tecnico en sitio ---
            if (args.IsGuiMode)
            {
                if (!IsElevated())
                {
                    // El manifiesto pide elevacion, asi que esto solo ocurre en
                    // escenarios raros (UAC deshabilitado por politica).
                    MessageBox.Show(
                        "El toolkit requiere privilegios de administrador.",
                        "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return ExitNotElevated;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm(args));
                return ExitOk;
            }

            // --- Modo consola ---
            EnsureConsole();

            if (!IsElevated())
            {
                Console.Error.WriteLine("ERROR: se requieren privilegios de administrador.");
                return ExitNotElevated;
            }

            try
            {
                if (args.InstallAgent)   return AgentInstaller.Install(args.SharePath, args.Ring);
                if (args.UninstallAgent) return AgentInstaller.Uninstall();
                if (args.Rollback)       return RunRollback(args);

                return RunModules(args);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("ERROR NO CONTROLADO: " + ex.Message);
                return ExitGeneric;
            }
        }

        private static int RunModules(CommandLineArgs args)
        {
            string origin;
            var catalog = EmbeddedScripts.ReadCatalog(args.ConfigPath, args.SharePath, out origin);

            using (var host = new ScriptHost())
            {
                host.Output += (s, e) => WriteColored(e.Level, e.Text);
                host.Open();

                Console.WriteLine("Toolkit v" + AppVersion() + "  |  catalogo: " + origin);

                var options = new RunOptions
                {
                    Modules                 = args.Modules.ToArray(),
                    Apps                    = args.Apps.ToArray(),
                    CatalogJson             = catalog,
                    SharePath               = args.SharePath,
                    Root                    = args.Root,
                    ReportOnly              = args.ReportOnly,
                    Silent                  = args.Silent,
                    NoLockDown              = args.NoLockDown,
                    NoBrowsers              = args.NoBrowsers,
                    CheckIn                 = args.CheckIn,
                    IgnoreMaintenanceWindow = args.Force
                };

                return host.Run(options);
            }
        }

        private static int RunRollback(CommandLineArgs args)
        {
            using (var host = new ScriptHost())
            {
                host.Output += (s, e) => WriteColored(e.Level, e.Text);
                host.Open();
                host.Invoke(
                    "param($Root) Initialize-Toolkit -Root $Root; Invoke-ToolkitRollback",
                    new Dictionary<string, object> { { "Root", args.Root } });
                return ExitOk;
            }
        }

        private static void WriteColored(LogLevel level, string text)
        {
            var previous = Console.ForegroundColor;
            switch (level)
            {
                case LogLevel.Ok:    Console.ForegroundColor = ConsoleColor.Green;    break;
                case LogLevel.Warn:  Console.ForegroundColor = ConsoleColor.Yellow;   break;
                case LogLevel.Error: Console.ForegroundColor = ConsoleColor.Red;      break;
                case LogLevel.Debug: Console.ForegroundColor = ConsoleColor.DarkGray; break;
            }
            Console.WriteLine(text);
            Console.ForegroundColor = previous;
        }

        private static void EnsureConsole()
        {
            // El exe es WinExe (sin consola propia) para que el modo GUI no
            // muestre una ventana negra. En CLI se engancha a la consola del padre.
            if (!AttachConsole(AttachParentProcess)) AllocConsole();
        }

        public static bool IsElevated()
        {
            try
            {
                using (var identity = WindowsIdentity.GetCurrent())
                {
                    return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                }
            }
            catch { return false; }
        }

        public static string AppVersion()
        {
            return System.Reflection.Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
        }

        // Identidad de la app. La fuente unica es el .csproj (Authors/Company/Copyright/
        // Description): asi lo que ve el Explorador en Propiedades > Detalles y lo que
        // ve el usuario en Acerca de es siempre lo mismo.
        public const string AppName = "Toolkit BPO";

        public static string AppAuthor    => AssemblyAttr<System.Reflection.AssemblyCompanyAttribute>(a => a.Company)     ?? "danielnvcd";
        public static string AppCopyright => AssemblyAttr<System.Reflection.AssemblyCopyrightAttribute>(a => a.Copyright) ?? "";
        public static string AppDescription => AssemblyAttr<System.Reflection.AssemblyDescriptionAttribute>(a => a.Description) ?? "";

        /// <summary>Fecha del ejecutable (el build es determinista, asi que se usa la del archivo).</summary>
        public static string AppBuildDate()
        {
            try { return System.IO.File.GetLastWriteTime(Application.ExecutablePath).ToString("yyyy-MM-dd"); }
            catch { return "?"; }
        }

        private static string AssemblyAttr<T>(Func<T, string> pick) where T : Attribute
        {
            try
            {
                var a = (T)Attribute.GetCustomAttribute(System.Reflection.Assembly.GetExecutingAssembly(), typeof(T));
                return a == null ? null : pick(a);
            }
            catch { return null; }
        }
    }
}
