using Gtk;

namespace Ilia {
    class WindowPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 3;
        private const int ITEM_VIEW_COLUMN_APP_ICON = 0;
        private const int ITEM_VIEW_COLUMN_TITLE = 1;
        private const int ITEM_VIEW_COLUMN_ID = 2;

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
        // Active icon theme
        private Gtk.IconTheme icon_theme;

        private int icon_size;

        public string get_name () {
            return "<u>W</u>indows";
        }

        public string get_icon_name () {
            return "window-new";
        }

        public string get_help () {
            return "This dialog allows for navigating between open windows in the desktop environment.  Selecting a window from the list will cause it to be viewed on screen and focused.";
        }

        public char get_keybinding() {
            return 'w';
        }

        public HashTable<string, string>? get_keybindings() {
            var keybindings = new HashTable<string, string ? >(str_hash, str_equal);

            keybindings.set("enter", "Navigate to Window");

            return keybindings;
        }

        public async void initialize (GLib.Settings settings, HashTable<string, string ? > arg_map, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            icon_size = settings.get_int ("icon-size");

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_windows ();
            model.set_sort_column_id (1, SortType.ASCENDING);
            // model.set_sort_func (0, app_sort_func);
            set_selection ();

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
            item_view.insert_column_with_attributes (-1, "App", new CellRendererPixbuf (), "pixbuf", ITEM_VIEW_COLUMN_APP_ICON);
            item_view.insert_column_with_attributes (-1, "Title", new CellRendererText (), "text", ITEM_VIEW_COLUMN_TITLE);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public bool key_event (Gdk.EventKey event_key) {
            var keycode = event_key.keyval;

            if (keycode == Ilia.KEY_CODE_ENTER && !filter.get_iter_first (out iter) && entry.text.length > 0) {
                _from_selection (iter);
                return true;
            }

            return false;
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            _from_selection (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            if (filter.get_iter_first (out iter)) {
                _from_selection (iter);
            }
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text ().down ().strip ();

            if (queryString.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_TITLE, out app_info);
                strval = app_info.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        private void load_windows () {
            try {
                var i3_client = new I3Client ();
                var node = i3_client.getTree ();

                if (node != null) {
                    icon_theme = Gtk.IconTheme.get_default ();
                    traverse_nodes (node);
                }
            } catch (GLib.Error err) {
                // TODO consistent error handling
                stderr.printf ("Failed to read or parse window tree from %s: %s\n", WM_NAME, err.message);
            }
        }

        private void traverse_nodes (TreeReply node) {
            if (navigable_window(node)) {
                Gdk.Pixbuf pixbuf;
                if (node.windowProperties.instance != null) {
                    pixbuf = load_icon_from_app_name (icon_theme, node.windowProperties.instance, icon_size);
                } else {
                    pixbuf = load_icon_from_app_name (icon_theme, node.app_id, icon_size);
                }

                model.append (out iter);
                model.set (
                    iter,
                    ITEM_VIEW_COLUMN_APP_ICON, pixbuf,
                    ITEM_VIEW_COLUMN_TITLE, node.name,
                    ITEM_VIEW_COLUMN_ID, node.id
                );
            }

            if (node.nodes != null) {
                for (int i = 0; i < node.nodes.length; ++i) {
                    traverse_nodes (node.nodes[i]);
                }
            }

            if (node.floating_nodes != null) {
                for (int i = 0; i < node.floating_nodes.length; ++i) {
                    traverse_nodes (node.floating_nodes[i]);
                }
            }
        }

        // Filter controls which TreeReply instances should be shown in window view
        private bool navigable_window(TreeReply node) {
            bool rv = node.ntype == "con"                                 // specifies actual windows
                      && (node.window_type == "normal"
                          || node.window_type == "unknown"
                          || IS_SESSION_WAYLAND && node.layout == "none") // window type
                      && node.windowProperties.clazz != "i3bar";          // ignore i3bar

            return rv;
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreeSelection selection = item_view.get_selection ();

            if (selection.count_selected_rows () == 0) { // initial state, nothing explicitly selected by user
                selection.set_mode (SelectionMode.SINGLE);
                Gtk.TreePath path = new Gtk.TreePath.first ();
                selection.select_path (path);
                stdout.printf("select_path\n");
            } else { // an existing item has selection, ensure it's visible
                List<Gtk.TreePath> path_list = selection.get_selected_rows(null);
                if (path_list != null) {
                    unowned List<Gtk.TreePath>? element = path_list.first ();
                    item_view.scroll_to_cell(element.data, null, false, 0f, 0f);
                }
            }

            item_view.grab_focus (); // ensure list view is in focus to avoid excessive nav for selection
        }

        // switch to window
        public void _from_selection (Gtk.TreeIter selection) {
            string id;
            filter.@get (selection, ITEM_VIEW_COLUMN_ID, out id);

            focus_window (id);
        }

        // [window_role="gnome-terminal-window-6bee2ec0-eb8b-4b10-aafc-7c2708201d43" title="Terminal"] focus
        private void focus_window (string id) {
            string exec = "[con_id=\"" + id + "\"] focus";
            string cli_bin = get_wm_cli();

            if (cli_bin == null) {
                stderr.printf("ilia doesn't support this action with you WM.\n");
                return;
            }

            string commandline = cli_bin + exec;
            // stdout.printf("running %s\n", commandline);

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