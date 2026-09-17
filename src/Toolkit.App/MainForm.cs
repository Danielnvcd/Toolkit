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
    /// Interfaz para el técnico en sitio. Misma lógica que el modo desatendido:
    /// por debajo llama al mismo Invoke-ToolkitRun.ps1 embebido, de modo que
    /// GUI y despliegue masivo no pueden divergir.
    ///
    /// Cada módulo tiene su propia página (Ubicación, Aplicaciones, Red, Soporte,
    /// Usuarios) con sus opciones y sus botones: el técnico ejecuta una cosa
    /// cada vez y ve en la salida de abajo solo lo que pidió.
    ///
    /// La página "Usuarios" es la excepción deliberada: cambiar contraseñas o
    /// borrar cuentas es interactivo por naturaleza y no se despliega en masa.
    /// Llama directamente a las funciones de Toolkit.Users.psm1.
    /// </summary>
    public sealed class MainForm : Form
    {
        private readonly CommandLineArgs _args;

        private RichTextBox _log;
        private Label _status, _elapsed;
        private PictureBox _statusIcon;
        private Button _btnCancel;
        private ProgressBar _progress;
        private SplitContainer _split;
        private Timer _clock;
        private DateTime _busySince;
        private bool _busy;

        // Navegación: una fila de botones arriba y una página visible cada vez.
        private FlowLayoutPanel _nav;
        private Panel _content;
        private readonly List<Button> _navButtons = new List<Button>();
        private readonly List<Panel> _pages = new List<Panel>();
        private int _pageApps = -1, _pageUsers = -1;

        // Botones que lanzan una ejecución; se bloquean todos mientras hay una en curso.
        private readonly List<Button> _actionButtons = new List<Button>();

        // Página Ubicación
        private CheckBox _chkLockDown, _chkBrowsers, _chkGetPosition;

        // Página Aplicaciones
        private CheckedListBox _apps;
        private Label _appsHint;
        private bool _appsLoaded;

        // Página Red
        private NumericUpDown _pingCount;

        // Página Usuarios
        private ListView _users;
        private Button _btnUsersRefresh, _btnUserNew, _btnUserPwd, _btnUserNoPwd, _btnUserToggle, _btnUserDelete;
        private bool _usersLoaded;

        // Runspace único para toda la ventana. Se abre en segundo plano nada más
        // mostrarse el formulario (ver Load) para que el primer clic no pague el
        // arranque (runspace + 6 módulos + Initialize-Toolkit: 1.5-2.5 s).
        private Task<ScriptHost> _hostTask;
        private readonly object _hostLock = new object();

        // Log de la GUI por lotes: los scripts emiten cientos de líneas seguidas y
        // repintar el RichTextBox una a una (BeginInvoke + AppendText + ScrollToCaret)
        // congela la ventana. Se encolan y se vuelcan de una vez en el hilo de la UI.
        private readonly Queue<KeyValuePair<LogLevel, string>> _pendingLog = new Queue<KeyValuePair<LogLevel, string>>();
        private int _flushScheduled;

        private const string PrepMessage = "Preparando módulos...";

        private sealed class UserRow
        {
            public string Name, FullName, Sid, ProfilePath, LastLogon;
            public bool Enabled, LockedOut, IsAdmin, PasswordRequired, BuiltIn, SessionOpen, IsCurrentUser, HasProfile;
        }

        public MainForm(CommandLineArgs args)
        {
            _args = args;
            BuildUi();
            WindowPlacement.Restore(this, _split);
            FormClosing += (s, e) => WindowPlacement.Save(this, _split);
            FormClosed += (s, e) =>
            {
                Task<ScriptHost> t;
                lock (_hostLock) t = _hostTask;
                if (t != null && t.Status == TaskStatus.RanToCompletion)
                {
                    try { t.Result.Dispose(); } catch { }
                }
            };
        }

        private void BuildUi()
        {
            // Escalado DPI: el manifiesto declara la app PerMonitorV2, así que Windows
            // NO la estira. Todas las medidas de este archivo son a 96 ppp y WinForms
            // las multiplica al 125 %/150 %... PERO solo si el layout está suspendido
            // cuando se asigna AutoScaleDimensions: si no, escala en ese instante (con
            // el formulario vacío) y los controles que se añaden después se quedan a
            // 96 ppp con el texto grande. Es el mismo patrón que genera el diseñador:
            // SuspendLayout -> construir -> ResumeLayout + PerformLayout.
            SuspendLayout();
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);

            Text = Program.AppName;
            if (EmbeddedScripts.AppIcon != null) Icon = EmbeddedScripts.AppIcon;
            Font = Theme.Body;
            BackColor = Theme.Window;
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(760, 540);

            // Orden de dock (se procesa del último al primero): barra de estado abajo,
            // progreso justo encima, cabecera arriba y el resto para el cuerpo.
            var split = BuildSplit(); var header = BuildHeader(); var status = BuildStatusBar();
            Controls.AddRange(new Control[] { split, header, _progress, status });

            ResumeLayout(false);
            PerformLayout();   // aquí se escala todo a la vez

            // Tamaño inicial (ya en píxeles de dispositivo): el preferido, pero nunca
            // más grande que la pantalla (portátiles de 1366x768 con la barra de
            // tareas, monitores pequeños...).
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Size = new Size(Math.Min(Theme.Px(1000), area.Width - 40),
                            Math.Min(Theme.Px(740),  area.Height - 40));

            // La distancia del separador se fija cuando el formulario ya tiene su
            // tamaño real (escalado DPI incluido); antes, WinForms la recorta.
            Load += (s, e) =>
            {
                if (!WindowPlacement.HasSavedSplitter)
                {
                    // 420 px lógicos (cabe la página Soporte entera), pero nunca más del 62 % de la altura.
                    var want = Math.Min(Theme.Px(420), (int)(_split.Height * 0.62));
                    want = Math.Max(_split.Panel1MinSize, Math.Min(want, _split.Height - _split.Panel2MinSize - _split.SplitterWidth));
                    try { _split.SplitterDistance = want; } catch (ArgumentException) { }
                }
                SelectPage(0);
                WarmUpHost();
            };

            Append(LogLevel.Info,  Program.AppName + " v" + Program.AppVersion() + " — los scripts van embebidos en este ejecutable.");
            Append(LogLevel.Debug, "Auditar evalúa el equipo sin modificar nada. Empieza siempre por ahí.");
        }

        // -------------------------------------------------------------------
        //  Cabecera: logo de la empresa, equipo/usuario y "Acerca de"
        // -------------------------------------------------------------------
        private Control BuildHeader()
        {
            // Fondo blanco porque el logo (texto negro sobre transparente) está hecho para eso.
            var header = new Panel { Dock = DockStyle.Top, Height = 58, BackColor = Theme.Surface };
            var logo = new PictureBox
            {
                Dock = DockStyle.Left, SizeMode = PictureBoxSizeMode.Zoom,
                Margin = new Padding(0), Padding = new Padding(16, 8, 0, 8), Cursor = Cursors.Hand
            };
            var img = EmbeddedScripts.CompanyLogo;
            if (img != null)
            {
                logo.Image = img;
                logo.Width = (int)Math.Round(img.Width * (header.Height - 16) / (double)img.Height) + logo.Padding.Horizontal;
            }
            else logo.Width = 0;
            logo.Click += (s, e) => ShowAbout();

            var about = Theme.MakeButton("Acerca de", Theme.ButtonKind.Secondary, Theme.GlyphInfo);
            about.FlatAppearance.BorderSize = 0;
            about.BackColor = Theme.Surface;
            about.Dock = DockStyle.Right;
            about.AutoSize = false;
            about.Width = 118;
            about.Margin = new Padding(0);
            about.Click += (s, e) => ShowAbout();

            var machine = new Label
            {
                Text = Environment.MachineName + "   ·   " + Environment.UserName + "   ·   v" + Program.AppVersion(),
                Dock = DockStyle.Fill, AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleRight,
                Padding = new Padding(8, 0, 12, 0),
                Font = Theme.Body, ForeColor = Theme.TextMuted
            };
            header.Controls.AddRange(new Control[] { machine, about, logo, Theme.Rule(DockStyle.Bottom) });
            return header;
        }

        // -------------------------------------------------------------------
        //  Cuerpo: páginas arriba, salida abajo, separador arrastrable
        // -------------------------------------------------------------------
        private Control BuildSplit()
        {
            // --- Panel superior: tarjeta blanca con la navegación y la página activa ---
            _nav = new FlowLayoutPanel
            {
                Dock = DockStyle.Top, Height = 46, BackColor = Theme.Surface,
                Padding = new Padding(8, 4, 8, 0), WrapContents = false
            };
            // Subrayado de acento bajo el botón de la página activa.
            _nav.Paint += (s, e) =>
            {
                var sel = _navButtons.FirstOrDefault(b => b.Tag is bool && (bool)b.Tag);
                if (sel == null) return;
                using (var br = new SolidBrush(Theme.Accent))
                    e.Graphics.FillRectangle(br, sel.Left + Theme.Px(8), _nav.Height - Theme.Px(3), sel.Width - Theme.Px(16), Theme.Px(3));
            };
            _content = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface };

            AddPage("Ubicación",    Theme.GlyphLocation, BuildLocationPage());
            _pageApps  = AddPage("Aplicaciones", Theme.GlyphApps, BuildAppsPage());
            AddPage("Red",          Theme.GlyphNetwork,  BuildNetworkPage());
            AddPage("Soporte",      Theme.GlyphSupport,  BuildSupportPage());
            _pageUsers = AddPage("Usuarios", Theme.GlyphUsers, BuildUsersPage());

            var card = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface, Padding = new Padding(1) };
            card.Paint += (s, e) => ControlPaint.DrawBorder(e.Graphics, card.ClientRectangle, Theme.Border, ButtonBorderStyle.Solid);
            card.Controls.Add(_content);
            card.Controls.Add(Theme.Rule(DockStyle.Top));
            card.Controls.Add(_nav);

            // --- Panel inferior: cabecera "Salida" con sus botones y el log ---
            _log = new RichTextBox
            {
                Dock = DockStyle.Fill, ReadOnly = true,
                BackColor = Theme.LogBack, ForeColor = Theme.LogText,
                Font = Theme.Mono, BorderStyle = BorderStyle.None,
                WordWrap = false, ScrollBars = RichTextBoxScrollBars.Both,
                DetectUrls = false
            };
            var logPad = new Panel { Dock = DockStyle.Fill, BackColor = Theme.LogBack, Padding = new Padding(10, 8, 4, 6) };
            logPad.Controls.Add(_log);

            var logHead = new Panel { Dock = DockStyle.Top, Height = 36, BackColor = Theme.Surface };
            var logTitle = new Label
            {
                Text = "Salida", Dock = DockStyle.Left, Width = 90, Font = Theme.Section, ForeColor = Theme.Text,
                TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(12, 0, 0, 0)
            };
            var logTools = new FlowLayoutPanel
            {
                Dock = DockStyle.Right, FlowDirection = FlowDirection.RightToLeft, AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(0, 4, 6, 0), WrapContents = false
            };
            var bLogs  = SmallTool("Abrir carpeta de logs", Theme.GlyphFolder);
            var bClear = SmallTool("Limpiar", Theme.GlyphClear);
            var bCopy  = SmallTool("Copiar", Theme.GlyphCopy);
            bCopy.Click += (s, e) =>
            {
                try { Clipboard.SetText(_log.Text); SetStatus(StatusKind.Info, "Salida copiada al portapapeles."); }
                catch (Exception ex) { SetStatus(StatusKind.Error, "No se pudo copiar: " + ex.Message); }
            };
            bClear.Click += (s, e) => _log.Clear();
            bLogs.Click += (s, e) =>
            {
                var dir = System.IO.Path.Combine(_args.Root, "logs");
                try { System.Diagnostics.Process.Start("explorer.exe", System.IO.Directory.Exists(dir) ? dir : _args.Root); } catch { }
            };
            logTools.Controls.AddRange(new Control[] { bLogs, bClear, bCopy });
            logHead.Controls.AddRange(new Control[] { logTitle, logTools });

            var logCard = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface, Padding = new Padding(1) };
            logCard.Paint += (s, e) => ControlPaint.DrawBorder(e.Graphics, logCard.ClientRectangle, Theme.Border, ButtonBorderStyle.Solid);
            logCard.Controls.Add(logPad);
            logCard.Controls.Add(logHead);

            // Panel1 es el fijo: al agrandar la ventana, el espacio extra va al log.
            _split = new SplitContainer
            {
                Dock = DockStyle.Fill, Orientation = Orientation.Horizontal,
                FixedPanel = FixedPanel.Panel1, SplitterWidth = 10,
                Panel1MinSize = Theme.Px(160), Panel2MinSize = Theme.Px(100), BackColor = Theme.Window
            };
            _split.Panel1.Padding = new Padding(16, 12, 16, 0);
            _split.Panel2.Padding = new Padding(16, 0, 16, 12);
            _split.Panel1.Controls.Add(card);
            _split.Panel2.Controls.Add(logCard);
            // Pista visual de que el separador se puede arrastrar.
            _split.Paint += (s, e) =>
            {
                var r = _split.SplitterRectangle;
                using (var pen = new Pen(Theme.Border, 2))
                {
                    int cx = r.Left + r.Width / 2, cy = r.Top + r.Height / 2;
                    e.Graphics.DrawLine(pen, cx - Theme.Px(18), cy, cx + Theme.Px(18), cy);
                }
            };
            return _split;
        }

        /// <summary>Botón discreto de la cabecera del log (sin borde, se ilumina al pasar).</summary>
        private static Button SmallTool(string text, string glyph)
        {
            var b = Theme.MakeButton(text, Theme.ButtonKind.Secondary, glyph);
            b.FlatAppearance.BorderSize = 0;
            b.Font = Theme.Small;
            b.MinimumSize = new Size(0, 28);
            b.Margin = new Padding(4, 0, 0, 0);
            return b;
        }

        private int AddPage(string title, string glyph, Panel page)
        {
            int index = _pages.Count;
            var b = new Button
            {
                Text = title, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                FlatStyle = FlatStyle.Flat, BackColor = Theme.Surface, ForeColor = Theme.TextMuted,
                Font = Theme.Body, Padding = new Padding(8, 0, 10, 0), Margin = new Padding(0, 0, 2, 0),
                MinimumSize = new Size(0, 38), Cursor = Cursors.Hand, Tag = false,
                Image = Theme.Glyph(glyph, Theme.TextMuted), ImageAlign = ContentAlignment.MiddleLeft,
                TextImageRelation = TextImageRelation.ImageBeforeText, TextAlign = ContentAlignment.MiddleLeft,
                UseVisualStyleBackColor = false
            };
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = Theme.Hover;
            b.FlatAppearance.MouseDownBackColor = Theme.Hover;
            b.Click += (s, e) => SelectPage(index);
            _navButtons.Add(b);
            _nav.Controls.Add(b);

            page.Dock = DockStyle.Fill;
            page.Visible = false;
            _pages.Add(page);
            _content.Controls.Add(page);
            return index;
        }

        private readonly string[] _pageGlyphs = { Theme.GlyphLocation, Theme.GlyphApps, Theme.GlyphNetwork, Theme.GlyphSupport, Theme.GlyphUsers };

        private async void SelectPage(int index)
        {
            for (int i = 0; i < _pages.Count; i++)
            {
                bool on = i == index;
                _pages[i].Visible = on;
                var b = _navButtons[i];
                b.Tag = on;
                b.ForeColor = on ? Theme.Accent : Theme.TextMuted;
                b.Font = on ? Theme.BodyBold : Theme.Body;
                b.Image = Theme.Glyph(_pageGlyphs[i], on ? Theme.Accent : Theme.TextMuted);
            }
            _nav.Invalidate();

            // Las listas se cargan la primera vez que se abre la página: no tiene
            // sentido pagarlo al arrancar. Con algo en curso no se lanza otra
            // ejecución sobre el mismo runspace; se cargará al volver a la página.
            if (_busy) return;
            if (index == _pageUsers && !_usersLoaded) await RefreshUsers();
            if (index == _pageApps  && !_appsLoaded)  await RefreshApps();
        }

        // -------------------------------------------------------------------
        //  Barra de estado: icono, texto, tiempo transcurrido y Cancelar
        // -------------------------------------------------------------------
        private Control BuildStatusBar()
        {
            var bar = new Panel { Dock = DockStyle.Bottom, Height = 42, BackColor = Theme.Window };
            _statusIcon = new PictureBox
            {
                Dock = DockStyle.Left, Width = 34, SizeMode = PictureBoxSizeMode.CenterImage,
                Padding = new Padding(16, 0, 0, 0)
            };
            _status = new Label
            {
                Dock = DockStyle.Fill, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Theme.Text, Font = Theme.Body, Padding = new Padding(4, 0, 0, 0)
            };
            _elapsed = new Label
            {
                Dock = DockStyle.Right, Width = 60, TextAlign = ContentAlignment.MiddleRight,
                ForeColor = Theme.TextMuted, Font = Theme.Mono, Visible = false
            };
            _btnCancel = Theme.MakeButton("Cancelar", Theme.ButtonKind.Danger, Theme.GlyphStop);
            _btnCancel.Dock = DockStyle.Right;
            _btnCancel.AutoSize = false;
            _btnCancel.Width = 112;
            _btnCancel.Margin = new Padding(0);
            _btnCancel.Visible = false;
            _btnCancel.Click += (s, e) => CancelCurrent();
            var cancelHost = new Panel { Dock = DockStyle.Right, Width = 112 + 16, Padding = new Padding(8, 4, 16, 4) };
            cancelHost.Controls.Add(_btnCancel);

            bar.Controls.AddRange(new Control[] { _status, _statusIcon, _elapsed, cancelHost, Theme.Rule(DockStyle.Top) });

            _progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 3, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 25, Visible = false };

            _clock = new Timer { Interval = 1000 };
            _clock.Tick += (s, e) => _elapsed.Text = (DateTime.Now - _busySince).ToString(@"m\:ss");

            SetStatus(StatusKind.Info, "Listo.");
            return bar;
        }

        private enum StatusKind { Info, Ok, Busy, Warn, Error }

        private void SetStatus(StatusKind kind, string text)
        {
            string glyph; Color color;
            switch (kind)
            {
                case StatusKind.Ok:    glyph = Theme.GlyphOk;      color = Theme.Ok;     break;
                case StatusKind.Busy:  glyph = Theme.GlyphClock;   color = Theme.Accent; break;
                case StatusKind.Warn:  glyph = Theme.GlyphWarning; color = Theme.Warn;   break;
                case StatusKind.Error: glyph = Theme.GlyphError;   color = Theme.Danger; break;
                default:               glyph = Theme.GlyphInfo;    color = Theme.Accent; break;
            }
            _statusIcon.Image = Theme.Glyph(glyph, color, 18);
            _status.Text = text;
        }

        /// <summary>
        /// Arranca el runspace compartido en segundo plano mientras el técnico mira
        /// la ventana. Los botones siguen activos: si pulsa uno antes de que termine,
        /// SharedHost() simplemente espera a que acabe (en el hilo de trabajo).
        /// </summary>
        private async void WarmUpHost()
        {
            SetStatus(StatusKind.Busy, PrepMessage);
            _progress.Visible = true;
            string error = null;
            try { await StartHost(); }
            catch (Exception ex) { error = ex.Message; }
            // Si mientras tanto ya hay una acción en marcha, no pisar su estado.
            if (!_busy)
            {
                _progress.Visible = false;
                if (error == null) SetStatus(StatusKind.Info, "Listo.");
                else SetStatus(StatusKind.Error, "No se pudieron cargar los módulos: " + error);
            }
        }

        private Task<ScriptHost> StartHost()
        {
            lock (_hostLock)
            {
                if (_hostTask == null || _hostTask.IsFaulted)
                {
                    _hostTask = Task.Run(() =>
                    {
                        var h = new ScriptHost();
                        h.Output += (s, e) => Append(e.Level, e.Text);
                        h.Open();
                        h.Invoke("param($Root) Initialize-Toolkit -Root $Root",
                            new Dictionary<string, object> { { "Root", _args.Root } });
                        return h;
                    });
                }
                return _hostTask;
            }
        }

        /// <summary>
        /// Runspace compartido por TODA la ventana: orquestador (Ubicación, Apps,
        /// Red), Soporte y Usuarios. Se abre una vez (en segundo plano, al cargar
        /// el formulario) y se reutiliza. Bloquea hasta que esté listo: llamar
        /// siempre desde un hilo de trabajo (Task.Run), nunca desde el de la UI.
        /// </summary>
        private ScriptHost SharedHost()
        {
            return StartHost().GetAwaiter().GetResult();
        }

        private void CancelCurrent()
        {
            Task<ScriptHost> t;
            lock (_hostLock) t = _hostTask;
            if (t == null || t.Status != TaskStatus.RanToCompletion) return;
            if (!Dialogs.Confirm(this, "Cancelar la operación",
                "Se detendrá la operación en curso.\n\nSi estaba aplicando cambios, pueden quedar a medias: " +
                "usa 'Auditar' para ver el estado y 'Revertir' si hace falta.",
                "Detener ahora", danger: true, cancelText: "Seguir esperando")) return;
            _btnCancel.Enabled = false;
            SetStatus(StatusKind.Warn, "Cancelando...");
            t.Result.Cancel();
        }

        // -------------------------------------------------------------------
        //  Página Ubicación
        // -------------------------------------------------------------------
        private Panel BuildLocationPage()
        {
            var page = NewPage();
            var stack = NewStack();

            stack.Controls.Add(Theme.Hint(
                "Activa la ubicación de Windows (servicio, interruptor, consentimiento de todos los perfiles y políticas) " +
                "y da permiso a los navegadores para que Zoho pueda hacer el check-in. Se aplica sin reiniciar."));

            _chkLockDown    = Theme.Check("Impedir que el usuario desactive la ubicación desde Configuración (recomendado)", true);
            _chkBrowsers    = Theme.Check("Permitir la ubicación en Chrome, Edge y Firefox sin preguntar (check-in de Zoho)", true);
            _chkGetPosition = Theme.Check("Obtener coordenadas reales al verificar (tarda hasta 20 s; útil en el piloto)", false);
            stack.Controls.Add(_chkLockDown);
            stack.Controls.Add(_chkBrowsers);
            stack.Controls.Add(_chkGetPosition);

            var activate = NewButton("Activar ubicación",       Theme.ButtonKind.Success,   Theme.GlyphLocation);
            var audit    = NewButton("Auditar",                 Theme.ButtonKind.Secondary, Theme.GlyphSearch);
            var checkIn  = NewButton("Comprobar check-in Zoho", Theme.ButtonKind.Primary,   Theme.GlyphCheck);
            var geoTest  = NewButton("Probar en el navegador",  Theme.ButtonKind.Secondary, Theme.GlyphGlobe);
            var settings = NewButton("Ajustes de Windows",      Theme.ButtonKind.Secondary, Theme.GlyphSettings);
            var rollback = NewButton("Revertir",                Theme.ButtonKind.Danger,    Theme.GlyphUndo);

            var tip = new ToolTip();
            tip.SetToolTip(activate,
                "Un solo clic: arranca el servicio de ubicación, activa el interruptor, el consentimiento de todos los\n" +
                "usuarios, las políticas y el permiso de los navegadores; después comprueba que el check-in funciona.");
            tip.SetToolTip(audit,    "Muestra el estado actual sin modificar nada.");
            tip.SetToolTip(checkIn,  "Recorre todo lo que necesita el check-in de Zoho y dice qué falta. No modifica nada.");
            tip.SetToolTip(rollback, "Deshace los cambios de registro que hizo el toolkit en este equipo.");
            tip.SetToolTip(geoTest,  "Abre una página local que pide la ubicación igual que Zoho y muestra coordenadas, precisión o el error exacto.");
            tip.SetToolTip(settings, "Abre Configuración > Privacidad > Ubicación de Windows (ahí se fija la ubicación predeterminada).");

            activate.Click += (s, e) => ActivateLocation();
            audit.Click    += async (s, e) => await Execute("location", reportOnly: true);
            checkIn.Click  += async (s, e) => await Execute("location", reportOnly: true, checkIn: true);
            geoTest.Click  += async (s, e) => await RunSupport("Prueba en el navegador",
                "param($Root) Open-BrowserGeoTest -Root $Root | Out-Null",
                parameters: new Dictionary<string, object> { { "Root", _args.Root } });
            settings.Click += async (s, e) => await RunSupport("Ajustes de ubicación", "Open-LocationSettings");
            rollback.Click += (s, e) => Rollback();

            stack.Controls.Add(NewButtonRow(activate, checkIn, audit, geoTest, settings, rollback));

            page.Controls.Add(stack);
            return page;
        }

        // -------------------------------------------------------------------
        //  Página Aplicaciones
        // -------------------------------------------------------------------
        private Panel BuildAppsPage()
        {
            var page = NewPage();
            page.AutoScroll = false;

            _appsHint = Theme.Hint("Aplicaciones del catálogo. Marca las que quieras comprobar o instalar.");

            _apps = new CheckedListBox
            {
                Dock = DockStyle.Fill, CheckOnClick = true, IntegralHeight = false,
                HorizontalScrollbar = true, BorderStyle = BorderStyle.FixedSingle,
                Font = Theme.Body, Margin = new Padding(0, 0, 0, 10)
            };

            var apply   = NewButton("Instalar seleccionadas", Theme.ButtonKind.Success,   Theme.GlyphDownload);
            var audit   = NewButton("Comprobar instaladas",   Theme.ButtonKind.Secondary, Theme.GlyphSearch);
            var refresh = NewButton("Recargar catálogo",      Theme.ButtonKind.Secondary, Theme.GlyphRefresh);

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
            grid.Controls.Add(NewButtonRow(apply, audit, refresh), 0, 2);

            page.Controls.Add(grid);
            return page;
        }

        private sealed class AppRow
        {
            public string Id, Name, Version;
            public bool Enabled;
            public override string ToString() =>
                Name + (string.IsNullOrEmpty(Version) || Version == "0.0.0" ? "" : "  v" + Version) +
                (Enabled ? "" : "   (fuera del despliegue automático: enabled=false; se instala si la marcas)");
        }

        /// <summary>
        /// Lee las apps del catálogo con el runspace compartido.
        /// Se hace en PowerShell (ConvertFrom-Json) para no meter un parser JSON en el exe.
        /// </summary>
        private async Task RefreshApps()
        {
            SetBusy(true, "Leyendo catálogo de aplicaciones...");
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
                _appsHint.Text = "No se pudo leer el catálogo: " + error;
                _appsHint.ForeColor = Theme.Danger;
            }
            else
            {
                _appsHint.Text = "Catálogo: " + origin + "   ·   " + rows.Count + " aplicación(es). Marca las que quieras comprobar o instalar.";
                _appsHint.ForeColor = Theme.TextMuted;
            }

            SetBusy(false, error == null ? "Catálogo cargado." : "Error leyendo el catálogo.", error == null ? StatusKind.Info : StatusKind.Error);
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
        //  Página Red (solo diagnóstico: no modifica nada)
        // -------------------------------------------------------------------
        private Panel BuildNetworkPage()
        {
            var page = NewPage();
            var stack = NewStack();

            stack.Controls.Add(Theme.Hint(
                "Mide latencia, jitter y pérdida contra los destinos del catálogo, resuelve DNS, prueba puertos TCP, " +
                "certificados TLS, MTU y proxy. No cambia nada en el equipo."));

            // Etiqueta + número + pista en una fila que se parte si no cabe.
            var row = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = true, Margin = new Padding(0, 4, 0, 4)
            };
            _pingCount = new NumericUpDown
            {
                Width = 70, Minimum = 4, Maximum = 500, Value = 50, Font = Theme.Body,
                Margin = new Padding(6, 0, 10, 0), BorderStyle = BorderStyle.FixedSingle
            };
            row.Controls.Add(new Label { Text = "Pings por destino:", AutoSize = true, Font = Theme.Body, ForeColor = Theme.Text, Margin = new Padding(0, 5, 0, 0) });
            row.Controls.Add(_pingCount);
            row.Controls.Add(new Label
            {
                Text = "50 tarda ~1 min; baja a 10 para un vistazo rápido.",
                AutoSize = true, ForeColor = Theme.TextMuted, Font = Theme.Body, Margin = new Padding(0, 5, 0, 0)
            });
            stack.Controls.Add(row);

            var run = NewButton("Ejecutar diagnóstico", Theme.ButtonKind.Primary, Theme.GlyphPlay);
            run.Click += async (s, e) => await Execute("network", reportOnly: true);
            stack.Controls.Add(NewButtonRow(run));

            page.Controls.Add(stack);
            return page;
        }

        // -------------------------------------------------------------------
        //  Página Soporte: utilidades de un clic para el técnico de L1.
        //  Cada botón llama a una función de Toolkit.Support.psm1 en el runspace
        //  compartido; no pasa por el orquestador porque son acciones sueltas.
        //  Todos los botones miden lo mismo para que formen una cuadrícula.
        // -------------------------------------------------------------------
        private const int SupportButtonWidth = 212;

        private Panel BuildSupportPage()
        {
            var page = NewPage();
            var stack = NewStack();
            stack.Padding = new Padding(16, 6, 16, 8);

            // --- Diagnóstico ---
            stack.Controls.Add(Theme.SectionLabel("Diagnóstico  ·  no cambia nada"));
            var bInfo    = SupportButton("Info del equipo",           Theme.GlyphInfo);
            var bAudio   = SupportButton("Audio y micrófono",         Theme.GlyphAudio);
            var bPrint   = SupportButton("Impresoras",                Theme.GlyphPrinter);
            var bUpdate  = SupportButton("Windows Update",            Theme.GlyphUpdate);
            var bTime    = SupportButton("Hora del sistema",          Theme.GlyphClock);
            var bEvents  = SupportButton("Errores recientes (24 h)",  Theme.GlyphError);
            var bProcs   = SupportButton("Procesos que más consumen", Theme.GlyphProcess);
            bInfo.Click   += async (s, e) => await RunSupport("Info del equipo",   "Get-SupportSummary | Out-Null");
            bAudio.Click  += async (s, e) => await RunSupport("Audio y micrófono", "Test-AudioSetup | Out-Null");
            bPrint.Click  += async (s, e) => await RunSupport("Impresoras",        "Get-PrinterReport | Out-Null");
            bUpdate.Click += async (s, e) => await RunSupport("Windows Update",    "Get-UpdateStatus | Out-Null");
            bTime.Click   += async (s, e) => await RunSupport("Hora del sistema",  "Get-TimeStatus | Out-Null");
            bEvents.Click += async (s, e) => await RunSupport("Errores recientes", "Get-RecentErrors | Out-Null");
            bProcs.Click  += async (s, e) => await RunSupport("Procesos",          "Get-TopProcesses | Out-Null");
            stack.Controls.Add(NewButtonRow(bInfo, bAudio, bPrint, bUpdate, bTime, bEvents, bProcs));

            // --- Reparaciones rápidas ---
            stack.Controls.Add(Theme.SectionLabel("Reparaciones rápidas"));
            var bNet     = SupportButton("Reparar red",                  Theme.GlyphNetwork);
            var bNetDeep = SupportButton("Reset de red (reinicia)",      Theme.GlyphNetwork, Theme.ButtonKind.Warn);
            var bAudioR  = SupportButton("Reiniciar audio",              Theme.GlyphAudio);
            var bQueue   = SupportButton("Limpiar cola de impresión",    Theme.GlyphPrinter);
            var bSync    = SupportButton("Sincronizar hora",             Theme.GlyphClock);
            var bTemp    = SupportButton("Limpiar temporales",           Theme.GlyphBroom);
            var bMedia   = SupportButton("Permitir micrófono y cámara",  Theme.GlyphMic);
            var bPower   = SupportButton("No suspender el equipo",       Theme.GlyphSleep);
            var bScan    = SupportButton("Buscar actualizaciones",       Theme.GlyphUpdate);
            var bSfc     = SupportButton("Reparar archivos del sistema", Theme.GlyphShield, Theme.ButtonKind.Warn);
            var bReboot  = SupportButton("Reiniciar equipo (60 s)",      Theme.GlyphPower, Theme.ButtonKind.Danger);
            var bAbort   = SupportButton("Cancelar reinicio",            Theme.GlyphStop);

            bNet.Click     += async (s, e) => await RunSupport("Reparar red", "Repair-Network | Out-Null",
                "Se vaciará la caché DNS y se renovará la IP por DHCP. La red se corta uno o dos segundos.", "Reparar red");
            bNetDeep.Click += async (s, e) => await RunSupport("Reset de red", "Repair-Network -Deep | Out-Null",
                "Reset profundo: Winsock y pila TCP/IP. Deshace configuraciones de proxy/VPN raras.\n\nHabrá que reiniciar el equipo al terminar.", "Hacer el reset");
            bAudioR.Click  += async (s, e) => await RunSupport("Reiniciar audio", "Restart-AudioServices | Out-Null",
                "Se reiniciarán los servicios de audio. El sonido se corta unos segundos; el softphone puede necesitar reabrirse.", "Reiniciar audio");
            bQueue.Click   += async (s, e) => await RunSupport("Limpiar cola de impresión", "Clear-PrintQueue",
                "Se eliminarán TODOS los trabajos pendientes de todas las impresoras de este equipo.", "Limpiar la cola");
            bSync.Click    += async (s, e) => await RunSupport("Sincronizar hora", "Sync-SystemTime | Out-Null");
            bTemp.Click    += async (s, e) => await RunSupport("Limpiar temporales", "Clear-TempFiles | Out-Null",
                "Se borrarán los archivos temporales de más de 1 día de todos los perfiles y de Windows, y se vaciará la papelera.", "Limpiar");
            bMedia.Click   += async (s, e) => await RunSupport("Permitir micrófono y cámara", "Enable-MediaConsent | Out-Null",
                "Se permitirá el micrófono y la cámara para el equipo, las apps de escritorio y todos los usuarios.\n\nReversible con 'Revertir' (página Ubicación).", "Permitir");
            bPower.Click   += async (s, e) => await RunSupport("No suspender", "Set-NoSleepPower | Out-Null",
                "Con corriente, el equipo no se suspenderá ni hibernará; la pantalla se apaga a los 15 min.\nSe desactiva la hibernación (libera varios GB).", "Aplicar");
            bScan.Click    += async (s, e) => await RunSupport("Buscar actualizaciones", "Start-UpdateScan | Out-Null",
                "Se pedirá a Windows Update que busque, descargue e instale actualizaciones. Puede pedir reinicio más tarde.", "Buscar");
            bSfc.Click     += async (s, e) => await RunSupport("Reparar archivos del sistema", "Repair-SystemFiles | Out-Null",
                "sfc /scannow tarda entre 5 y 20 minutos. No cierres el toolkit mientras tanto.", "Empezar");
            bReboot.Click  += async (s, e) => await RunSupport("Reiniciar equipo", "Restart-ComputerDelayed -Seconds 60 | Out-Null",
                "El equipo se reiniciará en 60 segundos. El agente verá un aviso de Windows con la cuenta atrás y podrá guardar.\n\nSe puede cancelar con 'Cancelar reinicio' antes de que venza.", "Reiniciar en 60 s", danger: true);
            bAbort.Click   += async (s, e) => await RunSupport("Cancelar reinicio", "Restart-ComputerDelayed -Cancel | Out-Null");
            stack.Controls.Add(NewButtonRow(bNet, bNetDeep, bAudioR, bQueue, bSync, bTemp, bMedia, bPower, bScan, bSfc, bReboot, bAbort));

            // --- Reporte ---
            stack.Controls.Add(Theme.SectionLabel("Reporte"));
            var bReport = SupportButton("Guardar reporte para ticket", Theme.GlyphSave, Theme.ButtonKind.Primary);
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
            stack.Controls.Add(NewButtonRow(bReport));

            page.Controls.Add(stack);
            return page;
        }

        private Button SupportButton(string text, string glyph, Theme.ButtonKind kind = Theme.ButtonKind.Secondary)
        {
            var b = Theme.MakeButton(text, kind, glyph, SupportButtonWidth);
            _actionButtons.Add(b);
            return b;
        }

        private void ShowAbout()
        {
            using (var dlg = new AboutDialog()) dlg.ShowDialog(this);
        }

        /// <summary>
        /// Ejecuta una acción de soporte en el runspace compartido. Con <paramref name="confirm"/>
        /// pide confirmación antes (para las que cambian algo). Devuelve el último
        /// valor de salida como texto (lo usa el reporte para abrir el archivo).
        /// </summary>
        private async Task<string> RunSupport(string title, string script, string confirm = null, string okText = "Continuar",
                                              bool danger = false, IDictionary<string, object> parameters = null)
        {
            if (confirm != null && !Dialogs.Confirm(this, title, confirm, okText, danger)) return null;

            SetBusy(true, title + "...");
            _log.Clear();
            string last = null, error = null;
            bool cancelled = false;

            await Task.Run(() =>
            {
                try
                {
                    var res = SharedHost().Invoke(script, parameters);
                    if (res != null && res.Count > 0 && res[res.Count - 1] != null)
                        last = res[res.Count - 1].BaseObject?.ToString();
                }
                catch (PipelineStoppedException) { cancelled = true; }
                catch (Exception ex) { error = ex.Message; }
            });

            if (cancelled)
            {
                Append(LogLevel.Warn, "Cancelado por el técnico.");
                SetBusy(false, title + ": cancelado.", StatusKind.Warn);
            }
            else if (error != null)
            {
                Append(LogLevel.Error, "ERROR: " + error);
                SetBusy(false, title + ": error. Revisa la salida.", StatusKind.Error);
            }
            else
            {
                SetBusy(false, title + ": terminado.");
            }
            return last;
        }

        // -------------------------------------------------------------------
        //  Página Usuarios
        // -------------------------------------------------------------------
        private Panel BuildUsersPage()
        {
            var page = NewPage();
            page.AutoScroll = false;

            _users = new ListView
            {
                Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true,
                MultiSelect = false, HideSelection = false, GridLines = false,
                BorderStyle = BorderStyle.FixedSingle, Font = Theme.Body, Margin = new Padding(0)
            };
            _users.Columns.Add("Usuario", Theme.Px(150));
            _users.Columns.Add("Estado", Theme.Px(90));
            _users.Columns.Add("Admin", Theme.Px(55));
            _users.Columns.Add("Contraseña", Theme.Px(100));
            _users.Columns.Add("Último inicio", Theme.Px(115));
            _users.Columns.Add("Sesión", Theme.Px(65));
            _users.Columns.Add("Perfil", Theme.Px(160));
            _users.SelectedIndexChanged += (s, e) => UpdateUserButtons();
            _users.DoubleClick += (s, e) => { if (_btnUserPwd.Enabled) ChangePassword(); };
            // La última columna absorbe el ancho sobrante para no dejar un hueco gris.
            _users.Resize += (s, e) => StretchLastColumn(_users);

            // Botonera vertical: los botones se apilan y comparten anchura.
            var side = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.TopDown, WrapContents = false, Width = 206,
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom,   // alto = el de la fila; si no cabe, scroll
                AutoScroll = true, Margin = new Padding(10, 0, 0, 0)
            };
            Func<string, Theme.ButtonKind, string, Button> mk = (text, kind, glyph) =>
            {
                var b = Theme.MakeButton(text, kind, glyph, 196);
                b.Margin = new Padding(0, 0, 0, 6);
                return b;
            };
            _btnUsersRefresh = mk("Actualizar lista",      Theme.ButtonKind.Secondary, Theme.GlyphRefresh);
            _btnUserNew      = mk("Nuevo usuario...",      Theme.ButtonKind.Success,   Theme.GlyphAdd);
            _btnUserPwd      = mk("Cambiar contraseña...", Theme.ButtonKind.Secondary, Theme.GlyphKey);
            _btnUserNoPwd    = mk("Quitar contraseña",     Theme.ButtonKind.Secondary, Theme.GlyphKey);
            _btnUserToggle   = mk("Deshabilitar",          Theme.ButtonKind.Secondary, Theme.GlyphBlock);
            _btnUserDelete   = mk("Eliminar usuario",      Theme.ButtonKind.Danger,    Theme.GlyphDelete);

            _btnUsersRefresh.Click += async (s, e) => await RefreshUsers();
            _btnUserNew.Click      += (s, e) => CreateUser();
            _btnUserPwd.Click      += (s, e) => ChangePassword();
            _btnUserNoPwd.Click    += (s, e) => ClearPassword();
            _btnUserToggle.Click   += (s, e) => ToggleEnabled();
            _btnUserDelete.Click   += (s, e) => DeleteUser();

            side.Controls.AddRange(new Control[] { _btnUsersRefresh, _btnUserNew, _btnUserPwd, _btnUserNoPwd, _btnUserToggle, _btnUserDelete });

            // Dos columnas: la lista se lleva todo el ancho, la botonera lo justo.
            var host = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Padding = new Padding(16, 12, 16, 12) };
            host.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            host.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            host.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            host.Controls.Add(_users, 0, 0);
            host.Controls.Add(side, 1, 0);
            page.Controls.Add(host);

            UpdateUserButtons();
            return page;
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
                var estado = u.LockedOut ? "Bloqueada" : (u.Enabled ? "Activa" : "Deshabilitada");
                var item = new ListViewItem(new[]
                {
                    u.Name + (u.IsCurrentUser ? "  (actual)" : ""),
                    estado,
                    u.IsAdmin ? "Sí" : "",
                    u.PasswordRequired ? "requerida" : "sin contraseña",
                    u.LastLogon,
                    u.SessionOpen ? "abierta" : (u.HasProfile ? "perfil" : "–"),
                    u.ProfilePath ?? ""
                }) { Tag = u, UseItemStyleForSubItems = false };
                if (u.BuiltIn)       item.ForeColor = Theme.TextMuted;
                else if (!u.Enabled) item.ForeColor = Theme.TextMuted;
                if (u.IsCurrentUser) item.Font = Theme.BodyBold;
                if (u.LockedOut)     item.SubItems[1].ForeColor = Theme.Danger;
                if (!u.PasswordRequired && !u.BuiltIn) item.SubItems[3].ForeColor = Theme.Warn;
                if (u.SessionOpen)   item.SubItems[5].ForeColor = Theme.Ok;
                _users.Items.Add(item);
            }
            _users.EndUpdate();
            _usersLoaded = true;
            UpdateUserButtons();

            SetBusy(false, error != null ? "Error leyendo cuentas: " + error : rows.Count + " cuenta(s) local(es).",
                    error != null ? StatusKind.Error : StatusKind.Info);
            if (error != null) Dialogs.Warn(this, "Usuarios", error);
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
            using (var dlg = new PasswordDialog("Cambiar contraseña", u.Name))
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                await RunUserAction("Cambiando contraseña de " + u.Name + "...",
                    "param($Name, $Password) Set-LocalUserPassword -Name $Name -Password $Password",
                    new Dictionary<string, object> { { "Name", u.Name }, { "Password", dlg.Password } });
            }
        }

        private async void ClearPassword()
        {
            var u = SelectedUser(); if (u == null) return;
            if (!Dialogs.Confirm(this, "Quitar contraseña",
                "La cuenta '" + u.Name + "' quedará sin contraseña: cualquiera podrá iniciar sesión en este equipo con ella.\n\n" +
                "Windows no permite usar cuentas sin contraseña por red ni por escritorio remoto.",
                "Quitar contraseña", danger: true)) return;
            await RunUserAction("Quitando contraseña de " + u.Name + "...",
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
            var text = "Se va a eliminar la cuenta '" + u.Name + "'. Esta acción no se puede deshacer.";
            bool removeProfile = false;
            if (u.HasProfile)
            {
                var r = Dialogs.Choice(this, "Eliminar usuario",
                    text + "\n\nLa cuenta tiene carpeta de perfil:\n    " + u.ProfilePath,
                    new[] { "Eliminar cuenta y carpeta", "Solo la cuenta", "Cancelar" }, Dialogs.Kind.Warning, dangerPrimary: true);
                if (r == 2) return;
                removeProfile = (r == 0);
            }
            else
            {
                if (!Dialogs.Confirm(this, "Eliminar usuario", text, "Eliminar cuenta", danger: true)) return;
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
        /// Ejecuta una acción de Toolkit.Users.psm1. Todas devuelven {Success, Message}
        /// en vez de lanzar, para que el error llegue al técnico en claro.
        /// </summary>
        private async Task RunUserAction(string busyText, string script, Dictionary<string, object> parameters)
        {
            SetBusy(true, busyText);
            bool success = false;
            string message = "Sin respuesta del módulo.";

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
                catch (PipelineStoppedException) { message = "Cancelado."; }
                catch (Exception ex) { message = ex.Message; }
            });

            SetBusy(false, message, success ? StatusKind.Ok : StatusKind.Warn);
            if (!success) Dialogs.Warn(this, "Usuarios", message);

            await RefreshUsers();
        }

        // -------------------------------------------------------------------
        //  Construcción de páginas
        // -------------------------------------------------------------------
        // Layout fluido: nada de coordenadas fijas. Cada página es una pila vertical
        // (TableLayoutPanel de una columna) que se adapta al ancho; si el alto no
        // alcanza, la página muestra scroll en vez de recortar.

        private static Panel NewPage() =>
            new Panel { BackColor = Theme.Surface, AutoScroll = true, Padding = new Padding(0) };

        private static TableLayoutPanel NewStack()
        {
            var t = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 1,
                Padding = new Padding(16, 14, 16, 6)
            };
            // Columna al 100 %: es lo que permite que las etiquetas se ajusten al ancho.
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            return t;
        }

        /// <summary>Botón de acción de una página: se registra para bloquearse mientras hay algo en curso.</summary>
        private Button NewButton(string text, Theme.ButtonKind kind, string glyph)
        {
            var b = Theme.MakeButton(text, kind, glyph);
            _actionButtons.Add(b);
            return b;
        }

        /// <summary>Fila de botones que pasa a varias líneas cuando la ventana es estrecha.</summary>
        private static FlowLayoutPanel NewButtonRow(params Button[] buttons)
        {
            var row = new FlowLayoutPanel
            {
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = true,
                Anchor = AnchorStyles.Left | AnchorStyles.Right,
                Margin = new Padding(0, 6, 0, 0)
            };
            row.Controls.AddRange(buttons);
            return row;
        }

        private static void StretchLastColumn(ListView list)
        {
            if (list.Columns.Count == 0) return;
            int used = 0;
            for (int i = 0; i < list.Columns.Count - 1; i++) used += list.Columns[i].Width;
            // La última columna se lleva el sobrante; si no hay sobrante, se queda en
            // su mínimo y aparece el scroll horizontal (solo con la ventana muy estrecha).
            var last = list.Columns[list.Columns.Count - 1];
            var free = list.ClientSize.Width - used;
            last.Width = Math.Max(free, Theme.Px(80));
        }

        // -------------------------------------------------------------------
        //  Ejecución de módulos (orquestador embebido)
        // -------------------------------------------------------------------

        /// <summary>
        /// Botón Activar ubicación: aplica todo (servicio, interruptor, consentimiento,
        /// políticas, navegadores) y, si fue bien, encadena la comprobación del check-in
        /// para que el técnico vea el veredicto final sin pulsar nada más.
        /// </summary>
        private async void ActivateLocation()
        {
            var code = await Execute("location", reportOnly: false);
            if (code != 0 && code != Program.ExitRebootNeeded) return;   // cancelado o fallo: ya se avisó

            Append(LogLevel.Info, "");
            Append(LogLevel.Info, "Ubicación activada. Comprobando ahora que el check-in de Zoho funciona...");
            await Execute("location", reportOnly: true, checkIn: true, keepLog: true);
        }

        private const int ExitCancelled = -1;

        /// <summary>
        /// Ejecuta UN módulo del orquestador con las opciones de su página.
        /// Devuelve el código de salida (o ExitCancelled si el usuario no confirmó).
        /// </summary>
        private async Task<int> Execute(string module, bool reportOnly, bool checkIn = false, bool keepLog = false)
        {
            string[] apps = null;
            if (module == "apps")
            {
                apps = SelectedApps();
                if (apps.Length == 0)
                {
                    Dialogs.Info(this, "Aplicaciones", "Marca al menos una aplicación de la lista.");
                    return ExitCancelled;
                }
            }

            if (!reportOnly)
            {
                string title, what, ok;
                switch (module)
                {
                    case "location":
                        title = "Activar ubicación"; ok = "Activar";
                        what = "Se va a activar la ubicación en este equipo (servicio, registro y políticas)." +
                               (_chkLockDown.Checked ? "\nEl usuario NO podrá desactivarla desde Configuración." : "") +
                               (_chkBrowsers.Checked ? "\nChrome, Edge y Firefox entregarán la ubicación a los sitios sin preguntar." : "") +
                               "\n\nLos cambios de registro quedan registrados y son reversibles con 'Revertir'.";
                        break;
                    case "apps":
                        title = "Instalar aplicaciones"; ok = "Instalar";
                        what = "Se van a instalar en silencio:\n\n  · " + string.Join("\n  · ", apps) +
                               "\n\nLa instalación de aplicaciones NO se deshace con 'Revertir'.";
                        break;
                    default:
                        title = "Confirmar"; ok = "Continuar";
                        what = "Se va a ejecutar el módulo '" + module + "'.";
                        break;
                }
                if (!Dialogs.Confirm(this, title, what, ok)) return ExitCancelled;
            }

            // Las opciones se leen aquí, en el hilo de la UI, antes de irse al hilo de trabajo.
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
                // El técnico está delante: no tiene sentido aplazar a la ventana nocturna.
                IgnoreMaintenanceWindow = true
            };

            SetBusy(true, checkIn ? "Comprobando el check-in de Zoho..." : reportOnly ? "Auditando..." : "Aplicando cambios...");
            if (!keepLog) _log.Clear();

            var exitCode = await Task.Run(() =>
            {
                try
                {
                    string origin;
                    options.CatalogJson = EmbeddedScripts.ReadCatalog(_args.ConfigPath, _args.SharePath, out origin);
                    Append(LogLevel.Debug, "Catálogo: " + origin);

                    // Runspace compartido: no se paga el arranque (runspace + módulos) en cada clic.
                    return SharedHost().Run(options);
                }
                catch (Exception ex)
                {
                    Append(LogLevel.Error, "ERROR: " + ex.Message);
                    return Program.ExitGeneric;
                }
            });

            if (exitCode == ScriptHost.ExitCancelled)
            {
                SetBusy(false, "Cancelado.", StatusKind.Warn);
                return exitCode;
            }

            var verdict = checkIn
                ? (exitCode == 0 ? "Check-in de Zoho: el equipo está listo." : "Check-in de Zoho: NO va a funcionar todavía.")
                : DescribeExit(exitCode);
            var ok2 = exitCode == 0 || exitCode == Program.ExitRebootNeeded;
            SetBusy(false, verdict, ok2 ? (exitCode == Program.ExitRebootNeeded ? StatusKind.Warn : StatusKind.Ok) : StatusKind.Error);

            if (!ok2)
            {
                Dialogs.Warn(this, checkIn ? "Check-in de Zoho" : "Resultado", verdict + "\n\nRevisa la salida para el detalle.");
            }
            return exitCode;
        }

        private async void Rollback()
        {
            if (!Dialogs.Confirm(this, "Revertir cambios",
                "Esto revertirá TODOS los cambios de registro aplicados por el toolkit en este equipo.",
                "Revertir", danger: true)) return;

            SetBusy(true, "Revirtiendo...");
            _log.Clear();

            await Task.Run(() =>
            {
                try
                {
                    // Initialize-Toolkit abre un log propio para la reversión y deja el modo en interactivo.
                    SharedHost().Invoke("param($Root) Initialize-Toolkit -Root $Root; Invoke-ToolkitRollback",
                        new Dictionary<string, object> { { "Root", _args.Root } });
                }
                catch (Exception ex) { Append(LogLevel.Error, "ERROR: " + ex.Message); }
            });

            SetBusy(false, "Reversión terminada.");
        }

        private static string DescribeExit(int code)
        {
            switch (code)
            {
                case 0:    return "Terminado correctamente.";
                case 3010: return "Terminado. Requiere reinicio.";
                case 1001: return "Falló el módulo de ubicación.";
                case 1002: return "Falló la instalación de una o más aplicaciones.";
                case 1003: return "Red en estado crítico.";
                case 5:    return "Sin privilegios de administrador.";
                default:   return "Terminado con errores (código " + code + ").";
            }
        }

        private void SetBusy(bool busy, string status, StatusKind kind = StatusKind.Ok)
        {
            _busy = busy;
            foreach (var b in _actionButtons) b.Enabled = !busy;
            _apps.Enabled = !busy;
            _btnUsersRefresh.Enabled = _btnUserNew.Enabled = !busy;
            if (busy)
                _btnUserPwd.Enabled = _btnUserNoPwd.Enabled = _btnUserToggle.Enabled = _btnUserDelete.Enabled = false;
            else
                UpdateUserButtons();

            _progress.Visible = busy;
            _btnCancel.Visible = busy;
            _btnCancel.Enabled = busy;
            _elapsed.Visible = busy;
            if (busy)
            {
                _busySince = DateTime.Now;
                _elapsed.Text = "0:00";
                _clock.Start();
                SetStatus(StatusKind.Busy, status);
            }
            else
            {
                _clock.Stop();
                SetStatus(kind, status);
            }
        }

        // -------------------------------------------------------------------
        //  Salida (log de la GUI)
        // -------------------------------------------------------------------

        /// <summary>
        /// Se puede llamar desde cualquier hilo. Encola la línea y programa UN
        /// volcado en el hilo de la UI; las líneas que lleguen mientras tanto
        /// salen en ese mismo volcado.
        /// </summary>
        private void Append(LogLevel level, string text)
        {
            if (string.IsNullOrEmpty(text)) return;

            lock (_pendingLog) _pendingLog.Enqueue(new KeyValuePair<LogLevel, string>(level, text));

            if (!_log.InvokeRequired)
            {
                // Ya en el hilo de la UI (arranque, botones): volcar directamente
                // conserva el orden respecto a lo que hubiera encolado un worker.
                FlushLog();
                return;
            }
            if (System.Threading.Interlocked.Exchange(ref _flushScheduled, 1) == 0)
            {
                try { _log.BeginInvoke(new Action(FlushLog)); }
                catch (InvalidOperationException) { System.Threading.Interlocked.Exchange(ref _flushScheduled, 0); }   // ventana cerrándose
            }
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        private const int WM_SETREDRAW = 0x000B;

        private void FlushLog()
        {
            // Primero se libera la marca y luego se vacía la cola: una línea que
            // entre en medio programa otro volcado en vez de quedarse colgada.
            System.Threading.Interlocked.Exchange(ref _flushScheduled, 0);
            List<KeyValuePair<LogLevel, string>> batch;
            lock (_pendingLog)
            {
                if (_pendingLog.Count == 0) return;
                batch = new List<KeyValuePair<LogLevel, string>>(_pendingLog);
                _pendingLog.Clear();
            }

            bool many = batch.Count > 1 && _log.IsHandleCreated;
            if (many) SendMessage(_log.Handle, WM_SETREDRAW, IntPtr.Zero, IntPtr.Zero);
            try
            {
                foreach (var line in batch)
                {
                    _log.SelectionStart = _log.TextLength;
                    _log.SelectionLength = 0;
                    _log.SelectionColor = LevelColor(line.Key);
                    _log.AppendText(line.Value + Environment.NewLine);
                }
                _log.SelectionColor = _log.ForeColor;
            }
            finally
            {
                if (many)
                {
                    SendMessage(_log.Handle, WM_SETREDRAW, (IntPtr)1, IntPtr.Zero);
                    _log.Invalidate();
                }
            }
            _log.ScrollToCaret();
        }

        private static Color LevelColor(LogLevel level)
        {
            switch (level)
            {
                case LogLevel.Ok:    return Theme.LogOk;
                case LogLevel.Warn:  return Theme.LogWarn;
                case LogLevel.Error: return Theme.LogError;
                case LogLevel.Debug: return Theme.LogDebug;
                default:             return Theme.LogText;
            }
        }
    }

    /// <summary>
    /// Tamaño, posición y separador de la ventana entre sesiones (HKCU). El técnico
    /// que agranda el log no tiene que volver a hacerlo cada vez que abre el toolkit.
    /// </summary>
    internal static class WindowPlacement
    {
        private const string Key = @"Software\Toolkit BPO\Window";
        public static bool HasSavedSplitter { get; private set; }

        public static void Restore(Form f, SplitContainer split)
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key))
                {
                    if (k == null) return;
                    int w = (int)k.GetValue("Width", 0), h = (int)k.GetValue("Height", 0);
                    int x = (int)k.GetValue("Left", int.MinValue), y = (int)k.GetValue("Top", int.MinValue);
                    int sd = (int)k.GetValue("Splitter", 0);
                    bool max = (int)k.GetValue("Maximized", 0) == 1;

                    if (w >= f.MinimumSize.Width && h >= f.MinimumSize.Height && x != int.MinValue)
                    {
                        var r = new Rectangle(x, y, w, h);
                        // Solo si sigue cayendo en alguna pantalla (monitor externo desconectado...).
                        if (Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(r)))
                        {
                            f.StartPosition = FormStartPosition.Manual;
                            f.Bounds = r;
                        }
                    }
                    if (max) f.WindowState = FormWindowState.Maximized;
                    if (sd > 0)
                    {
                        HasSavedSplitter = true;
                        f.Load += (s, e) =>
                        {
                            var v = Math.Max(split.Panel1MinSize, Math.Min(sd, split.Height - split.Panel2MinSize - split.SplitterWidth));
                            try { split.SplitterDistance = v; } catch (ArgumentException) { }
                        };
                    }
                }
            }
            catch { }
        }

        public static void Save(Form f, SplitContainer split)
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key))
                {
                    if (k == null) return;
                    var b = f.WindowState == FormWindowState.Normal ? f.Bounds : f.RestoreBounds;
                    k.SetValue("Width", b.Width);  k.SetValue("Height", b.Height);
                    k.SetValue("Left", b.Left);    k.SetValue("Top", b.Top);
                    k.SetValue("Maximized", f.WindowState == FormWindowState.Maximized ? 1 : 0);
                    k.SetValue("Splitter", split.SplitterDistance);
                }
            }
            catch { }
        }
    }
}
