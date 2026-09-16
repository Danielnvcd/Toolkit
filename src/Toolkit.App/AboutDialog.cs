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
            ClientSize = new Size(480, 330);

            // Filas AutoSize y el formulario se ajusta al contenido en OnLoad: asi
            // ninguna linea (el enlace, el ultimo) queda fuera aunque el texto
            // envuelva distinto por DPI o tamano de texto de accesibilidad.
            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 2, RowCount = 2, Padding = new Padding(20, 18, 20, 14)
            };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
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

            // Actualizaciones y guia de uso: la ficha del proyecto en la web.
            var updates = new LinkLabel
            {
                Text = "Actualizaciones y guia de uso: " + Program.UpdatesUrl,
                AutoSize = true, Anchor = AnchorStyles.Left | AnchorStyles.Right,
                Font = new Font("Segoe UI", 9F), Margin = new Padding(0, 12, 0, 2),
                LinkColor = Color.FromArgb(0, 90, 150), ActiveLinkColor = Color.FromArgb(0, 120, 60),
                VisitedLinkColor = Color.FromArgb(0, 90, 150), LinkBehavior = LinkBehavior.HoverUnderline
            };
            updates.LinkArea = new LinkArea(updates.Text.IndexOf("http", StringComparison.Ordinal), Program.UpdatesUrl.Length);
            updates.LinkClicked += (s, e) =>
            {
                try { System.Diagnostics.Process.Start(Program.UpdatesUrl); }
                catch (Exception ex) { MessageBox.Show(this, "No se pudo abrir el navegador: " + ex.Message, Program.AppName); }
            };
            text.Controls.Add(updates);

            // Botonera: el enlace tambien como boton, que nunca se puede recortar.
            var web = new Button
            {
                Text = "Actualizaciones y guia de uso", AutoSize = true, Height = 30, Padding = new Padding(8, 0, 8, 0),
                FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(0, 90, 150), ForeColor = Color.White,
                Font = new Font("Segoe UI", 9F, FontStyle.Bold), Margin = new Padding(0, 14, 10, 0)
            };
            web.Click += (s, e) =>
            {
                try { System.Diagnostics.Process.Start(Program.UpdatesUrl); }
                catch (Exception ex) { MessageBox.Show(this, "No se pudo abrir el navegador: " + ex.Message, Program.AppName); }
            };
            var ok = new Button
            {
                Text = "Cerrar", DialogResult = DialogResult.OK, Width = 90, Height = 30,
                FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(230, 230, 230), Margin = new Padding(0, 14, 0, 0)
            };
            AcceptButton = CancelButton = ok;
            var buttons = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = FlowDirection.RightToLeft,
                Anchor = AnchorStyles.Right, Margin = new Padding(0)
            };
            buttons.Controls.Add(ok);
            buttons.Controls.Add(web);

            root.Controls.Add(logo, 0, 0);
            root.Controls.Add(text, 1, 0);
            root.Controls.Add(buttons, 1, 1);
            Controls.Add(root);

            // Alto final = lo que ocupa el contenido, calculado con el ancho real.
            Load += (s, e) => ClientSize = new Size(ClientSize.Width, root.GetPreferredSize(new Size(ClientSize.Width, 0)).Height);
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
