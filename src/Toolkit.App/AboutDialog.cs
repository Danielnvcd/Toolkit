using System;
using System.Drawing;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Acerca de: logo, nombre, version, creador, fecha de compilacion y que hace.
    /// Los datos salen del ensamblado (ver Program.AppAuthor y el .csproj).
    /// </summary>
    internal sealed class AboutDialog : Form
    {
        public AboutDialog()
        {
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);
            Text = "Acerca de " + Program.AppName;
            if (EmbeddedScripts.AppIcon != null) Icon = EmbeddedScripts.AppIcon;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MaximizeBox = MinimizeBox = false;
            ShowInTaskbar = false;
            Font = new Font("Segoe UI", 9F);
            BackColor = Color.White;
            ClientSize = new Size(460, 300);

            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Padding = new Padding(20, 18, 20, 14)
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            var logo = new PictureBox { Size = new Size(72, 72), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 0, 18, 0) };
            if (EmbeddedScripts.AppIcon != null)
            {
                try { logo.Image = new Icon(EmbeddedScripts.AppIcon, 64, 64).ToBitmap(); } catch { }
            }

            var text = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, AutoSize = true };
            text.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            text.Controls.Add(Line(Program.AppName, 15F, FontStyle.Bold, Color.FromArgb(32, 45, 66)));
            text.Controls.Add(Line("Version " + Program.AppVersion() + "   ·   compilado " + Program.AppBuildDate(), 9F, FontStyle.Regular, Color.DimGray));
            text.Controls.Add(Line(Program.AppDescription, 9F, FontStyle.Regular, Color.Black, top: 12));
            text.Controls.Add(Line("Creado por " + Program.AppAuthor, 9.5F, FontStyle.Bold, Color.Black, top: 14));
            text.Controls.Add(Line(Program.AppCopyright, 8.5F, FontStyle.Regular, Color.DimGray));
            text.Controls.Add(Line(
                "Un solo ejecutable, sin instalacion. Los modulos de PowerShell van embebidos y se ejecutan en memoria. " +
                "Requiere Windows 10/11 con .NET Framework 4.8 y PowerShell 5.1, que vienen de fabrica.",
                8.5F, FontStyle.Regular, Color.DimGray, top: 12));

            var ok = new Button
            {
                Text = "Cerrar", DialogResult = DialogResult.OK, Width = 90, Height = 30,
                Anchor = AnchorStyles.Right, FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(230, 230, 230)
            };
            AcceptButton = CancelButton = ok;

            root.Controls.Add(logo, 0, 0);
            root.Controls.Add(text, 1, 0);
            root.Controls.Add(ok, 1, 1);
            Controls.Add(root);
        }

        private static Label Line(string text, float size, FontStyle style, Color color, int top = 0) =>
            new Label
            {
                Text = text, AutoSize = true,
                Anchor = AnchorStyles.Left | AnchorStyles.Right,   // envuelve al ancho de la columna
                Font = new Font("Segoe UI", size, style), ForeColor = color,
                Margin = new Padding(0, top, 0, 2)
            };
    }
}
