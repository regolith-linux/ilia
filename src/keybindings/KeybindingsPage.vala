using Gtk;
using Gee;

namespace Ilia {
    class KeybingingsPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 3;
        private const int ITEM_VIEW_COLUMN_KEYBINDING = 0;
        private const int ITEM_VIEW_COLUMN_SUMMARY = 1;
        private const int ITEM_VIEW_COLUMN_EXEC = 2;

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // Access state from model
        private Gtk.TreeIter iter;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;

        private Gtk.Entry entry;

        private SessionContoller session_controller;

        private Gtk.Widget root_widget;

        public string get_name () {
            return "Keybindings";
        }

        public string get_icon_name () {
            return "input-keyboard";
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (string), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            read_i3_config.begin ((obj, res) => {
                read_i3_config.end (res);

                item_view.columns_autosize ();
                model.set_sort_column_id (1, SortType.ASCENDING);
                // model.set_sort_func (0, app_sort_func);
                set_selection ();
            });

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (item_view);
            scrolled.expand = true;

            root_widget = scrolled;
        }

        public Gtk.Widget get_root () {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view () {
            item_view = new Gtk.TreeView.with_model (filter);

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes (-1, "Keybinding", new CellRendererText (), "text", ITEM_VIEW_COLUMN_KEYBINDING);
            item_view.insert_column_with_attributes (-1, "Action", new CellRendererText (), "text", ITEM_VIEW_COLUMN_SUMMARY);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public bool key_event(Gdk.EventKey event_key) {
            return false;
        }

        public void grab_focus (Gdk.EventKey event_key) {
            if (event_key.keyval == DialogWindow.KEY_CODE_ENTER && !filter.get_iter_first (out iter) && entry.text.length > 0) {
                execute_keybinding (entry.text);
            }

            item_view.grab_focus ();
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            execute_app_from_selection (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            if (filter.get_iter_first (out iter)) {
                execute_app_from_selection (iter);
            }
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text ().down ().strip ();

            if (queryString.length > 0) {
                GLib.Value gval;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_SUMMARY, out gval);
                strval = gval.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        // Read the active i3 configuration and populate the model with keybindings
        private async void read_i3_config () {
            try {
                var i3_client = new I3Client ();
                var config_file = i3_client.getConfig ().config;
                var parser = new ConfigParser (config_file, "");

                Map<string, ArrayList<Keybinding> > kbmodel = parser.parse ();

                foreach (var entry in kbmodel.entries) {
                    var category = entry.key;
                    var bindings = entry.value;

                    foreach (var binding in bindings) {
                        var formatted_spec = format_spec (binding.spec);
                        var summary = category + " " + binding.label;
                        model.append (out iter);
                        model.set (
                            iter,
                            ITEM_VIEW_COLUMN_KEYBINDING, formatted_spec,
                            ITEM_VIEW_COLUMN_SUMMARY, summary,
                            ITEM_VIEW_COLUMN_EXEC, binding.exec
                        );
                    }
                }
            } catch (GLib.Error err) {
                // TODO consistent error handling
                stderr.printf ("Failed to read config from i3: %s\n", err.message);
            }
        }

        public static string format_spec (string raw_keybinding) {
            // TODO: this won't work for keybindings with < > characters
            return raw_keybinding
                    .replace ("<", "")
                    .replace (">", " ")
                    .replace ("  ", " ");
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreePath path = new Gtk.TreePath.first ();
            Gtk.TreeSelection selection = item_view.get_selection ();

            selection.set_mode (SelectionMode.SINGLE);
            selection.select_path (path);
        }

        // launch a desktop app
        public void execute_app_from_selection (Gtk.TreeIter selection) {            
            string cmd_path;
            filter.@get (selection, ITEM_VIEW_COLUMN_EXEC, out cmd_path);

            if (cmd_path != null) execute_keybinding (cmd_path);
        }

        private void execute_keybinding (string exec) {
            string commandline = "/usr/bin/i3-msg \"" + exec + "\"";

            try {
                var app_info = AppInfo.create_from_commandline (commandline, null, AppInfoCreateFlags.NONE);

                if (!app_info.launch (null, null)) {
                    stderr.printf ("Error: execute_keybinding failed\n");
                }
                session_controller.quit ();
            } catch (GLib.Error err) {
                stderr.printf ("Error: execute_keybinding failed: %s\n", err.message);
            }
        }
    }
}