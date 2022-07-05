using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 4;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_KEYWORDS = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;

        // Number of past launches to store (to determine sort rank)
        private const uint HISTORY_MAX_LEN = 32;
        // Max number of files to read in sequence before yeilding
        private const int FS_FILE_READ_COUNT = 128;
        // Roots of app dirs env var.  See https://github.com/flatpak/flatpak/issues/1286#issuecomment-354554684
        private const string XDG_DATA_DIRS = "XDG_DATA_DIRS";

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // Access state from model
        private Gtk.TreeIter iter;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;
        // Active icon theme
        private Gtk.IconTheme icon_theme;

        private Gtk.Entry entry;

        private GLib.Settings settings;

        private SessionContoller session_controller;

        private string[] launch_history;

        private HashTable<string, int> launch_counts;

        private int icon_size;

        private int post_launch_sleep;

        private Gtk.Widget root_widget;

        public string get_name () {
            return "<u>A</u>pplications";
        }

        public string get_icon_name () {
            return "system-run";
        }

        public string get_help () {
            return "This dialog allows for the launching of desktop applications. Initially all desktop apps are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will launch it.";
        }

        public char get_keybinding() {
            return 'a';
        }

        public HashTable<string, string>? get_keybindings() {
            var keybindings = new HashTable<string, string ? >(str_hash, str_equal);

            keybindings.set("enter", "Launch Application");            

            return keybindings;
        }

        public async void initialize (GLib.Settings settings, HashTable<string, string ? > arg_map, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.settings = settings;
            this.entry = entry;
            this.session_controller = sessionController;

            launch_history = settings.get_strv ("app-launch-counts");
            launch_counts = load_launch_counts (launch_history);
            icon_size = settings.get_int ("icon-size");
            post_launch_sleep = settings.get_int("post-launch-sleep");

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (DesktopAppInfo));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_apps.begin ((obj, res) => {
                load_apps.end (res);

                model.set_sort_func (1, app_sort_func);
                model.set_sort_column_id (1, SortType.ASCENDING);

                set_selection ();
            });

            var scrolled = new Gtk.ScrolledWindow (null, null);            
            scrolled.get_style_context ().add_class ("scrolled_window");
            scrolled.add (item_view);
            scrolled.expand = true;

            root_widget = scrolled;
        }

        public Gtk.Widget get_root () {
            return root_widget;
        }

        public bool key_event(Gdk.EventKey event_key) {
            return false;
        }

        // Initialize the view displaying selections
        private void create_item_view () {
            item_view = new Gtk.TreeView.with_model (filter);            
            item_view.get_style_context ().add_class ("item_view");
            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            if (icon_size > 0) {
                item_view.insert_column_with_attributes (-1, "Icon", new CellRendererPixbuf (), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            }
            item_view.insert_column_with_attributes (-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public void grab_focus (uint keycode) {
            item_view.grab_focus ();
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            execute_app (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            model.set_sort_func (1, app_sort_func);
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            if (filter.get_iter_first (out iter)) {
                execute_app (iter);
            }
        }

        private int app_sort_func (TreeModel model, TreeIter a, TreeIter b) {
            string query_string = entry.get_text ().down ().strip ();
            DesktopAppInfo app_a;
            model.@get (a, ITEM_VIEW_COLUMN_APPINFO, out app_a);
            DesktopAppInfo app_b;
            model.@get (b, ITEM_VIEW_COLUMN_APPINFO, out app_b);

            var app_a_has_prefix = app_a.get_name ().down ().has_prefix (query_string);
            var app_b_has_prefix = app_b.get_name ().down ().has_prefix (query_string);

            if (query_string.length > 1 && (app_a_has_prefix || app_b_has_prefix)) {
                if (app_b_has_prefix && !app_b_has_prefix) {
                    // stdout.printf ("boosted %s\n", app_a.get_name ());
                    return -1;
                } else if (!app_a_has_prefix && app_b_has_prefix) {
                    // stdout.printf ("boosted %s\n", app_b.get_name ());
                    return 1;
                }
            }

            var a_count = launch_counts.get (app_a.get_id ());
            var b_count = launch_counts.get (app_b.get_id ());

            if (a_count > 0 || b_count > 0) {
                if (a_count > b_count) {
                    return -1;
                } else if (a_count < b_count) {
                    return 1;
                } else {
                    return 0;
                }
            }

            return app_a.get_name ().ascii_casecmp (app_b.get_name ());
        }

        private HashTable<string, int> load_launch_counts (string[] history) {
            var table = new HashTable<string, int>(str_hash, str_equal);

            for (int i = 0; i < history.length; ++i) {
                var app_name = history[i];
                if (table.contains (app_name)) {
                    table.replace (app_name, table.get (app_name) + 1);
                } else {
                    table.insert (app_name, 1);
                }
            }

            /*
            table.foreach ((key, val) => {
                print ("%s => %d\n", key, val);
            });
             */

            return table;
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string query_string = entry.get_text ().down ().strip ();

            if (query_string.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string ();

                if (strval != null && strval.down ().contains (query_string)) return true;

                model.get_value (iter, ITEM_VIEW_COLUMN_KEYWORDS, out app_info);
                strval = app_info.get_string ();

                return strval != null && strval.down ().contains (query_string);
            } else {
                return true;
            }
        }

        private async void load_apps () {
            // determine theme for icons
            icon_theme = Gtk.IconTheme.get_default ();

            var app_dirs = find_app_dirs();

            foreach (string app_dir in app_dirs) { 
                // populate model with desktop apps from known locations
                var system_app_dir = File.new_for_path (app_dir);
                if (system_app_dir.query_exists ()) yield load_apps_from_dir (system_app_dir);
            }
        }

        // Read locations of desktop app file paths from OS via env variable, fallback to const
        private string[] find_app_dirs() {
            // FIXME: replace with get_system_data_dirs
            var app_dir_roots = Environment.get_variable(XDG_DATA_DIRS);

            // Handle edge case of no env data for dirs
            if (app_dir_roots == null || app_dir_roots.length == 0) {
                string[] rv = new string[1];
                rv[0] = "/usr/share/applications";
    
                return rv;
            }

            string[] root_paths = app_dir_roots.split (":");
            string[] app_paths = new string[root_paths.length];
            int index = 0;

            foreach (unowned string root_path in root_paths) {
                app_paths[index] = root_path + "/applications";

                index++;
            }

            return app_paths;            
        }

        private async void load_apps_from_dir (File app_dir) {
            try {
                var enumerator = yield app_dir.enumerate_children_async (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT);

                while (true) {
                    var app_files = yield enumerator.next_files_async (FS_FILE_READ_COUNT, Priority.DEFAULT);

                    if (app_files == null) {
                        break;
                    }

                    foreach (var info in app_files) {
                        string file_path = app_dir.get_child (info.get_name ()).get_path ();
                        yield read_desktop_file (file_path);
                    }
                }
            } catch (Error err) {
                stderr.printf ("Error: list_files failed: %s\n", err.message);
            }
        }

        private async void read_desktop_file (string desktopPath) {
            DesktopAppInfo app_info = new DesktopAppInfo.from_filename (desktopPath);

            if (app_info != null && app_info.should_show ()) {
                model.append (out iter);

                var icon = app_info.get_icon ();
                string icon_name = null;
                if (icon != null) icon_name = icon.to_string ();

                var comment = app_info.get_string ("Comment");
                var keywords = app_info.get_string ("Keywords");

                Gdk.Pixbuf icon_img = null;

                if (icon_size > 0) {
                    icon_img = yield Ilia.load_icon_from_info_async (icon_theme, app_info, icon_size);

                    model.set (
                        iter,
                        ITEM_VIEW_COLUMN_ICON, icon_img,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name (),
                        ITEM_VIEW_COLUMN_KEYWORDS, comment + keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
                } else {
                    model.set (
                        iter,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name (),
                        ITEM_VIEW_COLUMN_KEYWORDS, comment + keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
                }
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
        public void execute_app (Gtk.TreeIter selection) {            
            DesktopAppInfo app_info;
            filter.@get (selection, ITEM_VIEW_COLUMN_APPINFO, out app_info);

            try {
                var result = app_info.launch_uris (null, null);

                if (result) {
                    string key = app_info.get_id ();
                    if (launch_history == null) {
                        launch_history = { key };
                    } else {
                        launch_history += key;
                    }

                    if (launch_history.length <= HISTORY_MAX_LEN) {
                        settings.set_strv ("app-launch-counts", launch_history);
                    } else {
                        settings.set_strv ("app-launch-counts", launch_history[1 : HISTORY_MAX_LEN]);
                    }
                } else {
                    stderr.printf ("Failed to launch %s\n", app_info.get_name ());
                }
                GLib.Thread.usleep(post_launch_sleep);
                session_controller.quit ();
            } catch (GLib.Error e) {
                stderr.printf ("%s\n", e.message);
            }
        }
    }
}
