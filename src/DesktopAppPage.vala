using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage {
        private const int ITEM_VIEW_COLUMNS = 4;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_KEYWORDS = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;

        // Number of past launches to store (to determine sort rank)
        private const uint HISTORY_MAX_LEN = 32;        
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
        // Active icon theme
        private Gtk.IconTheme icon_theme;

        private Gtk.Entry entry;

        private GLib.Settings settings;

        private SessionContoller session_controller;

        private string[] launch_counts;
        
        private int icon_size;
        
        public Gtk.Widget initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) {
            this.settings = settings;
            this.entry = entry;
            this.session_controller = sessionController;

            launch_counts = settings.get_strv ("app-launch-counts");
            icon_size = settings.get_int ("icon-size");

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (DesktopAppInfo));
            model.set_sort_column_id (1, SortType.ASCENDING);
            model.set_sort_func (1, app_sort_func);

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            load_apps.begin ();

            create_item_view ();

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (item_view);
            scrolled.expand = true;

            return scrolled;
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
            if (icon_size > 0) {
                item_view.insert_column_with_attributes (-1, "Icon", new CellRendererPixbuf (), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            }
            item_view.insert_column_with_attributes (-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public void grab_focus () {
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
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            filter.get_iter_first (out iter);
            execute_app (iter);
        }

        private int app_sort_func (TreeModel model, TreeIter a, TreeIter b) {
            DesktopAppInfo app_a;
            model.@get (a, ITEM_VIEW_COLUMN_APPINFO, out app_a);
            DesktopAppInfo app_b;
            model.@get (b, ITEM_VIEW_COLUMN_APPINFO, out app_b);

            var a_count = app_count (app_a);
            var b_count = app_count (app_b);

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

        private int app_count (DesktopAppInfo app) {
            var count = 0;
            for (int i = 0; i < launch_counts.length; ++i) {
                if (launch_counts[i] == app.get_id ()) count++;
            }

            return count;
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text ().down ().strip ();

            if (queryString.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string ();

                if (strval != null && strval.down ().contains (queryString)) return true;

                model.get_value (iter, ITEM_VIEW_COLUMN_KEYWORDS, out app_info);
                strval = app_info.get_string ();

                return strval != null && strval.down ().contains (queryString);
            } else {
                return true;
            }
        }

        private async void load_apps () {
            // determine theme for icons
            icon_theme = Gtk.IconTheme.get_default ();

            // populate model with desktop apps from known locations
            var system_app_dir = File.new_for_path ("/usr/share/applications");
            if (system_app_dir.query_exists ()) yield load_apps_from_dir (system_app_dir);

            // ~/.local/share/applications
            var home_dir = File.new_for_path (Environment.get_home_dir ());
            var local_app_dir = home_dir.get_child (".local").get_child ("share").get_child ("applications");
            if (local_app_dir.query_exists ()) yield load_apps_from_dir (local_app_dir);

            set_selection ();
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
                    icon_img = yield load_icon (icon_name, icon_size);

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

        private async Gdk.Pixbuf ? load_icon (string ? icon_name, int size) {
            Gtk.IconInfo icon_info;

            try {
                if (icon_name == null) {
                    icon_info = icon_theme.lookup_icon ("application-x-executable", size, Gtk.IconLookupFlags.FORCE_SIZE);
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
                    icon_info = icon_theme.lookup_icon ("application-x-executable", size, Gtk.IconLookupFlags.FORCE_SIZE);
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

        // launch a desktop app
        public void execute_app (Gtk.TreeIter selection) {            
            session_controller.launched ();

            DesktopAppInfo app_info;
            filter.@get (selection, ITEM_VIEW_COLUMN_APPINFO, out app_info);

            AppLaunchContext ctx = new AppLaunchContext ();

            ctx.launch_failed.connect ((startup_notify_id) => {
                stderr.printf ("Failed to launch %s(%n)\n", app_info.get_name (), startup_notify_id);
            });

            try {
                var result = app_info.launch (null, null);

                if (result) {
                    string key = app_info.get_id ();
                    if (launch_counts == null) {
                        launch_counts = { key };
                    } else {
                        launch_counts += key;
                    }

                    if (launch_counts.length <= HISTORY_MAX_LEN) {
                        settings.set_strv ("app-launch-counts", launch_counts);
                    } else {
                        settings.set_strv ("app-launch-counts", launch_counts[1 : HISTORY_MAX_LEN]);
                    }
                } else {
                    stderr.printf ("Failed to launch %s\n", app_info.get_name ());
                }                
            } catch (GLib.Error e) {
                stderr.printf ("%s\n", e.message);
            }            
        }
    }
}