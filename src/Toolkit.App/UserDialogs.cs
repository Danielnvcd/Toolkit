using System;
using System.Drawing;
using System.Windows.Forms;

namespace Toolkit.App
{
    /// <summary>
    /// Pide una contrasena dos veces. La contrasena nunca se escribe en el log.
    /// </summary>
    internal sealed class PasswordDialog : Form
    {
        private readonly TextBox _pwd1, _pwd2;

        public string Password => _pwd1.Text;

        public PasswordDialog(string title, string userName)
        {
            Text = title;
            Size = new Size(400, 200);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MaximizeBox = MinimizeBox = false;
            Font = new Font("Segoe UI", 9F);

            var lbl = new Label { Text = "Usuario:  " + userName, Left = 16, Top = 14, Width = 350, Font = new Font("Segoe UI", 9F, FontStyle.Bold) };
            var l1  = new Label { Text = "Nueva contrasena", Left = 16, Top = 46, Width = 130 };
            var l2  = new Label { Text = "Repetir contrasena", Left = 16, Top = 78, Width = 130 };
            _pwd1 = new TextBox { Left = 150, Top = 43, Width = 216, UseSystemPasswordChar = true };
            _pwd2 = new TextBox { Left = 150, Top = 75, Width = 216, UseSystemPasswordChar = true };

            var ok = new Button { Text = "Aceptar", Left = 190, Top = 118, Width = 85, DialogResult = DialogResult.None };
            var cancel = new Button { Text = "Cancelar", Left = 281, Top = 118, Width = 85, DialogResult = DialogResult.Cancel };
            ok.Click += (s, e) =>
            {
                if (_pwd1.Text != _pwd2.Text)
                {
                    MessageBox.Show(this, "Las contrasenas no coinciden.", "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                if (_pwd1.Text.Length == 0)
                {
                    MessageBox.Show(this, "Para dejar la cuenta sin contrasena usa el boton 'Quitar contrasena'.", "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                DialogResult = DialogResult.OK;
            };

            Controls.AddRange(new Control[] { lbl, l1, l2, _pwd1, _pwd2, ok, cancel });
            AcceptButton = ok;
            CancelButton = cancel;
        }
    }

    /// <summary>Datos para crear una cuenta local nueva.</summary>
    internal sealed class NewUserDialog : Form
    {
        private readonly TextBox _name, _fullName, _pwd1, _pwd2;
        private readonly CheckBox _noPassword, _admin, _neverExpires;

        public string UserName     => _name.Text.Trim();
        public string FullName     => _fullName.Text.Trim();
        public string Password     => _pwd1.Text;
        public bool   NoPassword   => _noPassword.Checked;
        public bool   Administrator => _admin.Checked;
        public bool   PasswordNeverExpires => _neverExpires.Checked;

        public NewUserDialog()
        {
            Text = "Nuevo usuario local";
            Size = new Size(420, 320);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MaximizeBox = MinimizeBox = false;
            Font = new Font("Segoe UI", 9F);

            int y = 16;
            Func<string, Label> lbl = t => new Label { Text = t, Left = 16, Top = y + 3, Width = 140 };
            Func<bool, TextBox> box = pwd => new TextBox { Left = 160, Top = y, Width = 226, UseSystemPasswordChar = pwd };

            var lName = lbl("Nombre de usuario"); _name = box(false); y += 32;
            var lFull = lbl("Nombre completo");   _fullName = box(false); y += 32;
            var lP1   = lbl("Contrasena");        _pwd1 = box(true); y += 32;
            var lP2   = lbl("Repetir contrasena"); _pwd2 = box(true); y += 36;

            _noPassword   = new CheckBox { Text = "Sin contrasena (inicio de sesion directo)", Left = 160, Top = y, AutoSize = true }; y += 26;
            _admin        = new CheckBox { Text = "Administrador local", Left = 160, Top = y, AutoSize = true }; y += 26;
            _neverExpires = new CheckBox { Text = "La contrasena nunca caduca", Left = 160, Top = y, AutoSize = true, Checked = true }; y += 36;

            _noPassword.CheckedChanged += (s, e) =>
            {
                _pwd1.Enabled = _pwd2.Enabled = !_noPassword.Checked;
                if (_noPassword.Checked) _pwd1.Text = _pwd2.Text = "";
            };

            var ok = new Button { Text = "Crear", Left = 210, Top = y, Width = 85 };
            var cancel = new Button { Text = "Cancelar", Left = 301, Top = y, Width = 85, DialogResult = DialogResult.Cancel };
            ok.Click += (s, e) =>
            {
                if (UserName.Length == 0)
                {
                    MessageBox.Show(this, "Indica el nombre de usuario.", "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                if (!NoPassword && _pwd1.Text.Length == 0)
                {
                    MessageBox.Show(this, "Indica una contrasena o marca 'Sin contrasena'.", "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                if (_pwd1.Text != _pwd2.Text)
                {
                    MessageBox.Show(this, "Las contrasenas no coinciden.", "Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                DialogResult = DialogResult.OK;
            };

            Controls.AddRange(new Control[] { lName, _name, lFull, _fullName, lP1, _pwd1, lP2, _pwd2,
                                              _noPassword, _admin, _neverExpires, ok, cancel });
            AcceptButton = ok;
            CancelButton = cancel;
        }
    }
}
