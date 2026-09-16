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
        private CheckBox _chkLockDown, _chkGetPosition;

        // Pestana Aplicaciones
        private CheckedListBox _apps;
        private Label _appsHint;
        private bool _appsLoaded;

        // Pestana Red
        private NumericUpDown _pingCount;

        // Pestana Usuarios
        private ListView _users;
        private Button _btnUsersRefresh, _btnUserNew, _btnUserPwd, _btnUserNoPwd, _btnUserToggle, _btnUserDelete;
        private ScriptHost _usersHost;
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
            FormClosed += (s, e) => { if (_usersHost != null) _usersHost.Dispose(); };
        }

        private void BuildUi()
        {
            Text = "Toolkit Call Center  v" + Program.AppVersion();
            Size = new Size(940, 720);
            MinimumSize = new Size(780, 560);
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

            _tabs = new TabControl { Dock = DockStyle.Fill };
            _tabApps  = BuildAppsTab();
            _tabUsers = BuildUsersTab();
            _tabs.TabPages.Add(BuildLocationTab());
            _tabs.TabPages.Add(_tabApps);
            _tabs.TabPages.Add(BuildNetworkTab());
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
            var logHost = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 4, 16, 8) };
            logHost.Controls.Add(_log);

            var split = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Horizontal,
                SplitterDistance = 290,
                Panel1MinSize = 220,
                Panel2MinSize = 120
            };
            var tabHost = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 8, 16, 4) };
            tabHost.Controls.Add(_tabs);
            split.Panel1.Controls.Add(tabHost);
            split.Panel2.Controls.Add(logHost);

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

            Controls.AddRange(new Control[] { split, header, _progress, _status });

            Append(LogLevel.Info,  "Toolkit v" + Program.AppVersion() + " — los scripts van embebidos en este ejecutable.");
            Append(LogLevel.Debug, "Auditar evalua el equipo sin modificar nada. Empieza siempre por ahi.");
        }

        // -------------------------------------------------------------------
        //  Pestana Ubicacion
        // -------------------------------------------------------------------
        private TabPage BuildLocationTab()
        {
            var tab = NewTab("Ubicacion");

            var panel = new Panel { Dock = DockStyle.Top, Height = 132, Padding = new Padding(16, 12, 16, 8) };

            var intro = NewHint(
                "Activa el servicio de ubicacion (lfsvc), el interruptor del sistema, el consentimiento de todos los " +
                "perfiles del equipo y las politicas. Se aplica sin reiniciar.", 8);

            _chkLockDown    = NewCheck("Impedir que el usuario desactive la ubicacion desde Configuracion  (recomendado)", 52, true);
            _chkLockDown.ForeColor = Color.FromArgb(120, 60, 0);
            _chkGetPosition = NewCheck("Obtener coordenadas reales al verificar  (tarda hasta 20 s; util en el piloto)", 76, false);

            panel.Controls.AddRange(new Control[] { intro, _chkLockDown, _chkGetPosition });

            var buttons = new Panel { Dock = DockStyle.Top, Height = 56, Padding = new Padding(16, 6, 16, 6) };

            var audit    = NewButton("Auditar  (no cambia nada)", 0,   170, Color.FromArgb(230, 230, 230), Color.Black);
            var apply    = NewButton("APLICAR UBICACION",         182, 170, Color.FromArgb(0, 120, 60),    Color.White);
            var rollback = NewButton("Revertir",                  364, 110, Color.FromArgb(150, 40, 40),   Color.White);

            audit.Click    += (s, e) => Execute("location", reportOnly: true);
            apply.Click    += (s, e) => Execute("location", reportOnly: false);
            rollback.Click += (s, e) => Rollback();

            buttons.Controls.AddRange(new Control[] { audit, apply, rollback });

            tab.Controls.AddRange(new Control[] { buttons, panel });
            return tab;
        }

        // -------------------------------------------------------------------
        //  Pestana Aplicaciones
        // -------------------------------------------------------------------
        private TabPage BuildAppsTab()
        {
            var tab = NewTab("Aplicaciones");

            _appsHint = NewHint("Aplicaciones del catalogo. Marca las que quieras comprobar o instalar.", 0);
            _appsHint.Dock = DockStyle.Top;
            _appsHint.Height = 24;
            _appsHint.Padding = new Padding(16, 6, 16, 0);

            _apps = new CheckedListBox
            {
                Dock = DockStyle.Fill,
                CheckOnClick = true,
                IntegralHeight = false,
                Font = new Font("Segoe UI", 9F)
            };

            var buttons = new Panel { Dock = DockStyle.Bottom, Height = 56, Padding = new Padding(16, 6, 16, 6) };

            var refresh = NewButton("Recargar catalogo",              0,   150, Color.FromArgb(230, 230, 230), Color.Black);
            var audit   = NewButton("Comprobar instaladas",           162, 170, Color.FromArgb(230, 230, 230), Color.Black);
            var apply   = NewButton("INSTALAR SELECCIONADAS",         344, 190, Color.FromArgb(0, 120, 60),    Color.White);

            refresh.Click += async (s, e) => await RefreshApps();
            audit.Click   += (s, e) => Execute("apps", reportOnly: true);
            apply.Click   += (s, e) => Execute("apps", reportOnly: false);

            buttons.Controls.AddRange(new Control[] { refresh, audit, apply });

            var host = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 4, 16, 0) };
            host.Controls.Add(_apps);

            tab.Controls.AddRange(new Control[] { host, buttons, _appsHint });
            return tab;
        }

        private sealed class AppRow
        {
            public string Id, Name, Version;
            public bool Enabled;
            public override string ToString() =>
                Name + (string.IsNullOrEmpty(Version) || Version == "0.0.0" ? "" : "  v" + Version) +
                (Enabled ? "" : "   (desactivada en el catalogo: enabled=false)");
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
                    var result = UsersHost().Invoke(
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

            var panel = new Panel { Dock = DockStyle.Top, Height = 120, Padding = new Padding(16, 12, 16, 8) };

            var intro = NewHint(
                "Mide latencia, jitter y perdida contra los destinos del catalogo, resuelve DNS, prueba puertos TCP, " +
                "certificados TLS, MTU y proxy. No cambia nada en el equipo.", 8);

            var lbl = new Label { Text = "Pings por destino:", Left = 16, Top = 58, AutoSize = true };
            _pingCount = new NumericUpDown
            {
                Left = 140, Top = 55, Width = 70,
                Minimum = 4, Maximum = 500, Value = 50
            };
            var lblHint = new Label
            {
                Text = "(50 tarda ~1 min; baja a 10 para un vistazo rapido)",
                Left = 220, Top = 58, AutoSize = true, ForeColor = Color.DimGray
            };

            panel.Controls.AddRange(new Control[] { intro, lbl, _pingCount, lblHint });

            var buttons = new Panel { Dock = DockStyle.Top, Height = 56, Padding = new Padding(16, 6, 16, 6) };
            var run = NewButton("EJECUTAR DIAGNOSTICO", 0, 190, Color.FromArgb(0, 90, 150), Color.White);
            run.Click += (s, e) => Execute("network", reportOnly: true);
            buttons.Controls.Add(run);

            tab.Controls.AddRange(new Control[] { buttons, panel });
            return tab;
        }

        // -------------------------------------------------------------------
        //  Pestana Usuarios
        // -------------------------------------------------------------------
        private TabPage BuildUsersTab()
        {
            var tab = new TabPage("Usuarios") { BackColor = Color.FromArgb(243, 243, 243) };

            _users = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                MultiSelect = false,
                HideSelection = false,
                GridLines = true,
                Font = new Font("Segoe UI", 9F)
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

            var side = new Panel { Dock = DockStyle.Right, Width = 190, Padding = new Padding(8, 0, 0, 0) };
            int y = 0;
            Func<string, Color, Color, Button> mk = (text, back, fore) =>
            {
                var b = new Button
                {
                    Text = text, Left = 8, Top = y, Width = 178, Height = 32,
                    BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat,
                    Font = new Font("Segoe UI", 9F, FontStyle.Bold)
                };
                y += 38;
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

            var host = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8) };
            host.Controls.AddRange(new Control[] { _users, side });
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
        /// Runspace propio para la pestana Usuarios. Se abre una vez y se reutiliza:
        /// asi el log de las acciones sobre cuentas va todo al mismo archivo.
        /// </summary>
        private ScriptHost UsersHost()
        {
            if (_usersHost == null)
            {
                var h = new ScriptHost();
                h.Output += (s, e) => Append(e.Level, e.Text);
                h.Open();
                h.Invoke("param($Root) Initialize-Toolkit -Root $Root",
                    new Dictionary<string, object> { { "Root", _args.Root } });
                _usersHost = h;
            }
            return _usersHost;
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
                    foreach (var o in UsersHost().Invoke("Get-LocalUserInventory"))
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
                    var res = UsersHost().Invoke(script, parameters);
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
        private static TabPage NewTab(string title) =>
            new TabPage(title) { BackColor = Color.FromArgb(243, 243, 243) };

        private static Label NewHint(string text, int top) =>
            new Label { Text = text, Top = top, Left = 16, Width = 800, Height = 36, ForeColor = Color.DimGray };

        private CheckBox NewCheck(string text, int top, bool chk) =>
            new CheckBox { Text = text, Top = top, Left = 16, Width = 640, Checked = chk, AutoSize = true };

        private Button NewButton(string text, int left, int width, Color back, Color fore)
        {
            var b = new Button
            {
                Text = text, Left = left + 16, Top = 8, Width = width, Height = 34,
                BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 9F, FontStyle.Bold)
            };
            _actionButtons.Add(b);
            return b;
        }

        /// <summary>
        /// Ejecuta UN modulo del orquestador con las opciones de su pestana.
        /// Cada pestana llama aqui con su propio nombre; el orquestador es el mismo
        /// que usa el modo desatendido (/silent /modules:...).
        /// </summary>
        private async void Execute(string module, bool reportOnly)
        {
            string[] apps = null;
            if (module == "apps")
            {
                apps = SelectedApps();
                if (apps.Length == 0)
                {
                    MessageBox.Show("Marca al menos una aplicacion de la lista.", "Toolkit",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
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
                if (confirm != DialogResult.Yes) return;
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
                GetPosition = _chkGetPosition.Checked,
                PingCount   = (int)_pingCount.Value,
                // El tecnico esta delante: no tiene sentido aplazar a la ventana nocturna.
                IgnoreMaintenanceWindow = true
            };

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
