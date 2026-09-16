using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

namespace Toolkit.App
{
    /// <summary>
    /// Convierte el exe en agente local auto-ejecutable (seccion 12 del PLAN).
    ///
    /// Es la pieza que hace viable el despliegue en 400 equipos sin GPO, Intune
    /// ni RMM: una sola pasada manual por equipo y, a partir de ahi, el agente
    /// reaplica configuracion y reporta solo. Los cambios posteriores se
    /// despliegan editando el share, no volviendo a tocar los equipos.
    /// </summary>
    internal static class AgentInstaller
    {
        public const string TaskName = "Toolkit Agent";
        private const int IntervalHours = 4;

        private static string InstallRoot => @"C:\ProgramData\Toolkit";
        private static string BinDir      => Path.Combine(InstallRoot, "bin");
        private static string TargetExe   => Path.Combine(BinDir, "Toolkit.exe");

        public static int Install(string sharePath, string ring)
        {
            Console.WriteLine("Instalando agente en " + BinDir + " ...");

            try
            {
                Directory.CreateDirectory(BinDir);
                Directory.CreateDirectory(Path.Combine(InstallRoot, "logs"));
                Directory.CreateDirectory(Path.Combine(InstallRoot, "reports"));

                // 1. Copiarse a si mismo
                var current = Assembly.GetExecutingAssembly().Location;
                if (!string.Equals(current, TargetExe, StringComparison.OrdinalIgnoreCase))
                {
                    File.Copy(current, TargetExe, true);
                    Console.WriteLine("  + Ejecutable copiado");
                }

                // 2. ACL: sin esto, un agente con admin local podria sustituir el exe
                //    por otro y la tarea lo ejecutaria como SYSTEM.
                HardenDirectory(BinDir);

                // 3. Configuracion del agente
                var config = "{\n" +
                             "  \"SharePath\": " + JsonString(sharePath) + ",\n" +
                             "  \"Ring\": " + JsonString(ring) + ",\n" +
                             "  \"InstalledAt\": " + JsonString(DateTime.Now.ToString("o")) + ",\n" +
                             "  \"InstalledBy\": " + JsonString(Environment.UserDomainName + "\\" + Environment.UserName) + ",\n" +
                             "  \"Version\": " + JsonString(Program.AppVersion()) + "\n" +
                             "}";
                File.WriteAllText(Path.Combine(InstallRoot, "agent.json"), config, new UTF8Encoding(false));

                // 4. Tarea programada
                if (!CreateScheduledTask(sharePath))
                    return Program.ExitGeneric;

                Console.WriteLine();
                Console.WriteLine("AGENTE INSTALADO");
                Console.WriteLine("  Ejecutable : " + TargetExe);
                Console.WriteLine("  Share      : " + (string.IsNullOrWhiteSpace(sharePath) ? "<modo autonomo>" : sharePath));
                Console.WriteLine("  Anillo     : " + ring);
                Console.WriteLine("  Frecuencia : al arrancar (+5 min) y cada " + IntervalHours + " h");
                Console.WriteLine();
                Console.WriteLine("  Prueba inmediata:  schtasks /Run /TN \"" + TaskName + "\"");
                Console.WriteLine("  Desinstalar:       Toolkit.exe /uninstall-agent");
                return Program.ExitOk;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("  x Fallo la instalacion del agente: " + ex.Message);
                return Program.ExitGeneric;
            }
        }

        public static int Uninstall()
        {
            var exit = Run("schtasks.exe", "/Delete /TN \"" + TaskName + "\" /F");
            Console.WriteLine(exit == 0 ? "Tarea eliminada." : "No habia tarea que eliminar.");

            try
            {
                if (Directory.Exists(BinDir))
                {
                    var deferred = 0;
                    foreach (var f in Directory.GetFiles(BinDir))
                    {
                        try
                        {
                            File.Delete(f);
                        }
                        catch (IOException)
                        {
                            // Caso normal: se esta desinstalando ejecutando el propio
                            // exe de BinDir, que esta bloqueado por estar en uso.
                            // Se marca para borrado en el siguiente arranque.
                            if (MoveFileEx(f, null, MoveFileDelayUntilReboot)) deferred++;
                        }
                        catch (UnauthorizedAccessException)
                        {
                            if (MoveFileEx(f, null, MoveFileDelayUntilReboot)) deferred++;
                        }
                    }
                    Console.WriteLine("Binarios eliminados de " + BinDir +
                        (deferred > 0 ? "  (" + deferred + " se borraran al reiniciar)" : ""));
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("No se pudieron borrar los binarios: " + ex.Message);
            }

            Console.WriteLine("Se CONSERVAN logs, reportes y rollback.json en " + InstallRoot + ".");
            Console.WriteLine("Para deshacer los cambios de registro: Toolkit.exe /rollback (ANTES de borrar).");
            return Program.ExitOk;
        }

        private static bool CreateScheduledTask(string sharePath)
        {
            var arguments = "/silent /all";
            if (!string.IsNullOrWhiteSpace(sharePath))
                arguments += " /share:\"" + sharePath + "\"";

            // Dos disparadores (arranque + repeticion) no se pueden definir con
            // la linea de comandos de schtasks: hace falta XML.
            var start = DateTime.Now.Date.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ss");
            var xml = $@"<?xml version=""1.0"" encoding=""UTF-16""?>
<Task version=""1.3"" xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task"">
  <RegistrationInfo>
    <Description>Toolkit call center: reaplica configuracion y reporta estado.</Description>
    <Author>Toolkit</Author>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT5M</Delay>
    </BootTrigger>
    <TimeTrigger>
      <StartBoundary>{start}</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT{IntervalHours}H</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id=""Author"">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT10M</Interval>
      <Count>2</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context=""Author"">
    <Exec>
      <Command>{TargetExe}</Command>
      <Arguments>{System.Security.SecurityElement.Escape(arguments)}</Arguments>
    </Exec>
  </Actions>
</Task>";

            var xmlPath = Path.Combine(Path.GetTempPath(), "toolkit-task.xml");
            // schtasks /XML exige UTF-16.
            File.WriteAllText(xmlPath, xml, Encoding.Unicode);

            try
            {
                var exit = Run("schtasks.exe", "/Create /TN \"" + TaskName + "\" /XML \"" + xmlPath + "\" /F");
                if (exit != 0)
                {
                    Console.Error.WriteLine("  x schtasks /Create devolvio " + exit);
                    return false;
                }
                Console.WriteLine("  + Tarea programada creada");
                return true;
            }
            finally
            {
                try { File.Delete(xmlPath); } catch { }
            }
        }

        private static void HardenDirectory(string path)
        {
            // icacls es mas fiable que manipular la ACL desde .NET cuando hay
            // que romper herencia y reescribir todo el descriptor.
            Run("icacls.exe", "\"" + path + "\" /inheritance:r");
            Run("icacls.exe", "\"" + path + "\" /grant \"*S-1-5-18:(OI)(CI)F\"");      // SYSTEM
            Run("icacls.exe", "\"" + path + "\" /grant \"*S-1-5-32-544:(OI)(CI)F\"");  // Administradores
            Run("icacls.exe", "\"" + path + "\" /grant \"*S-1-5-32-545:(OI)(CI)RX\""); // Usuarios: solo lectura
            Console.WriteLine("  + ACL aplicada (escritura solo SYSTEM/Administradores)");
        }

        private static int Run(string file, string args)
        {
            var psi = new ProcessStartInfo(file, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var p = Process.Start(psi))
            {
                p.StandardOutput.ReadToEnd();
                p.StandardError.ReadToEnd();
                p.WaitForExit();
                return p.ExitCode;
            }
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existing, string newName, int flags);
        private const int MoveFileDelayUntilReboot = 0x4;

        private static string JsonString(string value)
        {
            if (value == null) return "null";
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }
    }
}
