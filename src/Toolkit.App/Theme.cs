using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Sistema visual único de la aplicación: paleta, fuentes, iconos y fábrica de
    /// controles. Todo lo que se ve pasa por aquí, para que las tres ventanas
    /// (principal, Acerca de, diálogos) se vean como una sola aplicación.
    ///
    /// Los iconos son glifos de "Segoe MDL2 Assets" (viene con Windows 10/11)
    /// pintados a bitmap: no hace falta embeber ningún PNG y escalan con el DPI.
    /// </summary>
    internal static class Theme
    {
        // --- Paleta -----------------------------------------------------------
        public static readonly Color Window     = Color.FromArgb(243, 243, 243);
        public static readonly Color Surface    = Color.White;
        public static readonly Color Border     = Color.FromArgb(218, 218, 218);
        public static readonly Color BorderSoft = Color.FromArgb(232, 232, 232);
        public static readonly Color Text       = Color.FromArgb(31, 41, 55);
        public static readonly Color TextMuted  = Color.FromArgb(107, 114, 128);
        public static readonly Color Accent     = Color.FromArgb(15, 108, 189);
        public static readonly Color AccentDark = Color.FromArgb(10, 84, 150);
        public static readonly Color AccentSoft = Color.FromArgb(232, 241, 250);
        public static readonly Color Ok         = Color.FromArgb(16, 124, 16);
        public static readonly Color Warn       = Color.FromArgb(157, 93, 0);
        public static readonly Color WarnSoft   = Color.FromArgb(255, 244, 229);
        public static readonly Color Danger     = Color.FromArgb(196, 43, 28);
        public static readonly Color DangerSoft = Color.FromArgb(253, 236, 234);
        public static readonly Color Hover      = Color.FromArgb(236, 236, 236);

        // Log (panel oscuro): colores apagados para que no chillen sobre el negro.
        public static readonly Color LogBack  = Color.FromArgb(30, 30, 32);
        public static readonly Color LogText  = Color.FromArgb(214, 214, 214);
        public static readonly Color LogOk    = Color.FromArgb(137, 209, 133);
        public static readonly Color LogWarn  = Color.FromArgb(230, 196, 110);
        public static readonly Color LogError = Color.FromArgb(240, 128, 122);
        public static readonly Color LogDebug = Color.FromArgb(128, 132, 140);

        // --- Fuentes ----------------------------------------------------------
        public static readonly Font Body      = new Font("Segoe UI", 9.5F);
        public static readonly Font BodyBold  = new Font("Segoe UI", 9.5F, FontStyle.Bold);
        public static readonly Font Small     = new Font("Segoe UI", 8.75F);
        public static readonly Font Title     = new Font("Segoe UI", 12F, FontStyle.Bold);
        public static readonly Font Heading   = new Font("Segoe UI", 15F, FontStyle.Bold);
        public static readonly Font Section   = new Font("Segoe UI", 9.5F, FontStyle.Bold);
        public static readonly Font Mono      = new Font("Consolas", 9.5F);
        public static readonly Font Icons     = new Font("Segoe MDL2 Assets", 12F);

        // --- Glifos Segoe MDL2 Assets ------------------------------------------
        public const string GlyphLocation  = "";   // MapPin
        public const string GlyphApps      = "";   // AllApps
        public const string GlyphNetwork   = "";   // NetworkTower
        public const string GlyphSupport   = "";   // Repair
        public const string GlyphUsers     = "";   // People
        public const string GlyphPlay      = "";   // Play
        public const string GlyphSearch    = "";   // Search (auditar)
        public const string GlyphCheck     = "";   // CheckMark
        public const string GlyphGlobe     = "";   // Globe
        public const string GlyphSettings  = "";   // Setting
        public const string GlyphUndo      = "";   // Undo
        public const string GlyphRefresh   = "";   // Refresh
        public const string GlyphDownload  = "";   // Download
        public const string GlyphInfo      = "";   // Info
        public const string GlyphAudio     = "";   // Volume
        public const string GlyphPrinter   = "";   // Print
        public const string GlyphUpdate    = "";   // Sync
        public const string GlyphClock     = "";   // Recent
        public const string GlyphError     = "";   // ErrorBadge
        public const string GlyphProcess   = "";   // Diagnostic
        public const string GlyphRepair    = "";   // Repair
        public const string GlyphPower     = "";   // PowerButton
        public const string GlyphMic       = "";   // Microphone
        public const string GlyphBroom     = "";   // Broom
        public const string GlyphShield    = "";   // Shield
        public const string GlyphSave      = "";   // Save
        public const string GlyphCopy      = "";   // Copy
        public const string GlyphFolder    = "";   // Folder
        public const string GlyphClear     = "";   // Clear
        public const string GlyphAdd       = "";   // Add
        public const string GlyphKey       = "";   // Permissions (llave)
        public const string GlyphBlock     = "";   // Blocked
        public const string GlyphDelete    = "";   // Delete
        public const string GlyphWarning   = "";   // Warning
        public const string GlyphStop      = "";   // Stop
        public const string GlyphOk        = "";   // Completed
        public const string GlyphSleep     = "";   // Sleep
        public const string GlyphSetup     = "\uE7B8";   // Package: alta de puesto
        public const string GlyphHistory   = "\uE81C";   // History
        public const string GlyphFirewall  = "\uE72E";   // Lock: firewall y bloqueos
        public const string GlyphFilter    = "\uE71C";   // Filter: filtro web
        public const string GlyphPause     = "\uE769";   // Pause: pausar firewall

        private static readonly Dictionary<string, Bitmap> _glyphCache = new Dictionary<string, Bitmap>();

        private static float _dpiScale;

        /// <summary>
        /// Factor de escala del monitor principal (1.0 = 96 ppp, 1.5 = 150 %). Para lo
        /// que el escalado automático de WinForms no toca: bitmaps y columnas de ListView.
        /// </summary>
        public static float DpiScale
        {
            get
            {
                if (_dpiScale <= 0)
                {
                    try { using (var g = Graphics.FromHwnd(IntPtr.Zero)) _dpiScale = g.DpiX / 96F; }
                    catch { _dpiScale = 1F; }
                }
                return _dpiScale;
            }
        }

        /// <summary>Píxeles lógicos (96 ppp) a píxeles de dispositivo.</summary>
        public static int Px(int logical) => (int)Math.Round(logical * DpiScale);

        /// <summary>Glifo pintado a bitmap para usar como Image de un botón o etiqueta. El tamaño es lógico (se escala al DPI).</summary>
        public static Bitmap Glyph(string glyph, Color color, int size = 16)
        {
            size = Px(size);
            var key = glyph + "|" + color.ToArgb() + "|" + size;
            Bitmap bmp;
            if (_glyphCache.TryGetValue(key, out bmp)) return bmp;

            bmp = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bmp))
            using (var f = new Font("Segoe MDL2 Assets", size * 0.68F, GraphicsUnit.Pixel))
            {
                g.Clear(Color.Transparent);
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                TextRenderer.DrawText(g, glyph, f, new Rectangle(0, 0, size, size), color,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
            _glyphCache[key] = bmp;
            return bmp;
        }

        // --- Botones ----------------------------------------------------------
        public enum ButtonKind { Primary, Secondary, Danger, Warn, Success }

        /// <summary>
        /// Botón plano con borde fino y hover. Un solo aspecto para toda la app:
        ///   Primary   acento sólido, texto blanco (la acción principal de cada página)
        ///   Secondary blanco con borde (todo lo demás)
        ///   Danger    blanco con texto y borde rojos (irreversible)
        ///   Warn      blanco con texto ámbar (requiere reinicio / tarda mucho)
        ///   Success   verde sólido (acciones que "arreglan": activar, instalar)
        /// </summary>
        public static Button MakeButton(string text, ButtonKind kind = ButtonKind.Secondary, string glyph = null, int? width = null)
        {
            var b = new Button
            {
                Text = text,
                AutoSize = width == null,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
                MinimumSize = new Size(width ?? 96, 34),
                Padding = new Padding(glyph != null ? 6 : 10, 0, 10, 0),
                FlatStyle = FlatStyle.Flat,
                Font = kind == ButtonKind.Primary || kind == ButtonKind.Success ? BodyBold : Body,
                Margin = new Padding(0, 0, 8, 8),
                UseVisualStyleBackColor = false,
                Cursor = Cursors.Hand,
                TextAlign = ContentAlignment.MiddleCenter
            };
            if (width != null) { b.Width = width.Value; b.Height = 34; b.TextAlign = ContentAlignment.MiddleLeft; }
            b.FlatAppearance.BorderSize = 1;
            Style(b, kind);
            if (glyph != null)
            {
                b.Image = Glyph(glyph, b.ForeColor);
                b.ImageAlign = ContentAlignment.MiddleLeft;
                b.TextImageRelation = TextImageRelation.ImageBeforeText;
                b.TextAlign = ContentAlignment.MiddleLeft;
                // Deshabilitado: el icono también se atenúa.
                b.EnabledChanged += (s, e) => b.Image = Glyph(glyph, b.Enabled ? ForeOf(kind) : TextMuted);
            }
            return b;
        }

        private static Color ForeOf(ButtonKind kind)
        {
            switch (kind)
            {
                case ButtonKind.Primary:
                case ButtonKind.Success: return Color.White;
                case ButtonKind.Danger:  return Danger;
                case ButtonKind.Warn:    return Warn;
                default:                 return Text;
            }
        }

        private static void Style(Button b, ButtonKind kind)
        {
            b.ForeColor = ForeOf(kind);
            switch (kind)
            {
                case ButtonKind.Primary:
                    b.BackColor = Accent;
                    b.FlatAppearance.BorderColor = Accent;
                    b.FlatAppearance.MouseOverBackColor = AccentDark;
                    b.FlatAppearance.MouseDownBackColor = AccentDark;
                    break;
                case ButtonKind.Success:
                    b.BackColor = Ok;
                    b.FlatAppearance.BorderColor = Ok;
                    b.FlatAppearance.MouseOverBackColor = Color.FromArgb(12, 100, 12);
                    b.FlatAppearance.MouseDownBackColor = Color.FromArgb(12, 100, 12);
                    break;
                case ButtonKind.Danger:
                    b.BackColor = Surface;
                    b.FlatAppearance.BorderColor = Color.FromArgb(230, 170, 165);
                    b.FlatAppearance.MouseOverBackColor = DangerSoft;
                    b.FlatAppearance.MouseDownBackColor = DangerSoft;
                    break;
                case ButtonKind.Warn:
                    b.BackColor = Surface;
                    b.FlatAppearance.BorderColor = Color.FromArgb(230, 200, 150);
                    b.FlatAppearance.MouseOverBackColor = WarnSoft;
                    b.FlatAppearance.MouseDownBackColor = WarnSoft;
                    break;
                default:
                    b.BackColor = Surface;
                    b.FlatAppearance.BorderColor = Border;
                    b.FlatAppearance.MouseOverBackColor = Hover;
                    b.FlatAppearance.MouseDownBackColor = Hover;
                    break;
            }
        }

        // --- Otros controles ----------------------------------------------------
        public static Label SectionLabel(string text) =>
            new Label
            {
                Text = text, AutoSize = true, Font = Section, ForeColor = Text,
                Margin = new Padding(0, 10, 0, 6)
            };

        /// <summary>Texto explicativo: ocupa el ancho disponible y se parte en líneas.</summary>
        public static Label Hint(string text) =>
            new Label
            {
                Text = text, AutoSize = true,
                Anchor = AnchorStyles.Left | AnchorStyles.Right,   // en un TableLayoutPanel: ajusta y envuelve
                ForeColor = TextMuted, Font = Body,
                Margin = new Padding(0, 0, 0, 10)
            };

        public static CheckBox Check(string text, bool chk) =>
            new CheckBox { Text = text, Checked = chk, AutoSize = true, Font = Body, ForeColor = Text, Margin = new Padding(0, 2, 0, 2) };

        /// <summary>Línea de 1 px, horizontal.</summary>
        public static Panel Rule(DockStyle dock = DockStyle.Top) =>
            new Panel { Dock = dock, Height = 1, BackColor = Border };
    }
}
