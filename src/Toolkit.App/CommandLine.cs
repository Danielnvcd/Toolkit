using System;
using System.Collections.Generic;
using System.Linq;

namespace Toolkit.App
{
    public sealed class CommandLineArgs
    {
        public bool IsGuiMode { get; set; }
        public bool Silent { get; set; }
        public bool ReportOnly { get; set; }
        public bool Rollback { get; set; }
        public bool InstallAgent { get; set; }
        public bool UninstallAgent { get; set; }
        public bool NoLockDown { get; set; }
        public bool Force { get; set; }
        public bool ShowHelp { get; set; }

        public List<string> Modules { get; set; } = new List<string>();
        public List<string> Apps { get; set; } = new List<string>();

        public string SharePath { get; set; }
        public string ConfigPath { get; set; }
        public string Ring { get; set; } = "default";
        public string Root { get; set; } = @"C:\ProgramData\Toolkit";
    }

    internal static class CommandLine
    {
        private static readonly string[] ValidModules = { "location", "apps", "network", "users" };

        public static CommandLineArgs Parse(string[] argv)
        {
            var a = new CommandLineArgs();

            if (argv == null || argv.Length == 0)
            {
                a.IsGuiMode = true;
                return a;
            }

            foreach (var raw in argv)
            {
                var arg = raw.TrimStart('-', '/');
                var value = "";
                var sep = arg.IndexOfAny(new[] { ':', '=' });
                if (sep >= 0)
                {
                    value = arg.Substring(sep + 1).Trim('"');
                    arg = arg.Substring(0, sep);
                }

                switch (arg.ToLowerInvariant())
                {
                    case "silent": case "quiet": case "s":
                        a.Silent = true; break;

                    case "all":
                        a.Modules = ValidModules.ToList(); break;

                    case "modules": case "m":
                        a.Modules.AddRange(SplitList(value).Where(v => ValidModules.Contains(v)));
                        break;

                    case "apps":
                        a.Apps.AddRange(SplitList(value));
                        if (!a.Modules.Contains("apps")) a.Modules.Add("apps");
                        break;

                    case "report": case "audit":
                        a.ReportOnly = true;
                        if (a.Modules.Count == 0) a.Modules = ValidModules.ToList();
                        break;

                    case "rollback":        a.Rollback = true; break;
                    case "install-agent":   a.InstallAgent = true; break;
                    case "uninstall-agent": a.UninstallAgent = true; break;
                    case "nolockdown":      a.NoLockDown = true; break;
                    case "force":           a.Force = true; break;

                    case "share":  a.SharePath = value; break;
                    case "config": a.ConfigPath = value; break;
                    case "ring":   a.Ring = value; break;
                    case "root":   a.Root = value; break;

                    case "?": case "h": case "help":
                        a.ShowHelp = true; break;

                    default:
                        Console.Error.WriteLine("Argumento desconocido: " + raw);
                        a.ShowHelp = true;
                        break;
                }
            }

            // /silent sin modulos no haria nada util: se asume el conjunto completo.
            if (a.Silent && a.Modules.Count == 0 && !a.Rollback && !a.InstallAgent && !a.UninstallAgent)
                a.Modules = ValidModules.ToList();

            return a;
        }

        private static IEnumerable<string> SplitList(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return Enumerable.Empty<string>();
            return value.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                        .Select(v => v.Trim().ToLowerInvariant())
                        .Where(v => v.Length > 0);
        }

        public static void PrintUsage()
        {
            Console.WriteLine(@"
TOOLKIT CALL CENTER  v" + Program.AppVersion() + @"
Un solo ejecutable. Los scripts van dentro.

  Toolkit.exe                          Interfaz grafica (tecnico en sitio)
  Toolkit.exe /silent /all             Desatendido: aplica todo
  Toolkit.exe /report                  Auditoria: evalua SIN modificar nada
  Toolkit.exe /silent /modules:location,network
  Toolkit.exe /silent /apps:netextender,goto
  Toolkit.exe /rollback                Revierte los cambios de registro
  Toolkit.exe /install-agent /share:\\SRV-FILE\Toolkit$ /ring:1-piloto
  Toolkit.exe /uninstall-agent

OPCIONES
  /modules:<lista>   location | apps | network | users   (separadas por coma)
                     'users' solo inventaria las cuentas locales; las acciones
                     (contrasena, eliminar, crear) estan en la interfaz grafica
  /apps:<lista>      ids concretos del catalogo
  /share:<ruta>      share UNC para reportes, catalogo y paquetes
  /config:<ruta>     catalog.json alternativo (por defecto: el embebido)
  /ring:<nombre>     anillo de despliegue del agente
  /root:<ruta>       carpeta de datos (por defecto C:\ProgramData\Toolkit)
  /nolockdown        NO bloquea el conmutador de ubicacion al usuario
  /force             ignora la ventana de mantenimiento
  /silent            sin interaccion ni salida decorada

CODIGOS DE SALIDA
  0     correcto            1001  fallo modulo ubicacion
  3010  requiere reinicio   1002  fallo modulo aplicaciones
  5     sin privilegios     1003  red en estado critico
  1     fallo generico
");
        }
    }
}
