using Gtk;

namespace Ilia {
    // A dialog page that lists system commands on the path and allows for free-from launching in a terminal.
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
            return "Windows";
        }

        public string get_icon_name () {
            return "applications-other";
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            icon_size = settings.get_int ("icon-size");

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_apps ();
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
            return false;
        }

        public void grab_focus (uint keycode) {
            if (keycode == DialogWindow.KEY_CODE_ENTER && !filter.get_iter_first (out iter) && entry.text.length > 0) {
                execute_app_from_selection (iter);
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
                GLib.Value app_info;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_TITLE, out app_info);
                strval = app_info.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        private void load_apps () {
            try {
                var i3_client = new I3Client ();
                var node = i3_client.getTree ();

                if (node != null) {
                    icon_theme = Gtk.IconTheme.get_default ();
                    traverse_nodes (node);
                }                
            } catch (GLib.Error err) {
                // TODO consistent error handling
                stderr.printf ("Failed to read or parse window tree from i3: %s\n", err.message);
            }
        }

        private void traverse_nodes (TreeReply node) {
            if (node.ntype == "con" && node.window_type == "normal") {

                var pixbuf = load_icon (node.windowProperties.instance, icon_size);

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
        }

        private Gdk.Pixbuf ? load_icon (string ? icon_name, int size) {
            Gtk.IconInfo icon_info;

            try {
                if (icon_name == null) {
                    icon_info = icon_theme.lookup_icon ("applications-other", size, Gtk.IconLookupFlags.FORCE_SIZE);
                    return icon_info.load_icon ();
                }

                icon_info = icon_theme.lookup_icon (icon_name, size, Gtk.IconLookupFlags.FORCE_SIZE); // from icon theme
                if (icon_info != null) {
                    return icon_info.load_icon ();
                }

                if (GLib.File.new_for_path (icon_name).query_exists ()) {
                    try {
                        return new Gdk.Pixbuf.from_file_at_size (icon_name, size, size);
                    } catch (Error e) {
                        stderr.printf ("%s\n", e.message);
                    }
                }

                try {
                    icon_info = icon_theme.lookup_icon ("applications-other", size, Gtk.IconLookupFlags.FORCE_SIZE);
                    return icon_info.load_icon ();
                } catch (Error e) {
                    stderr.printf ("%s\n", e.message);
                }
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
            }

            return null;
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreePath path = new Gtk.TreePath.first ();
            Gtk.TreeSelection selection = item_view.get_selection ();

            selection.set_mode (SelectionMode.SINGLE);
            selection.select_path (path);
        }

        // switch to window
        public void execute_app_from_selection (Gtk.TreeIter selection) {
            string id;
            filter.@get (selection, ITEM_VIEW_COLUMN_ID, out id);

            execute_app (id);
        }

        // i3-msg [window_role="gnome-terminal-window-6bee2ec0-eb8b-4b10-aafc-7c2708201d43" title="Terminal"] focus
        private void execute_app (string id) {
            string exec = "[con_id=\"" + id + "\"] focus";
            string commandline = "/usr/bin/i3-msg " + exec;

            stdout.printf("running %s\n", commandline);

            try {
                var app_info = AppInfo.create_from_commandline (commandline, null, AppInfoCreateFlags.NONE);

                if (!app_info.launch (null, null)) {
                    stderr.printf ("Error: execute_keybinding failed\n");
                }
            } catch (GLib.Error err) {
                stderr.printf ("Error: execute_keybinding failed: %s\n", err.message);
            }
        }
    }
}