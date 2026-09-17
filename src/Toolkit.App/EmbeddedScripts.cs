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
            "Toolkit.Network",
            "Toolkit.Users",
            "Toolkit.Support"
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

        private static System.Drawing.Icon _appIcon;

        /// <summary>
        /// Logo de la app (assets\logo.ico embebido) para las ventanas. Se carga una
        /// vez. Si el recurso faltara, devuelve null y la ventana usa el icono por
        /// defecto: el logo nunca debe impedir que el toolkit arranque.
        /// </summary>
        public static System.Drawing.Icon AppIcon
        {
            get
            {
                if (_appIcon != null) return _appIcon;
                try
                {
                    using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Assets/logo.ico"))
                    {
                        if (stream != null) _appIcon = new System.Drawing.Icon(stream);
                    }
                }
                catch { }
                return _appIcon;
            }
        }

        /// <summary>
        /// El logo de la app como bitmap del tamaño pedido (o el más cercano por
        /// arriba). Se lee el frame directamente del .ico porque Icon.ToBitmap()
        /// falla con los .ico cuyos frames van comprimidos en PNG (los nuestros).
        /// Null si no se pudo: el llamador no pinta logo.
        /// </summary>
        public static System.Drawing.Bitmap AppLogoBitmap(int size)
        {
            try
            {
                byte[] ico;
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Assets/logo.ico"))
                {
                    if (stream == null) return null;
                    using (var ms = new MemoryStream()) { stream.CopyTo(ms); ico = ms.ToArray(); }
                }
                int count = BitConverter.ToUInt16(ico, 4);
                int bestOff = -1, bestLen = 0, bestSize = -1;
                for (int i = 0; i < count; i++)
                {
                    int e = 6 + i * 16;
                    int w = ico[e] == 0 ? 256 : ico[e];
                    int len = BitConverter.ToInt32(ico, e + 8);
                    int off = BitConverter.ToInt32(ico, e + 12);
                    // El más pequeño que no sea menor que el pedido; si no hay ninguno, el mayor.
                    bool better;
                    if (bestOff < 0)        better = true;
                    else if (w >= size)     better = bestSize < size || w < bestSize;
                    else                    better = bestSize < size && w > bestSize;
                    if (better) { bestOff = off; bestLen = len; bestSize = w; }
                }
                if (bestOff < 0) return null;
                using (var ms = new MemoryStream(ico, bestOff, bestLen))
                    return new System.Drawing.Bitmap(System.Drawing.Image.FromStream(ms));
            }
            catch { return null; }
        }

        private static System.Drawing.Image _companyLogo;

        /// <summary>Logo de la empresa (assets\bpo-centers-logo.png) para la cabecera. Null si falta.</summary>
        public static System.Drawing.Image CompanyLogo
        {
            get
            {
                if (_companyLogo != null) return _companyLogo;
                try
                {
                    using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Assets/bpo-centers-logo.png"))
                    {
                        // Copia en memoria: Image.FromStream exige que el stream siga vivo.
                        if (stream != null) _companyLogo = new System.Drawing.Bitmap(System.Drawing.Image.FromStream(stream));
                    }
                }
                catch { }
                return _companyLogo;
            }
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
