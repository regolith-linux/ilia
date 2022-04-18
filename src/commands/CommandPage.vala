using Gtk;

namespace Ilia {
    // A dialog page that lists system commands on the path and allows for free-from launching in a terminal.
    class CommandPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 1;
        private const int ITEM_VIEW_COLUMN_NAME = 0;

        // Max number of files to read in sequence before yeilding
        private const int FS_FILE_READ_COUNT = 64;
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
            return "Terminal";
        }

        public string get_icon_name() {
            return "utilities-terminal";
        }

        public string get_help () {
            return "This dialog allows for the executing commands on the user path. Initially all commands are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will launch it.";
        }

        public HashTable<string, string>? get_keybindings() {
            var keybindings = new HashTable<string, string ? >(str_hash, str_equal);

            keybindings.set("enter", "Execute Command");            

            return keybindings;
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_commands_from_path.begin ((obj, res) => {
                load_commands_from_path.end (res);

                model.set_sort_column_id (0, SortType.ASCENDING);
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
            item_view.insert_column_with_attributes (-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public bool key_event(Gdk.EventKey event_key) {
            return false;
        }

        public void grab_focus (uint keycode) {
            if (keycode == DialogWindow.KEY_CODE_ENTER && !filter.get_iter_first (out iter) && entry.text.length > 0) {
                execute_command(entry.text);
            }

            item_view.grab_focus ();
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            execute_command_from_selection (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            if (filter.get_iter_first (out iter)) {
                execute_command_from_selection (iter);
            }
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text ().down ().strip ();

            if (queryString.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        private async void load_commands_from_path () {
            var paths = Environment.get_variable("PATH");

            foreach (unowned string path in paths.split (":")) {
                var path_dir = File.new_for_path (path);
                if (path_dir.query_exists ()) {
                    yield load_commands_from_dir (path_dir);
                }
            }
        }

        private async void load_commands_from_dir (File app_dir) {
            try {
                var enumerator = yield app_dir.enumerate_children_async (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT);

                while (true) {
                    var app_files = yield enumerator.next_files_async (FS_FILE_READ_COUNT, Priority.DEFAULT);

                    if (app_files == null) {
                        break;
                    }

                    foreach (var info in app_files) {
                        string file_path = app_dir.get_child (info.get_name ()).get_path ();

                        model.append (out iter);
                        model.set (
                            iter,
                            ITEM_VIEW_COLUMN_NAME, file_path
                        );
                    }
                }
            } catch (Error err) {
                stderr.printf ("Error: list_files failed: %s\n", err.message);
            }
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreePath path = new Gtk.TreePath.first ();
            Gtk.TreeSelection selection = item_view.get_selection ();

            selection.set_mode (SelectionMode.SINGLE);
            selection.select_path (path);
        }

        // launch a desktop app
        public void execute_command_from_selection (Gtk.TreeIter selection) {
            string cmd_path;
            filter.@get (selection, ITEM_VIEW_COLUMN_NAME, out cmd_path);

            if (cmd_path != null) execute_command(cmd_path);
        }

        private void execute_command(string cmd_path) {
            // TODO ~ Enalbe two launch modes with some modifier.  By default terminal exits when program exits.
            //  todo is to add another mode in which the terminal does not exit after program completes.

            //string commandline = "/usr/bin/x-terminal-emulator -e \"bash -c '" + cmd_path + "; exec bash'\"";
            //string commandline = "x-terminal-emulator -e \"bash -c '" + cmd_path + "'\"";
            string commandline = "x-terminal-emulator -e '" + cmd_path + "'";

            // stdout.printf("%s\n", commandline);

            try {
                var app_info = AppInfo.create_from_commandline (commandline, cmd_path, AppInfoCreateFlags.NONE);

                if (!app_info.launch (null, null)) {
                    stderr.printf ("Error: execute_command failed\n");
                }

                session_controller.quit ();
            } catch (GLib.Error err) {
                stderr.printf ("Error: execute_command failed: %s\n", err.message);
            }
        }
    }
}