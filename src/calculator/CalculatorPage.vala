using Gtk;
using GLib;
using Math;

namespace Ilia {
    class CalculatorPage : DialogPage, GLib.Object {
        private Gtk.Entry entry;
        private Gtk.Label result_label;
        private Gtk.Widget root_widget;
        
        private string icon = "accessories-calculator";

        public string get_name() {
            return "<u>o</u>Calculator";
        }

        public string get_icon_name() {
            return icon;
        }

        public string get_help() {
            return "A simple calculator for quick math evaluations.";
        }

        public char get_keybinding() {
            return 'o';
        }

        public HashTable<string, string>? get_keybindings() {
            var keybindings = new HashTable<string, string>(str_hash, str_equal);
            keybindings.set("enter", "Calculate Result");
            return keybindings;
        }

        public void show() {
            if (entry != null) {
                entry.grab_focus();
            }
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (event_key.keyval == Gdk.Key.Return) {
                evaluate_expression();
                return true;
            }
            return false;
        }

        public async void initialize(
            GLib.Settings settings,
            HashTable<string, string?> arg_map,
            Gtk.Entry entry,
            SessionContoller sessionController,
            string wm_name,
            bool is_wayland
        ) throws GLib.Error {
            this.entry = entry;

            var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            vbox.margin = 12;
            vbox.expand = true;

            entry.changed.connect(on_entry_changed);
            entry.activate.connect(on_entry_activated);

            var result_title = new Gtk.Label("<b>Result</b>");
            result_title.set_use_markup(true);
            result_title.set_xalign(0.0f);

            result_label = new Gtk.Label("");
            result_label.set_xalign(0.0f);
            result_label.set_padding(10, 10);

            var result_frame = new Gtk.Frame(null);
            result_frame.set_shadow_type(Gtk.ShadowType.IN);
            result_frame.set_size_request(-1, 45);

            var result_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            result_box.set_margin_top(5);
            result_box.pack_start(result_label, true, true, 5);

            result_frame.add(result_box);

            var grid_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
            grid_container.set_halign(Gtk.Align.CENTER);

            var grid = new Gtk.Grid();
            grid.set_column_spacing(5);
            grid.set_row_spacing(5);
            grid.set_vexpand(true);
            grid.set_size_request(500, -1);

            string[,] buttons = {
                { "sin(", "cos(", "tan(" },
                { "log(", "ln(", "exp(" },
                { "^", "/", "π" },
                { "C", "(", ")" },
                { "+", "-", "*" }
            };

            for (int i = 0; i < 5; i++) {
                for (int j = 0; j < 3; j++) {
                    string label = buttons[i, j];
                    var button = new Gtk.Button.with_label(label);
                    button.clicked.connect(() => on_button_clicked(label));

                    button.set_hexpand(true);
                    button.set_vexpand(true);

                    grid.attach(button, j, i, 1, 1);
                }
            }

            // Container limits the max width of button grid
            grid_container.pack_start(grid, true, true, 0);

            vbox.pack_start(result_title, false, false, 0);
            vbox.pack_start(result_frame, false, false, 0);
            vbox.pack_start(grid_container, true, true, 0);

            root_widget = vbox;
        }

        private void on_entry_changed() {
            evaluate_expression();
        }

        private void on_entry_activated() {
            evaluate_expression();
        }

        private void on_button_clicked(string text) {
            if(text == "C") {
                entry.set_text("");
                return;
            }
            entry.insert_at_cursor(text);
        }

        private void evaluate_expression() {
            string expression = entry.get_text().strip();
            double result = ExpressionParser.parse(expression);
            set_output(result.to_string());
        }

        private void set_output(string text) {
            result_label.set_text(text);
        }   
    }
}
