using Gtk;

namespace Ilia {
    class TextListPage : DialogPage, GLib.Object {
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

        public string get_name () {
            return "TextList";
        }

        public string get_icon_name () {
            return "utilities-terminal";
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_apps ();
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
            item_view.insert_column_with_attributes (-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

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
                execute_app (entry.text);
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
                model.get_value (iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        private void load_apps () {
            string ? name = null;

            do {
                name = stdin.read_line ();
                if (name != null) {
                    model.append (out iter);
                    model.set (
                        iter,
                        ITEM_VIEW_COLUMN_NAME, name
                    );
                }
            } while (name != null);
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
            filter.@get (selection, ITEM_VIEW_COLUMN_NAME, out cmd_path);
            
            if (cmd_path != null) execute_app(cmd_path);
        }

        private void execute_app (string cmd_path) {            
            session_controller.quit();
        }
    }
}