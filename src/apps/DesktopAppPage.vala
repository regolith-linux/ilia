using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage, GLib.Object {
        private static GLib.Timer app_timer;
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

        private Gtk.TreePath path;

        private Thread<void> iconLoadThread;

        public string get_name() {
            return "<u>A</u>pplications";
        }

        public string get_icon_name() {
            return "system-run";
        }

        public string get_help() {
            return "This dialog allows for the launching of desktop applications. Initially all desktop apps are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will launch it.";
        }

        public char get_keybinding() {
            return 'a';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Launch Application");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            app_timer = new GLib.Timer();
            app_timer.start();
            this.settings = settings;
            this.entry = entry;
            this.session_controller = sessionController;

            launch_history = settings.get_strv("app-launch-counts");
            launch_counts = load_launch_counts(launch_history);
            icon_size = settings.get_int("icon-size");
            post_launch_sleep = settings.get_int("post-launch-sleep");

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (DesktopAppInfo));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view ();

            load_apps ();

            model.set_sort_func(1, app_sort_func);
            model.set_sort_column_id(1, SortType.ASCENDING);

            set_selection ();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context ().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;

            // Load app icons in background thread
            iconLoadThread = new Thread<void>("iconLoadThread", loadAppIcons);
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        public bool key_event(Gdk.EventKey key) {
            return handle_emacs_vim_nav(item_view, path, key);
        }

        // Automatically set the first item in the list as selected.
        private void set_selection() {
            Gtk.TreeSelection selection = item_view.get_selection ();

            if (selection.count_selected_rows () == 0) { // initial state, nothing explicitly selected by user
                selection.set_mode(SelectionMode.SINGLE);
                if (path == null)
                    path = new Gtk.TreePath.first ();
                selection.select_path(path);
            } else { // an existing item has selection, ensure it's visible
                var path_list = selection.get_selected_rows(null);
                if (path_list != null) {
                    unowned var element = path_list.first ();
                    item_view.scroll_to_cell(element.data, null, false, 0f, 0f);
                }
            }
        }

        public void show() {
            item_view.grab_focus ();
            debug("DesktopAppPage ready to accept keystrokes (%.3f seconds since app start)", app_timer.elapsed());
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.get_style_context ().add_class("item_view");
            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Disable Gtk search
            item_view.enable_search = false;

            // Create columns
            if (icon_size > 0)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf (), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            filter.get_iter(out iter, row_path);
            execute_app(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            // Cause resorting
            // TODO: find cleaner way of causing re-sort
            model.set_sort_func(1, app_sort_func);
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (filter.get_iter(out iter, path))
                execute_app(iter);
        }

        /**
         * Sort function for the application list
         *
         * This is a wrapper around the testable compare_desktop_apps utility function
         * that extracts the necessary data from the TreeModel and TreeIter objects
         */
        private int app_sort_func(TreeModel model, TreeIter a, TreeIter b) {
            string query_string = entry.get_text().down();

            DesktopAppInfo app_a;
            model.@get(a, ITEM_VIEW_COLUMN_APPINFO, out app_a);
            DesktopAppInfo app_b;
            model.@get(b, ITEM_VIEW_COLUMN_APPINFO, out app_b);

            var app_a_name = app_a.get_name().down();
            var app_b_name = app_b.get_name().down();

            var app_a_id = app_a.get_id();
            var app_b_id = app_b.get_id();

            return compare_desktop_apps(
                app_a_name,
                app_b_name,
                app_a_id,
                app_b_id,
                query_string,
                launch_counts
            );
        }

        private HashTable<string, int> load_launch_counts(string[] history) {
            var table = new HashTable<string, int>(str_hash, str_equal);

            for (int i = 0; i < history.length; ++i) {
                var app_name = history[i];
                if (table.contains(app_name))
                    table.replace(app_name, table.get(app_name) + 1);
                else
                    table.insert(app_name, 1);
            }

            /*
               table.foreach ((key, val) => {
                print ("%s => %d\n", key, val);
               });
             */

            return table;
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string query_string = entry.get_text ().down ().strip ();

            if (query_string.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value(iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string ();

                if (strval != null && strval.down ().contains(query_string))return true;

                model.get_value(iter, ITEM_VIEW_COLUMN_KEYWORDS, out app_info);
                strval = app_info.get_string ();

                return strval != null && strval.down ().contains(query_string);
            } else {
                return true;
            }
        }

        private void load_apps() {
            // determine theme for icons
            icon_theme = Gtk.IconTheme.get_default ();
            // Set a blank icon to avoid visual jank as real icons are loaded
            Gdk.Pixbuf blank_icon = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, icon_size, icon_size);

            var app_list = AppInfo.get_all ();
            foreach (AppInfo appinfo in app_list) {
                read_desktop_file(appinfo, blank_icon);
            }
            debug("Finished loading all apps (%.3f seconds since app start)", app_timer.elapsed());
        }

        private void read_desktop_file(AppInfo appInfo, Gdk.Pixbuf ? icon_img) {
            DesktopAppInfo app_info = new DesktopAppInfo(appInfo.get_id ());

            if (app_info != null && app_info.should_show ()) {
                model.append(out iter);

                var keywords = app_info.get_string("Comment") + app_info.get_string("Keywords");

                if (icon_size > 0)
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_ICON, icon_img,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name (),
                        ITEM_VIEW_COLUMN_KEYWORDS, keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
                else
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name (),
                        ITEM_VIEW_COLUMN_KEYWORDS, keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
            }
        }

        void loadAppIcons() {
            load_icons_async.begin((obj, res) => {
                try {
                    load_icons_async.end(res);
                } catch (Error e) {
                    stderr.printf("Error loading icons: %s\n", e.message);
                }
            });
        }
        
        // Asynchronously load icons with idle priority to avoid UI blocking
        private async void load_icons_async() throws Error {
            // Store iterators in a standard array
            TreeIter[] iterators = {};
            TreeIter app_iter;
            
            // First collect all iterators
            for (bool next = model.get_iter_first(out app_iter); next; next = model.iter_next(ref app_iter)) {
                iterators += app_iter;
            }
            
            foreach (TreeIter iter in iterators) {
                // Yield to main loop after each icon to keep UI maximally responsive
                Idle.add(load_icons_async.callback);
                yield;
                
                // Load the icon
                Value app_info_val;
                model.get_value(iter, ITEM_VIEW_COLUMN_APPINFO, out app_info_val);
                
                Gdk.Pixbuf? icon = Ilia.load_icon_from_info(
                    icon_theme,
                    (DesktopAppInfo) app_info_val,
                    icon_size
                );
                
                // Update the model with the loaded icon if successful
                if (icon != null) {
                    Idle.add(() => {
                        model.set(
                            iter,
                            ITEM_VIEW_COLUMN_ICON, icon
                        );
                        return false;
                    });
                }
            }
            debug("Finished loading all icons (%.3f seconds since app start)", app_timer.elapsed());
        }

        // In the case that neither success or failure signals are received, exit after a timeout
        private async void launch_failure_exit() {
            GLib.Timeout.add(post_launch_sleep, () => {
                session_controller.quit ();
                return false;
            }, GLib.Priority.DEFAULT);
            yield;
        }

        // launch a desktop app
        public void execute_app(Gtk.TreeIter selection) {
            DesktopAppInfo app_info;
            filter.@get(selection, ITEM_VIEW_COLUMN_APPINFO, out app_info);

            try {
                AppInfo runner = get_runner_app_info(app_info);
                AppLaunchContext ctx = new AppLaunchContext ();

                ctx.launched.connect((info, platform_data) => {
                    session_controller.quit ();
                });

                ctx.launch_failed.connect((startup_notify_id) => {
                    stderr.printf("Failed to launch app: %s\n", startup_notify_id);
                    session_controller.quit ();
                });


                ctx.launch_started.connect((info, platform_data) => {
                    launch_failure_exit.begin ();
                    // TODO ~ perhaps add some visual hint that launch process has begun
                });

                var result = runner.launch(null, ctx);

                if (result) {
                    string key = app_info.get_id ();
                    if (launch_history == null) {
                        launch_history = { key };
                    } else {
                        launch_history += key;
                    }

                    if (launch_history.length <= HISTORY_MAX_LEN)
                        settings.set_strv("app-launch-counts", launch_history);
                    else
                        settings.set_strv("app-launch-counts", launch_history[1 : HISTORY_MAX_LEN]);
                } else {
                    stderr.printf("Failed to launch %s\n", app_info.get_name ());
                    session_controller.quit ();
                }
            } catch (GLib.Error e) {
                stderr.printf("%s\n", e.message);
                session_controller.quit ();
            }
        }
    }
}
