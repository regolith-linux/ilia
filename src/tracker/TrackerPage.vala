using Gtk;

namespace Ilia {
    // A dialog page that lists system commands on the path and allows for free-from launching in a terminal.
    class TrackerPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 2;
        private const int ITEM_VIEW_COLUMN_TITLE = 0;
        private const int ITEM_VIEW_COLUMN_FILE = 1;

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
            return "Files";
        }

        public string get_icon_name () {
            return "applications-other";
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            // load_apps ();
            model.set_sort_column_id (0, SortType.ASCENDING);
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
            item_view.insert_column_with_attributes (-1, "Title", new CellRendererText (), "text", ITEM_VIEW_COLUMN_TITLE);
            item_view.insert_column_with_attributes (-1, "Path", new CellRendererText (), "text", ITEM_VIEW_COLUMN_FILE);

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
            if (entry.get_text ().length > 2) {
                model.clear ();
                load_apps ();
                filter.refilter ();
                set_selection ();
            }
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
                // TODO: Add 'path' to filter selection
                model.get_value (iter, ITEM_VIEW_COLUMN_FILE, out app_info);
                strval = app_info.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        // tracker sparql -q "SELECT DISTINCT nie:url(?f) nie:title(?f) WHERE { ?f fts:match 'regolith' }"
        private void load_apps () {
            try {
                var queryterm = entry.get_text ();
                var connection = Tracker.Sparql.Connection.get ();
                var query = "SELECT DISTINCT nie:url(?f) nie:title(?f) WHERE { ?f fts:match '" + queryterm + "' }";
                stdout.printf ("query: %s\n", query);
                var cursor = connection.query (query);
                long length = 0;

                do {
                    var uri = cursor.get_string (0, out length);

                    if (uri != null) {
                        var title = cursor.get_string (1, out length);

                        stdout.printf ("got %s %s\n", uri, title);

                        if (title == null) {
                            title = Path.get_basename (uri);
                        }

                        stdout.printf ("got %s %s\n", uri, title);

                        model.append (out iter);
                        model.set (
                            iter,
                            ITEM_VIEW_COLUMN_TITLE, title,
                            ITEM_VIEW_COLUMN_FILE, uri.substring (7)
                        );
                    }
                } while (cursor.next ());
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
            }
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
            string file;
            filter.@get (selection, ITEM_VIEW_COLUMN_FILE, out file);

            execute_app (file);
        }

        // tracker sparql -q "SELECT DISTINCT nie:url(?f) nie:title(?f) WHERE { ?f fts:match 'regolith' }"
        private void execute_app (string id) {
            string exec = "[con_id=\"" + id + "\"] focus";
            string commandline = "/usr/bin/i3-msg " + exec;

            stdout.printf ("running %s\n", commandline);

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