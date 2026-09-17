using System;
using System.Collections.Generic;
using System.Drawing;
using System.Management.Automation;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Últimas ejecuciones del toolkit en este equipo (Get-ToolkitHistory: una fila
    /// por log). Doble clic o "Abrir log" abre el archivo en el Bloc de notas.
    /// </summary>
    internal sealed class HistoryDialog : Form
    {
        private readonly ListView _list;

        public HistoryDialog(IList<PSObject> rows)
        {
            SuspendLayout();   // ver MainForm.BuildUi: el escalado DPI se aplica en ResumeLayout
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);
            Text = "Historial de ejecuciones";
            if (EmbeddedScripts.AppIcon != null) Icon = EmbeddedScripts.AppIcon;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            MinimizeBox = false;
            Font = Theme.Body;
            BackColor = Theme.Surface;
            ClientSize = new Size(860, 460);
            MinimumSize = new Size(600, 300);

            var hint = Theme.Hint("Una fila por ejecución (cada una tiene su log en C:\\ProgramData\\Toolkit\\logs). Doble clic para abrir el log.");
            hint.Dock = DockStyle.Top;
            hint.AutoSize = false;
            hint.Height = 40;
            hint.Padding = new Padding(16, 12, 16, 0);

            _list = new ListView
            {
                Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false,
                HideSelection = false, BorderStyle = BorderStyle.FixedSingle, Font = Theme.Body
            };
            _list.Columns.Add("Fecha", Theme.Px(130));
            _list.Columns.Add("Modo", Theme.Px(120));
            _list.Columns.Add("Resultado", Theme.Px(150));
            _list.Columns.Add("Qué se hizo", Theme.Px(400));
            _list.DoubleClick += (s, e) => OpenSelected();
            _list.Resize += (s, e) =>
            {
                int used = 0;
                for (int i = 0; i < _list.Columns.Count - 1; i++) used += _list.Columns[i].Width;
                _list.Columns[_list.Columns.Count - 1].Width = Math.Max(_list.ClientSize.Width - used, Theme.Px(120));
            };

            foreach (var r in rows)
            {
                var date = r.Properties["Date"]?.Value;
                var exit = r.Properties["ExitCode"]?.Value;
                int errors = ToInt(r.Properties["Errors"]?.Value), warns = ToInt(r.Properties["Warnings"]?.Value);
                var mode = Convert.ToString(r.Properties["Mode"]?.Value ?? "");
                if (mode.StartsWith("SOLO REPORTE")) mode = "Solo lectura";
                else if (mode == "INTERACTIVO") mode = "Interactivo";
                else if (mode == "DESATENDIDO") mode = "Desatendido (agente)";

                string result; Color color;
                if (exit == null)          { result = errors > 0 ? errors + " error(es)" : warns > 0 ? warns + " aviso(s)" : "OK"; color = errors > 0 ? Theme.Danger : warns > 0 ? Theme.Warn : Theme.Ok; }
                else if (ToInt(exit) == 0) { result = warns > 0 ? "OK, " + warns + " aviso(s)" : "OK"; color = warns > 0 ? Theme.Warn : Theme.Ok; }
                else if (ToInt(exit) == 3010) { result = "OK, requiere reinicio"; color = Theme.Warn; }
                else                       { result = "Fallo (código " + exit + ")"; color = Theme.Danger; }

                var item = new ListViewItem(new[]
                {
                    date is DateTime ? ((DateTime)date).ToString("yyyy-MM-dd HH:mm") : Convert.ToString(date),
                    mode,
                    result,
                    Convert.ToString(r.Properties["Steps"]?.Value ?? "")
                }) { Tag = Convert.ToString(r.Properties["Path"]?.Value), UseItemStyleForSubItems = false };
                item.SubItems[2].ForeColor = color;
                _list.Items.Add(item);
            }

            var open  = Theme.MakeButton("Abrir log", Theme.ButtonKind.Primary, Theme.GlyphFolder);
            var close = Theme.MakeButton("Cerrar", Theme.ButtonKind.Secondary);
            open.Margin = close.Margin = new Padding(8, 0, 0, 0);
            close.MinimumSize = new Size(104, 34);
            open.Click += (s, e) => OpenSelected();
            close.DialogResult = DialogResult.Cancel;
            var bar = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, WrapContents = false,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Padding = new Padding(14, 12, 14, 6), BackColor = Theme.Window
            };
            bar.Controls.Add(close);
            bar.Controls.Add(open);
            CancelButton = close;

            var host = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 0, 16, 12), BackColor = Theme.Surface };
            host.Controls.Add(_list);

            Controls.Add(host);
            Controls.Add(hint);
            Controls.Add(Theme.Rule(DockStyle.Bottom));
            Controls.Add(bar);
            ResumeLayout(false);
            PerformLayout();
        }

        private static int ToInt(object v)
        {
            int i;
            return v != null && int.TryParse(v.ToString(), out i) ? i : 0;
        }

        private void OpenSelected()
        {
            if (_list.SelectedItems.Count == 0) return;
            var path = _list.SelectedItems[0].Tag as string;
            if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path)) return;
            try { System.Diagnostics.Process.Start("notepad.exe", "\"" + path + "\""); } catch { }
        }
    }
}
