using Gtk;

namespace Ilia {
    class TextListPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 2;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;

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

        private string name = "TextList";

        private string icon = "utilities-terminal";

        public string get_name () {
            return name;
        }

        public string get_icon_name () {
            return icon;
        }

        public string get_help () {
            return "This dialog presents a filterable list of items to select from.";
        }

        public char get_keybinding() {
            // FIXME - this is never used
            return 't';
        }

        public HashTable<string, string>? get_keybindings() {
            var keybindings = new HashTable<string, string ? >(str_hash, str_equal);

            keybindings.set("enter", "Select Item");            

            return keybindings;
        }

        public async void initialize (GLib.Settings settings, HashTable<string, string ? > arg_map, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            if (arg_map.contains("-l")) {
                this.name = arg_map.get("-l");
            }
            if (arg_map.contains("-i")) {
                this.icon = arg_map.get("-i");
            }

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_items (settings.get_int ("icon-size"));
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
            item_view.insert_column_with_attributes (-1, "Icon", new CellRendererPixbuf (), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes (-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public bool key_event (Gdk.EventKey event_key) {
            var keycode = event_key.keyval;

            if (keycode == Ilia.KEY_CODE_ENTER && !filter.get_iter_first (out iter) && entry.text.length > 0) {
                print (entry.text);
                return true;
            }

            return false;
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            print_selection (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            if (filter.get_iter_first (out iter)) {
                print_selection (iter);
            }
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text ().down ().strip ();

            if (queryString.length > 0) {
                GLib.Value item_value;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_NAME, out item_value);
                strval = item_value.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        private void load_items (int icon_size) {
            string? name = null;
            var icon_theme = Gtk.IconTheme.get_default ();

            Gdk.Pixbuf? pixbuf = null;
            if (icon != null && icon.length > 0) {
                pixbuf = Ilia.load_icon_from_name (icon_theme, icon, icon_size);
            } 

            if (pixbuf == null) {
                pixbuf = Ilia.load_icon_from_name (icon_theme, "applications-other", icon_size);
            }

            do {
                name = stdin.read_line ();
                if (name != null) {
                    model.append (out iter);
                    model.set (
                        iter,
                        ITEM_VIEW_COLUMN_ICON, pixbuf,
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
        public void print_selection (Gtk.TreeIter selection) {
            string cmd_path;
            filter.@get (selection, ITEM_VIEW_COLUMN_NAME, out cmd_path);
            
            if (cmd_path != null) print(cmd_path);
        }

        private void print (string selection) {        
            stdout.printf("%s\n", selection);

            session_controller.quit();
        }
    }
}
