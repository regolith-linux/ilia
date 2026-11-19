using Gtk;

namespace Ilia {
    // A dialog page that lists system commands on the path and allows for free-from launching in a terminal.
    class CommandPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 1;
        private const int ITEM_VIEW_COLUMN_NAME = 0;

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

        private Gtk.TreePath path;

        private bool quiet = false;

        // The window was closed while the page was still loading: in the background copy the
        // process goes on, so what arrives later is dropped
        private bool closed = false;

        // The commands listed last, kept by the background copy for the next call: the model, the
        // commands in it, and the PATH directories with their modification times when they were
        // read. A later call with the same directories, unchanged, shows this list at once, and
        // the directories are read again to catch any other change.
        private static Gtk.ListStore ? listed_model = null;
        private static string[] listed_commands = {};
        private static string ? listed_signature = null;

        public string get_name() {
            return "<u>C</u>ommands";
        }

        public string get_icon_name() {
            return "utilities-terminal";
        }

        public string get_help() {
            return "This dialog allows for the executing commands on the user path. Initially all commands are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will launch it. If no item matches, enter runs the typed command line, including any arguments.";
        }

        public char get_keybinding() {
            return 'c';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Execute Command");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            if (arg_map.contains("-q"))
                this.quiet = true;

            string[] dirs = command_dirs(CallerEnvironment.get_variable("PATH"));
            string signature = directories_signature(dirs);
            if (listed_model != null && signature == listed_signature)
                model = listed_model;
            else
                model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            read_commands.begin(dirs, (obj, res) => {
                string[] commands = read_commands.end(res);
                if (closed || (model == listed_model && commands_equal(commands, listed_commands)))
                    return;

                // The commands are listed and sorted apart from the view, then shown at once: the view
                // and its accessible do not follow every row, which keeps the window responsive
                var listed = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (string), typeof (string));
                foreach (unowned string command in commands) {
                    Gtk.TreeIter row;
                    listed.append(out row);
                    listed.set(row, ITEM_VIEW_COLUMN_NAME, command);
                }
                listed.set_sort_column_id(0, SortType.ASCENDING);
                model = listed;
                filter = new Gtk.TreeModelFilter(model, null);
                filter.set_visible_func(filter_func);
                item_view.set_model(filter);
                set_selection();

                listed_model = listed;
                listed_commands = commands;
                listed_signature = signature;
            });

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.destroy.connect(() => {
                closed = true;
                // The filter and the model call back into the page, and so keep it: drop them,
                // as the background copy goes on after the window
                filter = null;
                model = null;
            });

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (handle_emacs_vim_nav(item_view, path, event_key))
                return true;

            var keycode = event_key.keyval;

            if (is_enter_key(keycode) && !filter.get_iter_first(out iter) && entry.text.length > 0) {
                execute_command(entry.text);
                return true;
            }

            return false;
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            filter.get_iter(out iter, row_path);
            execute_command_from_selection(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            filter.refilter();
            set_selection();
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (filter.get_iter(out iter, path))
                execute_command_from_selection(iter);
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text().down().strip();

            if (queryString.length > 0) {
                GLib.Value app_info;
                string strval;
                m.get_value(iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string();

                // Match the whole query, not each word: here a space starts the command's arguments
                return (strval != null && strval.down().contains(queryString));
            } else {
                return true;
            }
        }

        /*
         * The directories of PATH with their modification times, which change when a command is
         * added, removed or renamed in them
         */
        private static string directories_signature(string[] dirs) {
            var signature = new StringBuilder();
            foreach (unowned string dir in dirs) {
                signature.append(dir);
                try {
                    var info = File.new_for_path(dir).query_info(FileAttribute.TIME_MODIFIED + "," + FileAttribute.TIME_MODIFIED_USEC,
                                                                 FileQueryInfoFlags.NONE);
                    var modified = info.get_modification_date_time();
                    if (modified != null)
                        signature.append_printf("\n%" + int64.FORMAT + "\n", modified.to_unix() * 1000000 + modified.get_microsecond());
                } catch (GLib.Error e) {
                    signature.append("\n?\n");
                }
            }
            return signature.str;
        }

        private static bool commands_equal(string[] a, string[] b) {
            if (a.length != b.length)
                return false;
            for (int i = 0; i < a.length; i++) {
                if (a[i] != b[i])
                    return false;
            }
            return true;
        }

        /*
         * The commands in the directories, as full paths in a fixed order. They are read on a
         * worker thread, so that the window stays responsive meanwhile. The call keeps its own
         * copy of the directories: the caller's may be freed while the thread still reads them.
         */
        private static async string[] read_commands(owned string[] dirs) {
            var commands = new GenericArray<string>();
            SourceFunc callback = read_commands.callback;

            new Thread<void *>("ilia-commands", () => {
                foreach (unowned string dir in dirs) {
                    var app_dir = File.new_for_path(dir);
                    try {
                        // Follow links: most commands are links (alternatives), and is_command() needs their targets
                        var attributes = FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.ACCESS_CAN_EXECUTE;
                        var enumerator = app_dir.enumerate_children(attributes, FileQueryInfoFlags.NONE);
                        FileInfo ? info;
                        while ((info = enumerator.next_file()) != null) {
                            if (is_command(info))
                                commands.add(app_dir.get_child(info.get_name()).get_path());
                        }
                    } catch (Error err) {
                        stderr.printf("Error: list_files failed: %s\n", err.message);
                    }
                }
                commands.sort(strcmp);
                Idle.add((owned) callback);
                return null;
            });

            yield;
            string[] result = new string[commands.length];
            for (int i = 0; i < commands.length; i++)
                result[i] = commands[i];
            return result;
        }

        // Highlight the first row: the best match for the text typed
        private void set_selection() {
            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            if (path == null)
                path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
        }

        public void show() {
            item_view.grab_focus();
        }

        // launch a desktop app
        public void execute_command_from_selection(Gtk.TreeIter selection) {
            string cmd_path;
            filter.@get(selection, ITEM_VIEW_COLUMN_NAME, out cmd_path);

            if (cmd_path != null) execute_command(Shell.quote(cmd_path));
        }

        // command is in shell syntax: a quoted path, or a typed command line with arguments
        private void execute_command(string command) {
            // TODO ~ Enable two launch modes with some modifier.  By default terminal exits when program exits.
            // todo is to add another mode in which the terminal does not exit after program completes.

            // if -q is given, run the command without opening a terminal emulator
            string commandline = build_command_line(command, this.quiet);


            try {
                var app_info = AppInfo.create_from_commandline(commandline, null, GLib.AppInfoCreateFlags.NONE);
                var runner = get_runner_app_info(app_info);

                if (!runner.launch(null, CallerEnvironment.create_launch_context()))
                    stderr.printf("Error: execute_command failed\n");

                session_controller.quit();
            } catch (GLib.Error err) {
                stderr.printf("Error: execute_command failed: %s\n", err.message);
            }
        }
    }
}
