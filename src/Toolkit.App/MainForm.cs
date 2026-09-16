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
    /// La pestana "Usuarios" es la excepcion deliberada: cambiar contrasenas o
    /// borrar cuentas es interactivo por naturaleza y no se despliega en masa.
    /// Llama directamente a las funciones de Toolkit.Users.psm1.
    /// </summary>
    public sealed class MainForm : Form
    {
        private readonly CommandLineArgs _args;

        private CheckBox _chkLocation, _chkApps, _chkNetwork, _chkUsers, _chkLockDown;
        private Button _btnAudit, _btnApply, _btnRollback;
        private RichTextBox _log;
        private Label _status;
        private ProgressBar _progress;
        private TabControl _tabs;
        private TabPage _tabUsers;

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
            _tabs.TabPages.Add(BuildConfigTab());
            _tabUsers = BuildUsersTab();
            _tabs.TabPages.Add(_tabUsers);
            _tabs.SelectedIndexChanged += async (s, e) =>
            {
                if (_tabs.SelectedTab == _tabUsers && !_usersLoaded) await RefreshUsers();
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
                SplitterDistance = 270,
                Panel1MinSize = 200,
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
        //  Pestana Configuracion (ubicacion / apps / red)
        // -------------------------------------------------------------------
        private TabPage BuildConfigTab()
        {
            var tab = new TabPage("Configuracion") { BackColor = Color.FromArgb(243, 243, 243) };

            var panel = new Panel { Dock = DockStyle.Top, Height = 158, Padding = new Padding(16, 12, 16, 8) };

            _chkLocation = NewCheck("Ubicacion  (servicio lfsvc + politicas + todos los perfiles; aplica sin reiniciar)", 8, true);
            _chkApps     = NewCheck("Aplicaciones  (instalacion desatendida del catalogo)",          32, true);
            _chkNetwork  = NewCheck("Diagnostico de red  (latencia, jitter, perdida, DNS, MTU)",     56, true);
            _chkUsers    = NewCheck("Inventario de usuarios locales  (solo lectura; la gestion esta en la pestana Usuarios)", 80, true);
            _chkLockDown = NewCheck("Impedir que el usuario desactive la ubicacion  (recomendado)",  110, true);
            _chkLockDown.ForeColor = Color.FromArgb(120, 60, 0);

            panel.Controls.AddRange(new Control[] { _chkLocation, _chkApps, _chkNetwork, _chkUsers, _chkLockDown });

            var buttons = new Panel { Dock = DockStyle.Top, Height = 56, Padding = new Padding(16, 6, 16, 6) };

            _btnAudit    = NewButton("Auditar  (no cambia nada)", 0,   170, Color.FromArgb(230, 230, 230), Color.Black);
            _btnApply    = NewButton("APLICAR CAMBIOS",           182, 170, Color.FromArgb(0, 120, 60),    Color.White);
            _btnRollback = NewButton("Revertir",                  364, 110, Color.FromArgb(150, 40, 40),   Color.White);

            _btnAudit.Click    += (s, e) => Execute(reportOnly: true);
            _btnApply.Click    += (s, e) => Execute(reportOnly: false);
            _btnRollback.Click += (s, e) => Rollback();

            buttons.Controls.AddRange(new Control[] { _btnAudit, _btnApply, _btnRollback });

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
            var mods = new List<string>();
            if (_chkLocation.Checked) mods.Add("location");
            if (_chkApps.Checked)     mods.Add("apps");
            if (_chkNetwork.Checked)  mods.Add("network");
            if (_chkUsers.Checked)    mods.Add("users");
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
            _btnApply.Enabled = _btnAudit.Enabled = _btnRollback.Enabled = !busy;
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
