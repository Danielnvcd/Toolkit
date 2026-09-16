using System;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Interfaz para el tecnico en sitio. Misma logica que el modo desatendido:
    /// por debajo llama al mismo Invoke-ToolkitRun.ps1 embebido, de modo que
    /// GUI y despliegue masivo no pueden divergir.
    /// </summary>
    public sealed class MainForm : Form
    {
        private readonly CommandLineArgs _args;

        private CheckBox _chkLocation, _chkApps, _chkNetwork, _chkLockDown;
        private Button _btnAudit, _btnApply, _btnRollback;
        private RichTextBox _log;
        private Label _status;
        private ProgressBar _progress;

        public MainForm(CommandLineArgs args)
        {
            _args = args;
            BuildUi();
        }

        private void BuildUi()
        {
            Text = "Toolkit Call Center  v" + Program.AppVersion();
            Size = new Size(920, 640);
            MinimumSize = new Size(760, 520);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9F);
            BackColor = Color.FromArgb(243, 243, 243);

            var header = new Label
            {
                Text = "  " + Environment.MachineName + "   ·   " + Environment.UserName,
                Dock = DockStyle.Top,
                Height = 44,
                TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Segoe UI", 12F, FontStyle.Bold),
                BackColor = Color.FromArgb(32, 45, 66),
                ForeColor = Color.White
            };

            var panel = new Panel { Dock = DockStyle.Top, Height = 132, Padding = new Padding(16, 12, 16, 8) };

            _chkLocation = NewCheck("Ubicacion  (servicio lfsvc + politicas + todos los perfiles)", 8, true);
            _chkApps     = NewCheck("Aplicaciones  (instalacion desatendida del catalogo)",          32, true);
            _chkNetwork  = NewCheck("Diagnostico de red  (latencia, jitter, perdida, DNS, MTU)",     56, true);
            _chkLockDown = NewCheck("Impedir que el usuario desactive la ubicacion  (recomendado)",  84, true);
            _chkLockDown.ForeColor = Color.FromArgb(120, 60, 0);

            panel.Controls.AddRange(new Control[] { _chkLocation, _chkApps, _chkNetwork, _chkLockDown });

            var buttons = new Panel { Dock = DockStyle.Top, Height = 56, Padding = new Padding(16, 6, 16, 6) };

            _btnAudit    = NewButton("Auditar  (no cambia nada)", 0,   170, Color.FromArgb(230, 230, 230), Color.Black);
            _btnApply    = NewButton("APLICAR CAMBIOS",           182, 170, Color.FromArgb(0, 120, 60),    Color.White);
            _btnRollback = NewButton("Revertir",                  364, 110, Color.FromArgb(150, 40, 40),   Color.White);

            _btnAudit.Click    += (s, e) => Execute(reportOnly: true);
            _btnApply.Click    += (s, e) => Execute(reportOnly: false);
            _btnRollback.Click += (s, e) => Rollback();

            buttons.Controls.AddRange(new Control[] { _btnAudit, _btnApply, _btnRollback });

            _log = new RichTextBox
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                BackColor = Color.FromArgb(24, 24, 24),
                ForeColor = Color.Gainsboro,
                Font = new Font("Consolas", 8.75F),
                BorderStyle = BorderStyle.None,
                WordWrap = false,
                ScrollBars = RichTextBoxScrollBars.Both
            };
            var logHost = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 4, 16, 8) };
            logHost.Controls.Add(_log);

            _progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 4, Style = ProgressBarStyle.Marquee, Visible = false };
            _status = new Label
            {
                Dock = DockStyle.Bottom,
                Height = 26,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(16, 0, 0, 0),
                ForeColor = Color.DimGray,
                Text = "Listo."
            };

            Controls.AddRange(new Control[] { logHost, buttons, panel, header, _progress, _status });

            Append(LogLevel.Info,  "Toolkit v" + Program.AppVersion() + " — los scripts van embebidos en este ejecutable.");
            Append(LogLevel.Debug, "Auditar evalua el equipo sin modificar nada. Empieza siempre por ahi.");
        }

        private CheckBox NewCheck(string text, int top, bool chk) =>
            new CheckBox { Text = text, Top = top, Left = 16, Width = 640, Checked = chk, AutoSize = true };

        private Button NewButton(string text, int left, int width, Color back, Color fore) =>
            new Button
            {
                Text = text, Left = left + 16, Top = 8, Width = width, Height = 34,
                BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9F, FontStyle.Bold)
            };

        private string[] SelectedModules()
        {
            var mods = new System.Collections.Generic.List<string>();
            if (_chkLocation.Checked) mods.Add("location");
            if (_chkApps.Checked)     mods.Add("apps");
            if (_chkNetwork.Checked)  mods.Add("network");
            return mods.ToArray();
        }

        private async void Execute(bool reportOnly)
        {
            var modules = SelectedModules();
            if (modules.Length == 0)
            {
                MessageBox.Show("Selecciona al menos un modulo.", "Toolkit",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            if (!reportOnly)
            {
                var confirm = MessageBox.Show(
                    "Se van a aplicar cambios en este equipo:\n\n  · " + string.Join("\n  · ", modules) +
                    "\n\nTodos los cambios de registro quedan registrados y son reversibles con 'Revertir'.\n\n¿Continuar?",
                    "Confirmar", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (confirm != DialogResult.Yes) return;
            }

            SetBusy(true, reportOnly ? "Auditando..." : "Aplicando cambios...");
            _log.Clear();

            var exitCode = await Task.Run(() =>
            {
                try
                {
                    using (var host = new ScriptHost())
                    {
                        host.Output += (s, e) => Append(e.Level, e.Text);
                        host.Open();

                        string origin;
                        var catalog = EmbeddedScripts.ReadCatalog(_args.ConfigPath, _args.SharePath, out origin);
                        Append(LogLevel.Debug, "Catalogo: " + origin);

                        return host.Run(new RunOptions
                        {
                            Modules     = modules,
                            CatalogJson = catalog,
                            SharePath   = _args.SharePath,
                            Root        = _args.Root,
                            ReportOnly  = reportOnly,
                            Silent      = false,
                            NoLockDown  = !_chkLockDown.Checked,
                            // El tecnico esta delante: no tiene sentido aplazar a la ventana nocturna.
                            IgnoreMaintenanceWindow = true
                        });
                    }
                }
                catch (Exception ex)
                {
                    Append(LogLevel.Error, "ERROR: " + ex.Message);
                    return Program.ExitGeneric;
                }
            });

            SetBusy(false, DescribeExit(exitCode));

            if (exitCode != 0 && exitCode != Program.ExitRebootNeeded)
            {
                MessageBox.Show(DescribeExit(exitCode) + "\n\nRevisa el log para el detalle.",
                    "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private async void Rollback()
        {
            var confirm = MessageBox.Show(
                "Esto revertira TODOS los cambios de registro aplicados por el toolkit en este equipo.\n\n¿Continuar?",
                "Confirmar reversion", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            SetBusy(true, "Revirtiendo...");
            _log.Clear();

            await Task.Run(() =>
            {
                try
                {
                    using (var host = new ScriptHost())
                    {
                        host.Output += (s, e) => Append(e.Level, e.Text);
                        host.Open();
                        host.Invoke("param($Root) Initialize-Toolkit -Root $Root; Invoke-ToolkitRollback",
                            new System.Collections.Generic.Dictionary<string, object> { { "Root", _args.Root } });
                    }
                }
                catch (Exception ex) { Append(LogLevel.Error, "ERROR: " + ex.Message); }
            });

            SetBusy(false, "Reversion terminada.");
        }

        private static string DescribeExit(int code)
        {
            switch (code)
            {
                case 0:    return "Terminado correctamente.";
                case 3010: return "Terminado. REQUIERE REINICIO.";
                case 1001: return "Fallo el modulo de ubicacion.";
                case 1002: return "Fallo la instalacion de una o mas aplicaciones.";
                case 1003: return "Red en estado critico.";
                case 5:    return "Sin privilegios de administrador.";
                default:   return "Terminado con errores (codigo " + code + ").";
            }
        }

        private void SetBusy(bool busy, string status)
        {
            _btnApply.Enabled = _btnAudit.Enabled = _btnRollback.Enabled = !busy;
            _progress.Visible = busy;
            _status.Text = status;
        }

        private void Append(LogLevel level, string text)
        {
            if (string.IsNullOrEmpty(text)) return;

            if (_log.InvokeRequired)
            {
                _log.BeginInvoke(new Action(() => Append(level, text)));
                return;
            }

            Color color;
            switch (level)
            {
                case LogLevel.Ok:    color = Color.FromArgb(120, 220, 120); break;
                case LogLevel.Warn:  color = Color.FromArgb(240, 200, 100); break;
                case LogLevel.Error: color = Color.FromArgb(240, 120, 120); break;
                case LogLevel.Debug: color = Color.FromArgb(130, 130, 130); break;
                default:             color = Color.Gainsboro; break;
            }

            _log.SelectionStart = _log.TextLength;
            _log.SelectionLength = 0;
            _log.SelectionColor = color;
            _log.AppendText(text + Environment.NewLine);
            _log.SelectionColor = _log.ForeColor;
            _log.ScrollToCaret();
        }
    }
}
