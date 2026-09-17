using System;
using System.Drawing;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Acerca de: logo, nombre, versión, creador, fecha de compilación y qué hace.
    /// Los datos salen del ensamblado (ver Program.AppAuthor y el .csproj).
    /// </summary>
    internal sealed class AboutDialog : Form
    {
        public AboutDialog()
        {
            SuspendLayout();   // ver MainForm.BuildUi: el escalado DPI se aplica en ResumeLayout, con todos los hijos ya creados
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);
            Text = "Acerca de " + Program.AppName;
            if (EmbeddedScripts.AppIcon != null) Icon = EmbeddedScripts.AppIcon;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MaximizeBox = MinimizeBox = false;
            ShowInTaskbar = false;
            Font = Theme.Body;
            BackColor = Theme.Surface;
            ClientSize = new Size(500, 330);

            // Filas AutoSize y el formulario se ajusta al contenido en OnLoad: así
            // ninguna línea queda fuera aunque el texto envuelva distinto por DPI o
            // tamaño de texto de accesibilidad.
            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 2, RowCount = 1, Padding = new Padding(22, 20, 22, 16)
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            var logo = new PictureBox { Size = new Size(72, 72), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 2, 20, 0) };
            logo.Image = EmbeddedScripts.AppLogoBitmap(64);

            var text = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, AutoSize = true };
            text.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            text.Controls.Add(Line(Program.AppName, Theme.Heading, Theme.Text));
            text.Controls.Add(Line("Versión " + Program.AppVersion() + "   ·   compilado " + Program.AppBuildDate(), Theme.Body, Theme.TextMuted));
            text.Controls.Add(Line(Program.AppDescription, Theme.Body, Theme.Text, top: 12));
            text.Controls.Add(Line("Creado por " + Program.AppAuthor, Theme.BodyBold, Theme.Text, top: 14));
            text.Controls.Add(Line(Program.AppCopyright, Theme.Small, Theme.TextMuted));
            text.Controls.Add(Line(
                "Un solo ejecutable, sin instalación. Los módulos de PowerShell van embebidos y se ejecutan en memoria. " +
                "Requiere Windows 10/11 con .NET Framework 4.8 y PowerShell 5.1, que vienen de fábrica.",
                Theme.Small, Theme.TextMuted, top: 12));

            // Actualizaciones y guía de uso: la ficha del proyecto en la web.
            var updates = new LinkLabel
            {
                Text = Program.UpdatesUrl, AutoSize = true, Anchor = AnchorStyles.Left | AnchorStyles.Right,
                Font = Theme.Body, Margin = new Padding(0, 12, 0, 2),
                LinkColor = Theme.Accent, ActiveLinkColor = Theme.AccentDark, VisitedLinkColor = Theme.Accent,
                LinkBehavior = LinkBehavior.HoverUnderline
            };
            updates.LinkClicked += (s, e) => OpenSite();
            text.Controls.Add(updates);

            root.Controls.Add(logo, 0, 0);
            root.Controls.Add(text, 1, 0);

            // Franja de botones, como en el resto de diálogos.
            var web = Theme.MakeButton("Actualizaciones y guía de uso", Theme.ButtonKind.Primary, Theme.GlyphGlobe);
            web.Margin = new Padding(8, 0, 0, 0);
            web.Click += (s, e) => OpenSite();
            var ok = Theme.MakeButton("Cerrar", Theme.ButtonKind.Secondary);
            ok.MinimumSize = new Size(104, 34);
            ok.Margin = new Padding(8, 0, 0, 0);
            ok.DialogResult = DialogResult.OK;
            AcceptButton = CancelButton = ok;
            var bar = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Padding = new Padding(14, 12, 14, 6), BackColor = Theme.Window
            };
            bar.Controls.Add(ok);
            bar.Controls.Add(web);

            Controls.Add(root);
            Controls.Add(Theme.Rule(DockStyle.Bottom));
            Controls.Add(bar);

            // Alto final = lo que ocupa el contenido, calculado con el ancho real.
            ResumeLayout(false);
            PerformLayout();
            Load += (s, e) => ClientSize = new Size(ClientSize.Width, root.GetPreferredSize(new Size(ClientSize.Width, 0)).Height + bar.Height + 1);
        }

        private void OpenSite()
        {
            try { System.Diagnostics.Process.Start(Program.UpdatesUrl); }
            catch (Exception ex) { Dialogs.Error(this, Program.AppName, "No se pudo abrir el navegador: " + ex.Message); }
        }

        private static Label Line(string text, Font font, Color color, int top = 0) =>
            new Label
            {
                Text = text, AutoSize = true,
                Anchor = AnchorStyles.Left | AnchorStyles.Right,   // envuelve al ancho de la columna
                Font = font, ForeColor = color,
                Margin = new Padding(0, top, 0, 2)
            };
    }
}
