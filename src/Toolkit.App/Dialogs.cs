using System;
using System.Drawing;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Diálogos de confirmación e información propios, en lugar de MessageBox.
    ///
    /// La diferencia que importa: los botones dicen lo que hacen ("Eliminar cuenta
    /// y carpeta" / "Solo la cuenta" / "Cancelar") en vez de Sí/No/Cancelar con la
    /// leyenda escondida en el texto. Y se ven como el resto de la aplicación.
    /// </summary>
    internal static class Dialogs
    {
        public enum Kind { Info, Question, Warning, Error }

        /// <summary>Confirmación con dos botones. Devuelve true si se pulsó el principal.</summary>
        public static bool Confirm(IWin32Window owner, string title, string message, string okText,
                                   bool danger = false, string cancelText = "Cancelar")
        {
            return Choice(owner, title, message, new[] { okText, cancelText }, danger ? Kind.Warning : Kind.Question, danger) == 0;
        }

        public static void Info(IWin32Window owner, string title, string message) =>
            Choice(owner, title, message, new[] { "Aceptar" }, Kind.Info);

        public static void Warn(IWin32Window owner, string title, string message) =>
            Choice(owner, title, message, new[] { "Aceptar" }, Kind.Warning);

        public static void Error(IWin32Window owner, string title, string message) =>
            Choice(owner, title, message, new[] { "Aceptar" }, Kind.Error);

        /// <summary>
        /// N botones con texto propio. Devuelve el índice del pulsado; el último
        /// es siempre el de cancelar (Esc / cerrar la ventana devuelven ese índice).
        /// </summary>
        public static int Choice(IWin32Window owner, string title, string message, string[] buttons,
                                 Kind kind = Kind.Question, bool dangerPrimary = false)
        {
            using (var dlg = new ChoiceDialog(title, message, buttons, kind, dangerPrimary))
            {
                dlg.ShowDialog(owner);
                return dlg.Result;
            }
        }

        private sealed class ChoiceDialog : Form
        {
            public int Result { get; private set; }

            public ChoiceDialog(string title, string message, string[] buttons, Kind kind, bool dangerPrimary)
            {
                Result = buttons.Length - 1;

                SuspendLayout();   // ver MainForm.BuildUi: el escalado DPI se aplica en ResumeLayout, con todos los hijos ya creados
                AutoScaleMode = AutoScaleMode.Dpi;
                AutoScaleDimensions = new SizeF(96F, 96F);
                Text = title;
                if (EmbeddedScripts.AppIcon != null) Icon = EmbeddedScripts.AppIcon;
                FormBorderStyle = FormBorderStyle.FixedDialog;
                StartPosition = FormStartPosition.CenterParent;
                MaximizeBox = MinimizeBox = false;
                ShowInTaskbar = false;
                Font = Theme.Body;
                BackColor = Theme.Surface;
                ClientSize = new Size(460, 160);
                KeyPreview = true;

                string glyph; Color color;
                switch (kind)
                {
                    case Kind.Info:    glyph = Theme.GlyphInfo;    color = Theme.Accent; break;
                    case Kind.Warning: glyph = Theme.GlyphWarning; color = Theme.Warn;   break;
                    case Kind.Error:   glyph = Theme.GlyphError;   color = Theme.Danger; break;
                    default:           glyph = "";           color = Theme.Accent; break;   // Help
                }

                var icon = new PictureBox
                {
                    Image = Theme.Glyph(glyph, color, 40), Size = new Size(40, 40),
                    SizeMode = PictureBoxSizeMode.CenterImage, Margin = new Padding(0, 2, 16, 0)
                };
                var head = new Label
                {
                    Text = title, AutoSize = true, Font = Theme.Title, ForeColor = Theme.Text,
                    Anchor = AnchorStyles.Left | AnchorStyles.Right, Margin = new Padding(0, 0, 0, 6)
                };
                var body = new Label
                {
                    Text = message, AutoSize = true, Font = Theme.Body, ForeColor = Theme.Text,
                    Anchor = AnchorStyles.Left | AnchorStyles.Right, Margin = new Padding(0)
                };

                var textCol = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill, Margin = new Padding(0) };
                textCol.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
                textCol.Controls.Add(head);
                textCol.Controls.Add(body);

                var content = new TableLayoutPanel
                {
                    Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                    ColumnCount = 2, Padding = new Padding(22, 20, 22, 18), BackColor = Theme.Surface
                };
                content.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
                content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
                content.Controls.Add(icon, 0, 0);
                content.Controls.Add(textCol, 1, 0);

                // Botonera en una franja gris, botones de derecha a izquierda:
                // el principal queda el más a la derecha, como en Windows.
                var bar = new FlowLayoutPanel
                {
                    Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, WrapContents = false,
                    AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                    Padding = new Padding(14, 12, 14, 6), BackColor = Theme.Window
                };
                Button first = null;
                for (int i = buttons.Length - 1; i >= 0; i--)
                {
                    int idx = i;
                    var kindBtn = i == 0
                        ? (dangerPrimary ? Theme.ButtonKind.Danger : Theme.ButtonKind.Primary)
                        : Theme.ButtonKind.Secondary;
                    var b = Theme.MakeButton(buttons[i], kindBtn);
                    b.Margin = new Padding(8, 0, 0, 0);
                    b.MinimumSize = new Size(104, 34);
                    b.Click += (s, e) => { Result = idx; Close(); };
                    bar.Controls.Add(b);
                    if (i == 0) first = b;
                    if (i == buttons.Length - 1) CancelButton = b;
                }
                AcceptButton = first;

                Controls.Add(content);
                Controls.Add(Theme.Rule(DockStyle.Bottom));
                Controls.Add(bar);

                // Ancho: el mínimo, o lo que necesiten los botones en una sola fila
                // (tres botones con texto largo no caben en 460). Alto: el del texto.
                ResumeLayout(false);
                PerformLayout();
                Load += (s, e) =>
                {
                    int need = bar.Padding.Horizontal;
                    foreach (Control b in bar.Controls) need += b.Width + b.Margin.Horizontal;
                    var w = Math.Max(ClientSize.Width, need + 8);
                    var h = content.GetPreferredSize(new Size(w, 0)).Height + bar.Height + 1;
                    ClientSize = new Size(w, h);
                    if (first != null) first.Focus();
                };
            }
        }
    }
}
