using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Management.Automation;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Interfaz para el tecnico en sitio. Misma logica que el modo desatendido:
    /// por debajo llama al mismo Invoke-ToolkitRun.ps1 embebido, de modo que
    /// GUI y despliegue masivo no pueden divergir.
    ///
    /// Cada modulo tiene su propia pestana (Ubicacion, Aplicaciones, Red,
    /// Usuarios) con sus opciones y sus botones: el tecnico ejecuta una cosa
    /// cada vez y ve en el log de abajo solo lo que pidio.
    ///
    /// La pestana "Usuarios" es la excepcion deliberada: cambiar contrasenas o
    /// borrar cuentas es interactivo por naturaleza y no se despliega en masa.
    /// Llama directamente a las funciones de Toolkit.Users.psm1.
    /// </summary>
    public sealed class MainForm : Form
    {
        private readonly CommandLineArgs _args;

        private RichTextBox _log;
        private Label _status;
        private ProgressBar _progress;
        private TabControl _tabs;
        private TabPage _tabApps, _tabUsers;

        // Botones que lanzan una ejecucion; se bloquean todos mientras hay una en curso.
        private readonly List<Button> _actionButtons = new List<Button>();

        // Pestana Ubicacion
        private CheckBox _chkLockDown, _chkBrowsers, _chkGetPosition;

        // Pestana Aplicaciones
        private CheckedListBox _apps;
        private Label _appsHint;
        private bool _appsLoaded;

        // Pestana Red
        private NumericUpDown _pingCount;

        // Pestana Usuarios
        private ListView _users;
        private Button _btnUsersRefresh, _btnUserNew, _btnUserPwd, _btnUserNoPwd, _btnUserToggle, _btnUserDelete;
        private ScriptHost _sharedHost;
        private bool _usersLoaded;

        private sealed class UserRow
        {
            public string Name, FullName, Sid, ProfilePath, LastLogon;
            public bool Enabled, LockedOut, IsAdmin, PasswordRequired, BuiltIn, SessionOpen, IsCurrentUser, HasProfile;
        }

        public MainForm(CommandLineArgs args)
        {
            _args = args;
            BuildUi();
            FormClosed += (s, e) => { if (_sharedHost != null) _sharedHost.Dispose(); };
        }

        private void BuildUi()
        {
            // Escalado DPI: el manifiesto declara la app PerMonitorV2, asi que Windows
            // NO la estira. Sin esto, al 125 %/150 % el texto crece y los controles no,
            // y se pisan. Todas las medidas de este archivo son a 96 ppp.
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);

            Text = "Toolkit BPO";
            if (EmbeddedScripts.AppIcon != null) Icon = EmbeddedScripts.AppIcon;
            Font = new Font("Segoe UI", 9F);
            BackColor = Color.FromArgb(243, 243, 243);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(640, 480);

            // Tamano inicial: el preferido, pero nunca mas grande que la pantalla
            // (portatiles de 1366x768 con la barra de tareas, monitores pequenos...).
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Size = new Size(Math.Min(940, area.Width - 40), Math.Min(720, area.Height - 40));

            // Cabecera: logo + nombre de la app a la izquierda, equipo y usuario a la derecha.
            var header = new Panel { Dock = DockStyle.Top, Height = 48, BackColor = Color.FromArgb(32, 45, 66) };
            var logo = new PictureBox
            {
                Dock = DockStyle.Left, Width = 48, SizeMode = PictureBoxSizeMode.CenterImage,
                Margin = new Padding(0)
            };
            if (EmbeddedScripts.AppIcon != null)
            {
                try { logo.Image = new Icon(EmbeddedScripts.AppIcon, 32, 32).ToBitmap(); } catch { }
            }
            var title = new Label
            {
                Text = "Toolkit BPO",
                Dock = DockStyle.Left, AutoSize = true,
                Padding = new Padding(0, 12, 0, 0),
                Font = new Font("Segoe UI", 13F, FontStyle.Bold),
                ForeColor = Color.White
            };
            // "Acerca de" a la derecha del todo; el logo y el nombre tambien lo abren.
            var about = new LinkLabel
            {
                Text = "Acerca de", Dock = DockStyle.Right, AutoSize = false, Width = 84,
                TextAlign = ContentAlignment.MiddleCenter,
                LinkColor = Color.FromArgb(200, 210, 225), ActiveLinkColor = Color.White,
                VisitedLinkColor = Color.FromArgb(200, 210, 225), LinkBehavior = LinkBehavior.HoverUnderline,
                Font = new Font("Segoe UI", 9F)
            };
            about.LinkClicked += (s, e) => ShowAbout();
            logo.Cursor = title.Cursor = Cursors.Hand;
            logo.Click  += (s, e) => ShowAbout();
            title.Click += (s, e) => ShowAbout();

            var machine = new Label
            {
                Text = Environment.MachineName + "   ·   " + Environment.UserName + "   ·   v" + Program.AppVersion(),
                Dock = DockStyle.Fill, AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleRight,
                Padding = new Padding(8, 0, 8, 0),
                Font = new Font("Segoe UI", 9.5F),
                ForeColor = Color.FromArgb(200, 210, 225)
            };
            header.Controls.AddRange(new Control[] { machine, about, title, logo });

            _tabs = new TabControl { Dock = DockStyle.Fill };
            _tabApps  = BuildAppsTab();
            _tabUsers = BuildUsersTab();
            _tabs.TabPages.Add(BuildLocationTab());
            _tabs.TabPages.Add(_tabApps);
            _tabs.TabPages.Add(BuildNetworkTab());
            _tabs.TabPages.Add(BuildSupportTab());
            _tabs.TabPages.Add(_tabUsers);
            // Las listas se cargan la primera vez que se abre la pestana: abrir un
            // runspace cuesta un segundo y no tiene sentido pagarlo al arrancar.
            _tabs.SelectedIndexChanged += async (s, e) =>
            {
                if (_tabs.SelectedTab == _tabUsers && !_usersLoaded) await RefreshUsers();
                if (_tabs.SelectedTab == _tabApps  && !_appsLoaded)  await RefreshApps();
            };

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
            var logHost = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 0, 16, 8) };
            logHost.Controls.Add(_log);

            // Arriba las pestanas, abajo el log. El separador se arrastra con el raton;
            // se hace mas ancho que el de serie (4 px) para que se pueda coger.
            // Panel1 es el fijo: al agrandar la ventana, el espacio extra va al log.
            var split = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Horizontal,
                FixedPanel = FixedPanel.Panel1,
                SplitterWidth = 8,
                Panel1MinSize = 120,
                Panel2MinSize = 80,
                BackColor = Color.FromArgb(225, 225, 225)
            };
            split.Panel1.BackColor = split.Panel2.BackColor = BackColor;
            split.Panel1.Padding = new Padding(16, 8, 16, 0);
            split.Panel1.Controls.Add(_tabs);
            split.Panel2.Controls.Add(logHost);
            // Pista visual de que el separador se puede arrastrar.
            split.Paint += (s, e) =>
            {
                var r = split.SplitterRectangle;
                using (var pen = new Pen(Color.FromArgb(160, 160, 160)))
                {
                    int cx = r.Left + r.Width / 2, cy = r.Top + r.Height / 2;
                    e.Graphics.DrawLine(pen, cx - 16, cy, cx + 16, cy);
                }
            };

            _progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 4, Style = ProgressBarStyle.Marquee, Visible = false };
            _status = new Label
            {
                Dock = DockStyle.Bottom,
                Height = 26,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(16, 0, 0, 0),
                ForeColor = Color.DimGray,
                Text = "Listo."
            };

            Controls.AddRange(new Control[] { split, header, _progress, _status });

            // La distancia del separador se fija cuando el formulario ya tiene su
            // tamano real (escalado DPI incluido); antes, WinForms la recorta.
            Load += (s, e) =>
            {
                // 350 px logicos (cabe la pestana Soporte entera), pero nunca mas del 60 % de la altura.
                var want = Math.Min(LogicalToDeviceUnits(350), (int)(split.Height * 0.6));
                want = Math.Max(split.Panel1MinSize, Math.Min(want, split.Height - split.Panel2MinSize - split.SplitterWidth));
                try { split.SplitterDistance = want; } catch (ArgumentException) { }
            };

            Append(LogLevel.Info,  "Toolkit BPO v" + Program.AppVersion() + " — los scripts van embebidos en este ejecutable.");
            Append(LogLevel.Debug, "Auditar evalua el equipo sin modificar nada. Empieza siempre por ahi.");
        }

        // -------------------------------------------------------------------
        //  Pestana Ubicacion
        // -------------------------------------------------------------------
        private TabPage BuildLocationTab()
        {
            var tab = NewTab("Ubicacion");
            var stack = NewStack();

            stack.Controls.Add(NewHint(
                "Activa la ubicacion de Windows (servicio, interruptor, consentimiento de todos los perfiles y politicas) " +
                "y da permiso a los navegadores para que Zoho pueda hacer el check-in. Se aplica sin reiniciar."));

            _chkLockDown    = NewCheck("Impedir que el usuario desactive la ubicacion desde Configuracion (recomendado)", true);
            _chkLockDown.ForeColor = Color.FromArgb(120, 60, 0);
            _chkBrowsers    = NewCheck("Permitir la ubicacion en Chrome, Edge y Firefox sin preguntar (check-in de Zoho)", true);
            _chkGetPosition = NewCheck("Obtener coordenadas reales al verificar (tarda hasta 20 s; util en el piloto)", false);
            stack.Controls.Add(_chkLockDown);
            stack.Controls.Add(_chkBrowsers);
            stack.Controls.Add(_chkGetPosition);

            var activate = NewButton("ACTIVAR UBICACION",         Color.FromArgb(0, 120, 60),    Color.White);
            var audit    = NewButton("Auditar  (no cambia nada)", Color.FromArgb(230, 230, 230), Color.Black);
            var checkIn  = NewButton("Comprobar check-in Zoho",   Color.FromArgb(0, 90, 150),    Color.White);
            var rollback = NewButton("Revertir",                  Color.FromArgb(150, 40, 40),   Color.White);

            var tip = new ToolTip();
            tip.SetToolTip(activate,
                "Un solo clic: arranca el servicio de ubicacion, activa el interruptor, el consentimiento de todos los\n" +
                "usuarios, las politicas y el permiso de los navegadores; despues comprueba que el check-in funciona.");
            tip.SetToolTip(audit,    "Muestra el estado actual sin modificar nada.");
            tip.SetToolTip(checkIn,  "Recorre todo lo que necesita el check-in de Zoho y dice que falta. No modifica nada.");
            tip.SetToolTip(rollback, "Deshace los cambios de registro que hizo el toolkit en este equipo.");

            activate.Click += (s, e) => ActivateLocation();
            audit.Click    += async (s, e) => await Execute("location", reportOnly: true);
            checkIn.Click  += async (s, e) => await Execute("location", reportOnly: true, checkIn: true);
            rollback.Click += (s, e) => Rollback();

            stack.Controls.Add(NewButtonRow(activate, audit, checkIn, rollback));

            tab.Controls.Add(stack);
            return tab;
        }

        // -------------------------------------------------------------------
        //  Pestana Aplicaciones
        // -------------------------------------------------------------------
        private TabPage BuildAppsTab()
        {
            var tab = NewTab("Aplicaciones");
            tab.AutoScroll = false;

            _appsHint = NewHint("Aplicaciones del catalogo. Marca las que quieras comprobar o instalar.");

            _apps = new CheckedListBox
            {
                Dock = DockStyle.Fill,
                CheckOnClick = true,
                IntegralHeight = false,
                HorizontalScrollbar = true,
                Margin = new Padding(0, 0, 0, 4)
            };

            var refresh = NewButton("Recargar catalogo",      Color.FromArgb(230, 230, 230), Color.Black);
            var audit   = NewButton("Comprobar instaladas",   Color.FromArgb(230, 230, 230), Color.Black);
            var apply   = NewButton("INSTALAR SELECCIONADAS", Color.FromArgb(0, 120, 60),    Color.White);

            refresh.Click += async (s, e) => await RefreshApps();
            audit.Click   += async (s, e) => await Execute("apps", reportOnly: true);
            apply.Click   += async (s, e) => await Execute("apps", reportOnly: false);

            // Tres filas: texto (auto), lista (todo el resto), botones (auto).
            var grid = NewStack();
            grid.Dock = DockStyle.Fill;
            grid.AutoSize = false;
            grid.RowCount = 3;
            grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            grid.Controls.Add(_appsHint, 0, 0);
            grid.Controls.Add(_apps, 0, 1);
            grid.Controls.Add(NewButtonRow(refresh, audit, apply), 0, 2);

            tab.Controls.Add(grid);
            return tab;
        }

        private sealed class AppRow
        {
            public string Id, Name, Version;
            public bool Enabled;
            public override string ToString() =>
                Name + (string.IsNullOrEmpty(Version) || Version == "0.0.0" ? "" : "  v" + Version) +
                (Enabled ? "" : "   (fuera del despliegue automatico: enabled=false; se instala si la marcas)");
        }

        /// <summary>
        /// Lee las apps del catalogo con el mismo runspace de la pestana Usuarios.
        /// Se hace en PowerShell (ConvertFrom-Json) para no meter un parser JSON en el exe.
        /// </summary>
        private async Task RefreshApps()
        {
            SetBusy(true, "Leyendo catalogo de aplicaciones...");
            var rows = new List<AppRow>();
            string origin = null, error = null;

            await Task.Run(() =>
            {
                try
                {
                    var catalog = EmbeddedScripts.ReadCatalog(_args.ConfigPath, _args.SharePath, out origin);
                    var result = SharedHost().Invoke(
                        "param($Json) foreach ($a in ($Json | ConvertFrom-Json).apps) { " +
                        "[pscustomobject]@{ Id = [string]$a.id; Name = [string]$a.name; Version = [string]$a.version; Enabled = [bool]$a.enabled } }",
                        new Dictionary<string, object> { { "Json", catalog } });

                    foreach (var r in result)
                    {
                        if (r == null) continue;
                        rows.Add(new AppRow
                        {
                            Id      = Convert.ToString(r.Properties["Id"].Value),
                            Name    = Convert.ToString(r.Properties["Name"].Value),
                            Version = Convert.ToString(r.Properties["Version"].Value),
                            Enabled = Convert.ToBoolean(r.Properties["Enabled"].Value)
                        });
                    }
                }
                catch (Exception ex) { error = ex.Message; }
            });

            _apps.Items.Clear();
            foreach (var row in rows) _apps.Items.Add(row, row.Enabled);
            _appsLoaded = true;

            if (error != null)
            {
                _appsHint.Text = "No se pudo leer el catalogo: " + error;
                _appsHint.ForeColor = Color.Firebrick;
            }
            else
            {
                _appsHint.Text = "Catalogo: " + origin + "   ·   " + rows.Count + " aplicacion(es). Marca las que quieras comprobar o instalar.";
                _appsHint.ForeColor = Color.DimGray;
            }

            SetBusy(false, error == null ? "Catalogo cargado." : "Error leyendo el catalogo.");
        }

        private string[] SelectedApps()
        {
            var ids = new List<string>();
            foreach (var item in _apps.CheckedItems)
            {
                var row = item as AppRow;
                if (row != null) ids.Add(row.Id);
            }
            return ids.ToArray();
        }

        // -------------------------------------------------------------------
        //  Pestana Red (solo diagnostico: no modifica nada)
        // -------------------------------------------------------------------
        private TabPage BuildNetworkTab()
        {
            var tab = NewTab("Red");
            var stack = NewStack();

            stack.Controls.Add(NewHint(
                "Mide latencia, jitter y perdida contra los destinos del catalogo, resuelve DNS, prueba puertos TCP, " +
                "certificados TLS, MTU y proxy. No cambia nada en el equipo."));

            // Etiqueta + numero + pista en una fila que se parte si no cabe.
            var row = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = true, Margin = new Padding(0, 4, 0, 4)
            };
            _pingCount = new NumericUpDown
            {
                Width = 70, Minimum = 4, Maximum = 500, Value = 50,
                Margin = new Padding(6, 0, 10, 0)
            };
            row.Controls.Add(new Label { Text = "Pings por destino:", AutoSize = true, Margin = new Padding(0, 4, 0, 0) });
            row.Controls.Add(_pingCount);
            row.Controls.Add(new Label
            {
                Text = "(50 tarda ~1 min; baja a 10 para un vistazo rapido)",
                AutoSize = true, ForeColor = Color.DimGray, Margin = new Padding(0, 4, 0, 0)
            });
            stack.Controls.Add(row);

            var run = NewButton("EJECUTAR DIAGNOSTICO", Color.FromArgb(0, 90, 150), Color.White);
            run.Click += async (s, e) => await Execute("network", reportOnly: true);
            stack.Controls.Add(NewButtonRow(run));

            tab.Controls.Add(stack);
            return tab;
        }

        // -------------------------------------------------------------------
        //  Pestana Soporte: utilidades de un clic para el tecnico de L1.
        //  Cada boton llama a una funcion de Toolkit.Support.psm1 en el runspace
        //  compartido; no pasa por el orquestador porque son acciones sueltas.
        // -------------------------------------------------------------------
        private TabPage BuildSupportTab()
        {
            var tab = NewTab("Soporte");
            var stack = NewStack();

            var grey  = Color.FromArgb(230, 230, 230);
            var blue  = Color.FromArgb(0, 90, 150);
            var green = Color.FromArgb(0, 120, 60);
            var amber = Color.FromArgb(170, 95, 0);

            // --- Diagnostico ---
            stack.Controls.Add(NewSection("Diagnostico  (no cambia nada)"));
            var bInfo    = NewButton("Info del equipo",     grey, Color.Black);
            var bAudio   = NewButton("Audio y microfono",   grey, Color.Black);
            var bPrint   = NewButton("Impresoras",          grey, Color.Black);
            var bUpdate  = NewButton("Windows Update",      grey, Color.Black);
            var bTime    = NewButton("Hora del sistema",    grey, Color.Black);
            bInfo.Click   += async (s, e) => await RunSupport("Info del equipo",   "Get-SupportSummary | Out-Null");
            bAudio.Click  += async (s, e) => await RunSupport("Audio y microfono", "Test-AudioSetup | Out-Null");
            bPrint.Click  += async (s, e) => await RunSupport("Impresoras",        "Get-PrinterReport | Out-Null");
            bUpdate.Click += async (s, e) => await RunSupport("Windows Update",    "Get-UpdateStatus | Out-Null");
            bTime.Click   += async (s, e) => await RunSupport("Hora del sistema",  "Get-TimeStatus | Out-Null");
            stack.Controls.Add(NewButtonRow(bInfo, bAudio, bPrint, bUpdate, bTime));

            // --- Reparaciones rapidas ---
            stack.Controls.Add(NewSection("Reparaciones rapidas"));
            var bNet     = NewButton("Reparar red",                    blue, Color.White);
            var bNetDeep = NewButton("Reset de red (reinicia)",        amber, Color.White);
            var bAudioR  = NewButton("Reiniciar audio",                blue, Color.White);
            var bQueue   = NewButton("Limpiar cola de impresion",      blue, Color.White);
            var bSync    = NewButton("Sincronizar hora",               blue, Color.White);
            var bTemp    = NewButton("Limpiar temporales",             blue, Color.White);
            var bMedia   = NewButton("Permitir microfono y camara",    green, Color.White);
            var bPower   = NewButton("No suspender el equipo",         blue, Color.White);
            var bScan    = NewButton("Buscar actualizaciones",         blue, Color.White);
            var bSfc     = NewButton("Reparar archivos del sistema",   amber, Color.White);

            bNet.Click     += async (s, e) => await RunSupport("Reparar red", "Repair-Network | Out-Null",
                "Se vaciara la cache DNS y se renovara la IP por DHCP. La red se corta uno o dos segundos.");
            bNetDeep.Click += async (s, e) => await RunSupport("Reset de red", "Repair-Network -Deep | Out-Null",
                "Reset profundo: Winsock y pila TCP/IP. Deshace configuraciones de proxy/VPN raras.\n\nHABRA QUE REINICIAR EL EQUIPO al terminar.");
            bAudioR.Click  += async (s, e) => await RunSupport("Reiniciar audio", "Restart-AudioServices | Out-Null",
                "Se reiniciaran los servicios de audio. El sonido se corta unos segundos; el softphone puede necesitar reabrirse.");
            bQueue.Click   += async (s, e) => await RunSupport("Limpiar cola de impresion", "Clear-PrintQueue",
                "Se eliminaran TODOS los trabajos pendientes de todas las impresoras de este equipo.");
            bSync.Click    += async (s, e) => await RunSupport("Sincronizar hora", "Sync-SystemTime | Out-Null");
            bTemp.Click    += async (s, e) => await RunSupport("Limpiar temporales", "Clear-TempFiles | Out-Null",
                "Se borraran los archivos temporales de mas de 1 dia de todos los perfiles y de Windows, y se vaciara la papelera.");
            bMedia.Click   += async (s, e) => await RunSupport("Permitir microfono y camara", "Enable-MediaConsent | Out-Null",
                "Se permitira el microfono y la camara para el equipo, las apps de escritorio y todos los usuarios.\n\nReversible con 'Revertir' (pestana Ubicacion).");
            bPower.Click   += async (s, e) => await RunSupport("No suspender", "Set-NoSleepPower | Out-Null",
                "Con corriente, el equipo no se suspendera ni hibernara; la pantalla se apaga a los 15 min.\nSe desactiva la hibernacion (libera varios GB).");
            bScan.Click    += async (s, e) => await RunSupport("Buscar actualizaciones", "Start-UpdateScan | Out-Null",
                "Se pedira a Windows Update que busque, descargue e instale actualizaciones. Puede pedir reinicio mas tarde.");
            bSfc.Click     += async (s, e) => await RunSupport("Reparar archivos del sistema", "Repair-SystemFiles | Out-Null",
                "sfc /scannow tarda entre 5 y 20 minutos. No cierres el toolkit mientras tanto.");
            stack.Controls.Add(NewButtonRow(bNet, bNetDeep, bAudioR, bQueue, bSync, bTemp, bMedia, bPower, bScan, bSfc));

            // --- Reporte ---
            stack.Controls.Add(NewSection("Reporte"));
            var bReport = NewButton("Guardar reporte para ticket", green, Color.White);
            var bCopy   = NewButton("Copiar log",                  grey,  Color.Black);
            var bLogs   = NewButton("Abrir carpeta de logs",       grey,  Color.Black);
            bReport.Click += async (s, e) =>
            {
                var path = await RunSupport("Reporte para ticket",
                    "param($Root) Export-SupportReport -Root $Root",
                    parameters: new Dictionary<string, object> { { "Root", _args.Root } });
                if (!string.IsNullOrEmpty(path) && System.IO.File.Exists(path))
                {
                    try { System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + path + "\""); } catch { }
                }
            };
            bCopy.Click += (s, e) =>
            {
                try { Clipboard.SetText(_log.Text); _status.Text = "Log copiado al portapapeles."; }
                catch (Exception ex) { _status.Text = "No se pudo copiar: " + ex.Message; }
            };
            bLogs.Click += (s, e) =>
            {
                var dir = System.IO.Path.Combine(_args.Root, "logs");
                try { System.Diagnostics.Process.Start("explorer.exe", System.IO.Directory.Exists(dir) ? dir : _args.Root); } catch { }
            };
            stack.Controls.Add(NewButtonRow(bReport, bCopy, bLogs));

            tab.Controls.Add(stack);
            return tab;
        }

        private void ShowAbout()
        {
            using (var dlg = new AboutDialog()) dlg.ShowDialog(this);
        }

        private static Label NewSection(string text) =>
            new Label
            {
                Text = text, AutoSize = true,
                Font = new Font("Segoe UI", 9F, FontStyle.Bold),
                ForeColor = Color.FromArgb(32, 45, 66),
                Margin = new Padding(3, 8, 3, 2)
            };

        /// <summary>
        /// Ejecuta una accion de soporte en el runspace compartido. Con <paramref name="confirm"/>
        /// pide confirmacion antes (para las que cambian algo). Devuelve el ultimo
        /// valor de salida como texto (lo usa el reporte para abrir el archivo).
        /// </summary>
        private async Task<string> RunSupport(string title, string script, string confirm = null,
                                              IDictionary<string, object> parameters = null)
        {
            if (confirm != null)
            {
                var r = MessageBox.Show(this, confirm + "\n\n¿Continuar?", title,
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (r != DialogResult.Yes) return null;
            }

            SetBusy(true, title + "...");
            _log.Clear();
            string last = null, error = null;

            await Task.Run(() =>
            {
                try
                {
                    var res = SharedHost().Invoke(script, parameters);
                    if (res != null && res.Count > 0 && res[res.Count - 1] != null)
                        last = res[res.Count - 1].BaseObject?.ToString();
                }
                catch (Exception ex) { error = ex.Message; }
            });

            if (error != null)
            {
                Append(LogLevel.Error, "ERROR: " + error);
                SetBusy(false, title + ": error. Revisa el log.");
            }
            else
            {
                SetBusy(false, title + ": terminado.");
            }
            return last;
        }

        // -------------------------------------------------------------------
        //  Pestana Usuarios
        // -------------------------------------------------------------------
        private TabPage BuildUsersTab()
        {
            var tab = NewTab("Usuarios");
            tab.AutoScroll = false;

            _users = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                MultiSelect = false,
                HideSelection = false,
                GridLines = true,
                Margin = new Padding(0)
            };
            _users.Columns.Add("Usuario", 150);
            _users.Columns.Add("Estado", 95);
            _users.Columns.Add("Admin", 55);
            _users.Columns.Add("Contrasena", 100);
            _users.Columns.Add("Ultimo inicio", 115);
            _users.Columns.Add("Sesion", 70);
            _users.Columns.Add("Perfil", 220);
            _users.SelectedIndexChanged += (s, e) => UpdateUserButtons();
            _users.DoubleClick += (s, e) => { if (_btnUserPwd.Enabled) ChangePassword(); };
            // La ultima columna absorbe el ancho sobrante para no dejar un hueco gris.
            _users.Resize += (s, e) => StretchLastColumn(_users);

            // Botonera vertical: los botones se apilan y comparten anchura.
            var side = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false,
                Width = 182,
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom,   // alto = el de la fila; si no cabe, scroll
                AutoScroll = true,
                Margin = new Padding(8, 0, 0, 0)
            };
            Func<string, Color, Color, Button> mk = (text, back, fore) =>
            {
                var b = new Button
                {
                    Text = text, Width = 178, Height = 32,
                    BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat,
                    Font = new Font("Segoe UI", 9F, FontStyle.Bold),
                    Margin = new Padding(0, 0, 0, 6)
                };
                return b;
            };
            var grey  = Color.FromArgb(230, 230, 230);
            _btnUsersRefresh = mk("Actualizar lista",      grey, Color.Black);
            _btnUserNew      = mk("Nuevo usuario...",      Color.FromArgb(0, 120, 60), Color.White);
            _btnUserPwd      = mk("Cambiar contrasena...", grey, Color.Black);
            _btnUserNoPwd    = mk("Quitar contrasena",     grey, Color.Black);
            _btnUserToggle   = mk("Deshabilitar",          grey, Color.Black);
            _btnUserDelete   = mk("Eliminar usuario",      Color.FromArgb(150, 40, 40), Color.White);

            _btnUsersRefresh.Click += async (s, e) => await RefreshUsers();
            _btnUserNew.Click      += (s, e) => CreateUser();
            _btnUserPwd.Click      += (s, e) => ChangePassword();
            _btnUserNoPwd.Click    += (s, e) => ClearPassword();
            _btnUserToggle.Click   += (s, e) => ToggleEnabled();
            _btnUserDelete.Click   += (s, e) => DeleteUser();

            side.Controls.AddRange(new Control[] { _btnUsersRefresh, _btnUserNew, _btnUserPwd, _btnUserNoPwd, _btnUserToggle, _btnUserDelete });

            // Dos columnas: la lista se lleva todo el ancho, la botonera lo justo.
            var host = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Padding = new Padding(8) };
            host.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            host.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            host.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            host.Controls.Add(_users, 0, 0);
            host.Controls.Add(side, 1, 0);
            tab.Controls.Add(host);

            UpdateUserButtons();
            return tab;
        }

        private UserRow SelectedUser()
        {
            if (_users.SelectedItems.Count == 0) return null;
            return _users.SelectedItems[0].Tag as UserRow;
        }

        private void UpdateUserButtons()
        {
            var u = SelectedUser();
            var any = u != null;
            _btnUserPwd.Enabled    = any;
            _btnUserNoPwd.Enabled  = any && u.PasswordRequired;
            _btnUserToggle.Enabled = any && !u.IsCurrentUser;
            _btnUserToggle.Text    = (any && !u.Enabled) ? "Habilitar" : "Deshabilitar";
            _btnUserDelete.Enabled = any && !u.BuiltIn && !u.IsCurrentUser && !u.SessionOpen;
        }

        /// <summary>
        /// Runspace compartido por las pestanas Usuarios, Aplicaciones y Soporte
        /// (acciones sueltas que no pasan por el orquestador). Se abre una vez y
        /// se reutiliza: asi todo va al mismo archivo de log.
        /// </summary>
        private ScriptHost SharedHost()
        {
            if (_sharedHost == null)
            {
                var h = new ScriptHost();
                h.Output += (s, e) => Append(e.Level, e.Text);
                h.Open();
                h.Invoke("param($Root) Initialize-Toolkit -Root $Root",
                    new Dictionary<string, object> { { "Root", _args.Root } });
                _sharedHost = h;
            }
            return _sharedHost;
        }

        private async Task RefreshUsers()
        {
            SetBusy(true, "Leyendo cuentas locales...");
            var rows = new List<UserRow>();
            string error = null;

            await Task.Run(() =>
            {
                try
                {
                    foreach (var o in SharedHost().Invoke("Get-LocalUserInventory"))
                        if (o != null) rows.Add(ToRow(o));
                }
                catch (Exception ex) { error = ex.Message; }
            });

            _users.BeginUpdate();
            _users.Items.Clear();
            foreach (var u in rows)
            {
                var estado = u.LockedOut ? "BLOQUEADA" : (u.Enabled ? "Activa" : "Deshabilitada");
                var item = new ListViewItem(new[]
                {
                    u.Name + (u.IsCurrentUser ? "  (actual)" : ""),
                    estado,
                    u.IsAdmin ? "si" : "",
                    u.PasswordRequired ? "requerida" : "SIN contrasena",
                    u.LastLogon,
                    u.SessionOpen ? "ABIERTA" : (u.HasProfile ? "perfil" : "-"),
                    u.ProfilePath ?? ""
                }) { Tag = u };
                if (u.BuiltIn)       item.ForeColor = Color.Gray;
                else if (!u.Enabled) item.ForeColor = Color.FromArgb(160, 100, 0);
                _users.Items.Add(item);
            }
            _users.EndUpdate();
            _usersLoaded = true;
            UpdateUserButtons();

            SetBusy(false, error != null ? "Error leyendo cuentas: " + error : rows.Count + " cuenta(s) local(es).");
            if (error != null)
                MessageBox.Show(this, error, "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private static UserRow ToRow(PSObject o)
        {
            var r = new UserRow
            {
                Name             = Prop(o, "Name"),
                FullName         = Prop(o, "FullName"),
                Sid              = Prop(o, "Sid"),
                ProfilePath      = Prop(o, "ProfilePath"),
                Enabled          = PropBool(o, "Enabled"),
                LockedOut        = PropBool(o, "LockedOut"),
                IsAdmin          = PropBool(o, "IsAdmin"),
                PasswordRequired = PropBool(o, "PasswordRequired"),
                BuiltIn          = PropBool(o, "BuiltIn"),
                SessionOpen      = PropBool(o, "SessionOpen"),
                IsCurrentUser    = PropBool(o, "IsCurrentUser"),
                HasProfile       = PropBool(o, "HasProfile")
            };
            var ll = o.Properties["LastLogon"];
            r.LastLogon = (ll != null && ll.Value is DateTime) ? ((DateTime)ll.Value).ToString("yyyy-MM-dd HH:mm") : "nunca";
            return r;
        }

        private static string Prop(PSObject o, string name)
        {
            var p = o.Properties[name];
            return (p == null || p.Value == null) ? "" : p.Value.ToString();
        }

        private static bool PropBool(PSObject o, string name)
        {
            var p = o.Properties[name];
            return p != null && p.Value is bool && (bool)p.Value;
        }

        private async void ChangePassword()
        {
            var u = SelectedUser(); if (u == null) return;
            using (var dlg = new PasswordDialog("Cambiar contrasena", u.Name))
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                await RunUserAction("Cambiando contrasena de " + u.Name + "...",
                    "param($Name, $Password) Set-LocalUserPassword -Name $Name -Password $Password",
                    new Dictionary<string, object> { { "Name", u.Name }, { "Password", dlg.Password } });
            }
        }

        private async void ClearPassword()
        {
            var u = SelectedUser(); if (u == null) return;
            var ok = MessageBox.Show(this,
                "La cuenta '" + u.Name + "' quedara SIN contrasena: cualquiera podra iniciar sesion en este equipo con ella.\n\n" +
                "(Windows no permite usar cuentas sin contrasena por red ni por escritorio remoto.)\n\n¿Continuar?",
                "Quitar contrasena", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (ok != DialogResult.Yes) return;
            await RunUserAction("Quitando contrasena de " + u.Name + "...",
                "param($Name) Clear-LocalUserPassword -Name $Name",
                new Dictionary<string, object> { { "Name", u.Name } });
        }

        private async void ToggleEnabled()
        {
            var u = SelectedUser(); if (u == null) return;
            var fn = u.Enabled ? "Disable-LocalUserAccount" : "Enable-LocalUserAccount";
            await RunUserAction((u.Enabled ? "Deshabilitando " : "Habilitando ") + u.Name + "...",
                "param($Name) " + fn + " -Name $Name",
                new Dictionary<string, object> { { "Name", u.Name } });
        }

        private async void DeleteUser()
        {
            var u = SelectedUser(); if (u == null) return;
            var text = "Se va a ELIMINAR la cuenta '" + u.Name + "'. Esta accion no se puede deshacer.\n\n";
            bool removeProfile = false;
            if (u.HasProfile)
            {
                text += "¿Eliminar tambien su carpeta de perfil?\n    " + u.ProfilePath + "\n\n" +
                        "Si = cuenta + carpeta     No = solo la cuenta     Cancelar = no hacer nada";
                var r = MessageBox.Show(this, text, "Eliminar usuario", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Warning);
                if (r == DialogResult.Cancel) return;
                removeProfile = (r == DialogResult.Yes);
            }
            else
            {
                if (MessageBox.Show(this, text + "¿Continuar?", "Eliminar usuario", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            }
            await RunUserAction("Eliminando " + u.Name + "...",
                "param($Name, $RemoveProfile) Remove-LocalUserAccount -Name $Name -RemoveProfile:$RemoveProfile",
                new Dictionary<string, object> { { "Name", u.Name }, { "RemoveProfile", removeProfile } });
        }

        private async void CreateUser()
        {
            using (var dlg = new NewUserDialog())
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                await RunUserAction("Creando " + dlg.UserName + "...",
                    "param($Name, $Password, $FullName, $NoPassword, $Administrator, $NeverExpires) " +
                    "New-LocalUserAccount -Name $Name -Password $Password -FullName $FullName " +
                    "-NoPassword:$NoPassword -Administrator:$Administrator -PasswordNeverExpires:$NeverExpires",
                    new Dictionary<string, object>
                    {
                        { "Name", dlg.UserName }, { "Password", dlg.Password }, { "FullName", dlg.FullName },
                        { "NoPassword", dlg.NoPassword }, { "Administrator", dlg.Administrator },
                        { "NeverExpires", dlg.PasswordNeverExpires }
                    });
            }
        }

        /// <summary>
        /// Ejecuta una accion de Toolkit.Users.psm1. Todas devuelven {Success, Message}
        /// en vez de lanzar, para que el error llegue al tecnico en claro.
        /// </summary>
        private async Task RunUserAction(string busyText, string script, Dictionary<string, object> parameters)
        {
            SetBusy(true, busyText);
            bool success = false;
            string message = "Sin respuesta del modulo.";

            await Task.Run(() =>
            {
                try
                {
                    var res = SharedHost().Invoke(script, parameters);
                    var r = res.FirstOrDefault(x => x != null && x.Properties["Success"] != null);
                    if (r != null)
                    {
                        success = PropBool(r, "Success");
                        message = Prop(r, "Message");
                    }
                }
                catch (Exception ex) { message = ex.Message; }
            });

            SetBusy(false, message);
            if (!success)
                MessageBox.Show(this, message, "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);

            await RefreshUsers();
        }

        // -------------------------------------------------------------------
        //  Ejecucion de modulos (orquestador embebido)
        // -------------------------------------------------------------------
        // Layout fluido: nada de coordenadas fijas. Cada pestana es una pila vertical
        // (TableLayoutPanel de una columna) que se adapta al ancho; si el alto no
        // alcanza, la pestana muestra scroll en vez de recortar.

        private static TabPage NewTab(string title) =>
            new TabPage(title) { BackColor = Color.FromArgb(243, 243, 243), AutoScroll = true, Padding = new Padding(0) };

        private static TableLayoutPanel NewStack()
        {
            var t = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 1,
                Padding = new Padding(12, 10, 12, 4)
            };
            // Columna al 100 %: es lo que permite que las etiquetas se ajusten al ancho.
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            return t;
        }

        /// <summary>Texto explicativo: ocupa el ancho disponible y se parte en lineas.</summary>
        private static Label NewHint(string text) =>
            new Label
            {
                Text = text,
                AutoSize = true,
                Anchor = AnchorStyles.Left | AnchorStyles.Right,   // en un TableLayoutPanel, esto = "ajusta y envuelve"
                ForeColor = Color.DimGray,
                Margin = new Padding(3, 0, 3, 10)
            };

        private static CheckBox NewCheck(string text, bool chk) =>
            new CheckBox { Text = text, Checked = chk, AutoSize = true, Margin = new Padding(3, 2, 3, 2) };

        /// <summary>Boton que se dimensiona por su texto (asi no se recorta con otra fuente o DPI).</summary>
        private Button NewButton(string text, Color back, Color fore)
        {
            var b = new Button
            {
                Text = text,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                MinimumSize = new Size(110, 34),
                Padding = new Padding(10, 0, 10, 0),
                BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9F, FontStyle.Bold),
                Margin = new Padding(0, 0, 10, 6)
            };
            _actionButtons.Add(b);
            return b;
        }

        /// <summary>Fila de botones que pasa a dos lineas cuando la ventana es estrecha.</summary>
        private static FlowLayoutPanel NewButtonRow(params Button[] buttons)
        {
            var row = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = true,
                Anchor = AnchorStyles.Left | AnchorStyles.Right,
                Margin = new Padding(0, 8, 0, 0)
            };
            row.Controls.AddRange(buttons);
            return row;
        }

        private static void StretchLastColumn(ListView list)
        {
            if (list.Columns.Count == 0) return;
            int used = 0;
            for (int i = 0; i < list.Columns.Count - 1; i++) used += list.Columns[i].Width;
            var last = list.Columns[list.Columns.Count - 1];
            var free = list.ClientSize.Width - used;
            if (free > 120) last.Width = free;
        }

        /// <summary>
        /// Boton ACTIVAR UBICACION: aplica todo (servicio, interruptor, consentimiento,
        /// politicas, navegadores) y, si fue bien, encadena la comprobacion del check-in
        /// para que el tecnico vea el veredicto final sin pulsar nada mas.
        /// </summary>
        private async void ActivateLocation()
        {
            var code = await Execute("location", reportOnly: false);
            if (code != 0 && code != Program.ExitRebootNeeded) return;   // cancelado o fallo: ya se aviso

            Append(LogLevel.Info, "");
            Append(LogLevel.Info, "Ubicacion activada. Comprobando ahora que el check-in de Zoho funciona...");
            await Execute("location", reportOnly: true, checkIn: true, keepLog: true);
        }

        private const int ExitCancelled = -1;

        /// <summary>
        /// Ejecuta UN modulo del orquestador con las opciones de su pestana.
        /// Devuelve el codigo de salida (o ExitCancelled si el usuario no confirmo).
        /// </summary>
        private async Task<int> Execute(string module, bool reportOnly, bool checkIn = false, bool keepLog = false)
        {
            string[] apps = null;
            if (module == "apps")
            {
                apps = SelectedApps();
                if (apps.Length == 0)
                {
                    MessageBox.Show("Marca al menos una aplicacion de la lista.", "Toolkit",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return ExitCancelled;
                }
            }

            if (!reportOnly)
            {
                string what;
                switch (module)
                {
                    case "location":
                        what = "Se va a activar la ubicacion en este equipo (servicio, registro y politicas)." +
                               (_chkLockDown.Checked ? "\nEl usuario NO podra desactivarla desde Configuracion." : "") +
                               (_chkBrowsers.Checked ? "\nChrome, Edge y Firefox entregaran la ubicacion a los sitios sin preguntar." : "") +
                               "\n\nLos cambios de registro quedan registrados y son reversibles con 'Revertir'.";
                        break;
                    case "apps":
                        what = "Se van a instalar en silencio:\n\n  · " + string.Join("\n  · ", apps) +
                               "\n\nLa instalacion de aplicaciones NO se deshace con 'Revertir'.";
                        break;
                    default:
                        what = "Se va a ejecutar el modulo '" + module + "'.";
                        break;
                }
                var confirm = MessageBox.Show(what + "\n\n¿Continuar?",
                    "Confirmar", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (confirm != DialogResult.Yes) return ExitCancelled;
            }

            // Las opciones se leen aqui, en el hilo de la UI, antes de irse al hilo de trabajo.
            var options = new RunOptions
            {
                Modules     = new[] { module },
                Apps        = apps,
                SharePath   = _args.SharePath,
                Root        = _args.Root,
                ReportOnly  = reportOnly,
                Silent      = false,
                NoLockDown  = !_chkLockDown.Checked,
                NoBrowsers  = !_chkBrowsers.Checked,
                CheckIn     = checkIn,
                GetPosition = _chkGetPosition.Checked,
                PingCount   = (int)_pingCount.Value,
                // El tecnico esta delante: no tiene sentido aplazar a la ventana nocturna.
                IgnoreMaintenanceWindow = true
            };

            SetBusy(true, checkIn ? "Comprobando el check-in de Zoho..." : reportOnly ? "Auditando..." : "Aplicando cambios...");
            if (!keepLog) _log.Clear();

            var exitCode = await Task.Run(() =>
            {
                try
                {
                    using (var host = new ScriptHost())
                    {
                        host.Output += (s, e) => Append(e.Level, e.Text);
                        host.Open();

                        string origin;
                        options.CatalogJson = EmbeddedScripts.ReadCatalog(_args.ConfigPath, _args.SharePath, out origin);
                        Append(LogLevel.Debug, "Catalogo: " + origin);

                        return host.Run(options);
                    }
                }
                catch (Exception ex)
                {
                    Append(LogLevel.Error, "ERROR: " + ex.Message);
                    return Program.ExitGeneric;
                }
            });

            var verdict = checkIn
                ? (exitCode == 0 ? "Check-in de Zoho: el equipo esta listo." : "Check-in de Zoho: NO va a funcionar todavia.")
                : DescribeExit(exitCode);
            SetBusy(false, verdict);

            if (exitCode != 0 && exitCode != Program.ExitRebootNeeded)
            {
                MessageBox.Show(verdict + "\n\nRevisa el log para el detalle.",
                    "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            return exitCode;
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
                            new Dictionary<string, object> { { "Root", _args.Root } });
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
            foreach (var b in _actionButtons) b.Enabled = !busy;
            _apps.Enabled = !busy;
            _btnUsersRefresh.Enabled = _btnUserNew.Enabled = !busy;
            if (busy)
                _btnUserPwd.Enabled = _btnUserNoPwd.Enabled = _btnUserToggle.Enabled = _btnUserDelete.Enabled = false;
            else
                UpdateUserButtons();
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
