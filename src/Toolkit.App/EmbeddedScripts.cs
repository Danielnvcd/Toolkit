using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

namespace Toolkit.App
{
    /// <summary>
    /// Acceso a los scripts embebidos en el propio ejecutable.
    ///
    /// Los .psm1 y el catalogo viven DENTRO del exe como recursos. Nunca se
    /// escriben en disco: eso evita que alguien los edite en un equipo y la
    /// flota diverja, y elimina los problemas de ExecutionPolicy y de
    /// antivirus bloqueando scripts sueltos.
    /// </summary>
    internal static class EmbeddedScripts
    {
        // El orden importa: Core define Write-Log/Set-RegValue/Add-Result,
        // de los que dependen los demas modulos.
        public static readonly string[] ModuleOrder =
        {
            "Toolkit.Core",
            "Toolkit.Location",
            "Toolkit.Apps",
            "Toolkit.Network"
        };

        private const string Prefix = "Scripts/";

        public static string Read(string name)
        {
            var asm = Assembly.GetExecutingAssembly();
            var resourceName = Prefix + name;

            using (var stream = asm.GetManifestResourceStream(resourceName))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException(
                        "Recurso embebido no encontrado: " + resourceName +
                        ". Recursos disponibles: " + string.Join(", ", asm.GetManifestResourceNames()));
                }
                using (var reader = new StreamReader(stream))
                {
                    return reader.ReadToEnd();
                }
            }
        }

        public static string ReadModule(string moduleName)
        {
            return Read(moduleName + ".psm1");
        }

        public static string ReadRunner()
        {
            return Read("Invoke-ToolkitRun.ps1");
        }

        /// <summary>
        /// Catalogo de configuracion. Prioridad:
        ///   1. Ruta explicita (/config:...)
        ///   2. catalog.json junto al exe (permite ajustar sin recompilar)
        ///   3. catalog.json del share
        ///   4. El catalogo embebido (siempre funciona, incluso sin red)
        /// </summary>
        public static string ReadCatalog(string explicitPath, string sharePath, out string origin)
        {
            var candidates = new List<KeyValuePair<string, string>>();

            if (!string.IsNullOrWhiteSpace(explicitPath))
                candidates.Add(new KeyValuePair<string, string>("parametro /config", explicitPath));

            var beside = Path.Combine(
                Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) ?? ".",
                "catalog.json");
            candidates.Add(new KeyValuePair<string, string>("junto al exe", beside));

            if (!string.IsNullOrWhiteSpace(sharePath))
                candidates.Add(new KeyValuePair<string, string>("share", Path.Combine(sharePath, "catalog.json")));

            foreach (var c in candidates)
            {
                try
                {
                    if (File.Exists(c.Value))
                    {
                        origin = c.Key + " (" + c.Value + ")";
                        return File.ReadAllText(c.Value);
                    }
                }
                catch
                {
                    // Un share caido no puede tumbar el arranque: se sigue con el siguiente.
                }
            }

            origin = "embebido en el exe";
            return Read("catalog.json");
        }
    }
}
