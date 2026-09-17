using System;
using System.Drawing;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Base de los formularios de entrada: fondo blanco, franja de botones abajo,
    /// mismo aspecto que los diálogos de confirmación.
    /// </summary>
    internal abstract class InputDialog : Form
    {
        protected readonly TableLayoutPanel Grid;
        protected readonly Button Ok, Cancel;
        private readonly FlowLayoutPanel _bar;

        protected InputDialog(string title, string okText, int width = 440)
        {
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
            ClientSize = new Size(width, 200);

            Grid = new TableLayoutPanel
            {
                Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 2, Padding = new Padding(22, 18, 22, 10)
            };
            Grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            Grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));

            Ok = Theme.MakeButton(okText, Theme.ButtonKind.Primary);
            Cancel = Theme.MakeButton("Cancelar", Theme.ButtonKind.Secondary);
            Ok.MinimumSize = Cancel.MinimumSize = new Size(104, 34);
            Ok.Margin = Cancel.Margin = new Padding(8, 0, 0, 0);
            Cancel.DialogResult = DialogResult.Cancel;
            Ok.Click += (s, e) => { if (ValidateInput()) DialogResult = DialogResult.OK; };

            _bar = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Padding = new Padding(14, 12, 14, 6), BackColor = Theme.Window
            };
            _bar.Controls.Add(Cancel);
            _bar.Controls.Add(Ok);

            Controls.Add(Grid);
            Controls.Add(Theme.Rule(DockStyle.Bottom));
            Controls.Add(_bar);
            AcceptButton = Ok;
            CancelButton = Cancel;

            Load += (s, e) => ClientSize = new Size(ClientSize.Width, Grid.GetPreferredSize(new Size(ClientSize.Width, 0)).Height + _bar.Height + 1);
        }

        /// <summary>
        /// Las clases hijas añaden sus controles después del constructor base, así que
        /// el layout (y con él el escalado DPI) se reanuda aquí, con todo ya creado.
        /// </summary>
        protected override void OnLoad(EventArgs e)
        {
            ResumeLayout(false);
            PerformLayout();
            base.OnLoad(e);
        }

        /// <summary>Devuelve false (y avisa) si los datos no valen; el diálogo no se cierra.</summary>
        protected abstract bool ValidateInput();

        protected Label AddLabel(string text, int row) =>
            Put(new Label { Text = text, AutoSize = true, ForeColor = Theme.Text, Margin = new Padding(0, 7, 14, 0) }, 0, row);

        protected TextBox AddBox(int row, bool password = false)
        {
            var t = new TextBox
            {
                Dock = DockStyle.Fill, UseSystemPasswordChar = password, BorderStyle = BorderStyle.FixedSingle,
                Font = Theme.Body, Margin = new Padding(0, 3, 0, 6)
            };
            return Put(t, 1, row);
        }

        protected CheckBox AddCheck(string text, int row, bool chk = false) =>
            Put(Theme.Check(text, chk), 1, row);

        protected T Put<T>(T c, int col, int row) where T : Control
        {
            Grid.Controls.Add(c, col, row);
            return c;
        }
    }

    /// <summary>
    /// Pide una contraseña dos veces. La contraseña nunca se escribe en el log.
    /// </summary>
    internal sealed class PasswordDialog : InputDialog
    {
        private readonly TextBox _pwd1, _pwd2;

        public string Password => _pwd1.Text;

        public PasswordDialog(string title, string userName) : base(title, "Cambiar")
        {
            var who = new Label
            {
                Text = userName, AutoSize = true, Font = Theme.Title, ForeColor = Theme.Text,
                Margin = new Padding(0, 0, 0, 12)
            };
            Grid.Controls.Add(who, 0, 0);
            Grid.SetColumnSpan(who, 2);

            AddLabel("Nueva contraseña", 1);   _pwd1 = AddBox(1, password: true);
            AddLabel("Repetir contraseña", 2); _pwd2 = AddBox(2, password: true);
        }

        protected override bool ValidateInput()
        {
            if (_pwd1.Text != _pwd2.Text)
            {
                Dialogs.Warn(this, "Contraseña", "Las contraseñas no coinciden.");
                return false;
            }
            if (_pwd1.Text.Length == 0)
            {
                Dialogs.Info(this, "Contraseña", "Para dejar la cuenta sin contraseña usa el botón 'Quitar contraseña'.");
                return false;
            }
            return true;
        }
    }

    /// <summary>Datos para crear una cuenta local nueva.</summary>
    internal sealed class NewUserDialog : InputDialog
    {
        private readonly TextBox _name, _fullName, _pwd1, _pwd2;
        private readonly CheckBox _noPassword, _admin, _neverExpires;

        public string UserName     => _name.Text.Trim();
        public string FullName     => _fullName.Text.Trim();
        public string Password     => _pwd1.Text;
        public bool   NoPassword   => _noPassword.Checked;
        public bool   Administrator => _admin.Checked;
        public bool   PasswordNeverExpires => _neverExpires.Checked;

        public NewUserDialog() : base("Nuevo usuario local", "Crear", 460)
        {
            AddLabel("Nombre de usuario", 0);  _name     = AddBox(0);
            AddLabel("Nombre completo", 1);    _fullName = AddBox(1);
            AddLabel("Contraseña", 2);         _pwd1     = AddBox(2, password: true);
            AddLabel("Repetir contraseña", 3); _pwd2     = AddBox(3, password: true);

            _noPassword   = AddCheck("Sin contraseña (inicio de sesión directo)", 4);
            _admin        = AddCheck("Administrador local", 5);
            _neverExpires = AddCheck("La contraseña nunca caduca", 6, chk: true);
            _noPassword.Margin = new Padding(0, 8, 0, 2);

            _noPassword.CheckedChanged += (s, e) =>
            {
                _pwd1.Enabled = _pwd2.Enabled = !_noPassword.Checked;
                if (_noPassword.Checked) _pwd1.Text = _pwd2.Text = "";
            };
        }

        protected override bool ValidateInput()
        {
            if (UserName.Length == 0)
            {
                Dialogs.Warn(this, "Nuevo usuario", "Indica el nombre de usuario.");
                return false;
            }
            if (!NoPassword && _pwd1.Text.Length == 0)
            {
                Dialogs.Warn(this, "Nuevo usuario", "Indica una contraseña o marca 'Sin contraseña'.");
                return false;
            }
            if (_pwd1.Text != _pwd2.Text)
            {
                Dialogs.Warn(this, "Nuevo usuario", "Las contraseñas no coinciden.");
                return false;
            }
            return true;
        }
    }
}
