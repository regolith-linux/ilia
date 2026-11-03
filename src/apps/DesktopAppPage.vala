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

        // The desktop files, enumerated on a worker thread started as early as possible so that
        // the parse overlaps with GTK's own startup (theme CSS, fontconfig). Handed to the main
        // thread through an idle callback; only the main thread touches these fields.
        private static bool prefetch_started = false;
        private static GLib.List<AppInfo> ? prefetched_apps = null;
        private static SourceFunc ? prefetch_waiter = null;

        public static void prefetch_apps() {
            if (prefetch_started) return;
            prefetch_started = true;
            new Thread<void *>("ilia-apps", () => {
                var list = AppInfo.get_all();
                Idle.add(() => {
                    prefetched_apps = (owned) list;
                    if (prefetch_waiter != null) {
                        var waiter = (owned) prefetch_waiter;
                        waiter();
                    }
                    return false;
                }, Priority.HIGH);
                return null;
            });
        }

        private async GLib.List<AppInfo> get_app_list() {
            prefetch_apps();
            if (prefetched_apps == null) {
                prefetch_waiter = get_app_list.callback;
                yield;
            }
            return (owned) prefetched_apps;
        }

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

            create_item_view();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;

            // The window is built and shown while the desktop files are still being read
            var app_list = yield get_app_list();
            load_apps(app_list);

            model.set_sort_func(1, app_sort_func);
            model.set_sort_column_id(1, SortType.ASCENDING);

            set_selection();

            // Load app icons once the list is on screen. The model must only be
            // accessed from the GTK main thread: walking it from another thread races
            // with the re-sort done on every keystroke (ilia#78, ilia#90).
            if (icon_size > 0)
                Idle.add(() => { start_icon_loading(); return false; }, Priority.DEFAULT_IDLE);
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        public bool key_event(Gdk.EventKey key) {
            return handle_emacs_vim_nav(item_view, path, key);
        }

        // Highlight the first row: the best match for the text typed
        private void set_selection() {
            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            if (path == null)
                path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
        }

        public void show() {
            item_view.grab_focus ();
            debug("DesktopAppPage ready to accept keystrokes (%.3f seconds since app start)", app_timer.elapsed());
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.get_style_context().add_class("item_view");
            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Disable Gtk search
            item_view.enable_search = false;

            // Create columns
            if (icon_size > 0)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ITEM_VIEW_COLUMN_NAME);

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
            filter.refilter();
            set_selection();
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


            return table;
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string query_string = entry.get_text().down().strip();

            if (query_string.length > 0) {
                GLib.Value app_info;
                model.get_value(iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                string name = app_info.get_string();

                model.get_value(iter, ITEM_VIEW_COLUMN_KEYWORDS, out app_info);
                string keywords = app_info.get_string();

                // Each word may match either the name or the keywords
                return matches_all_words(query_string, { name, keywords });
            } else {
                return true;
            }
        }

        private void load_apps(GLib.List<AppInfo> app_list) {
            // determine theme for icons
            icon_theme = Gtk.IconTheme.get_default();
            // Set a blank icon to avoid visual jank as real icons are loaded. It stays for apps
            // without a loadable icon, so it must be transparent (a new pixbuf is not cleared).
            Gdk.Pixbuf ? blank_icon = null;
            if (icon_size > 0) {
                blank_icon = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, icon_size, icon_size);
                blank_icon.fill(0x00000000);
            }

            foreach (AppInfo appinfo in app_list) {
                read_desktop_file(appinfo as DesktopAppInfo, blank_icon);
            }
            debug("Finished loading all apps (%.3f seconds since app start)", app_timer.elapsed());
        }

        // app_info is the object from AppInfo.get_all(): creating a new DesktopAppInfo from the
        // id would parse the desktop file a second time
        private void read_desktop_file(DesktopAppInfo ? app_info, Gdk.Pixbuf ? icon_img) {
            if (app_info != null && app_info.should_show()) {
                model.append(out iter);

                var keywords = desktop_app_search_text(app_info);

                if (icon_size > 0)
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_ICON, icon_img,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name(),
                        ITEM_VIEW_COLUMN_KEYWORDS, keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
                else
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name(),
                        ITEM_VIEW_COLUMN_KEYWORDS, keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
            }
        }

        // Icons are looked up on the main thread (the theme cache makes that cheap) and decoded
        // on GTK's worker threads, a few at a time. Rows are queued in the order they are shown
        // so the visible rows get their icons first.
        private const int ICON_LOAD_PARALLELISM = 4;
        private TreeIter[] icon_queue = {};
        private int icon_queue_next = 0;
        private int icons_in_flight = 0;

        private void start_icon_loading() {
            TreeIter filter_iter;
            for (bool next = filter.get_iter_first(out filter_iter); next; next = filter.iter_next(ref filter_iter)) {
                TreeIter child_iter;
                filter.convert_iter_to_child_iter(out child_iter, filter_iter);
                icon_queue += child_iter;
            }
            for (int i = 0; i < ICON_LOAD_PARALLELISM; ++i)
                load_next_icon();
        }

        private void load_next_icon() {
            while (icon_queue_next < icon_queue.length) {
                var iter = icon_queue[icon_queue_next++];

                Value app_info_val;
                model.get_value(iter, ITEM_VIEW_COLUMN_APPINFO, out app_info_val);
                var icon = ((DesktopAppInfo) app_info_val.get_object()).get_icon();
                if (icon == null) continue;

                var icon_info = icon_theme.lookup_by_gicon(icon, icon_size, Gtk.IconLookupFlags.FORCE_SIZE);
                if (icon_info == null) continue;

                icons_in_flight++;
                icon_info.load_icon_async.begin(null, (obj, res) => {
                    try {
                        var pixbuf = icon_info.load_icon_async.end(res);
                        // GtkListStore iterators persist across re-sorting and rows are never removed
                        model.set(iter, ITEM_VIEW_COLUMN_ICON, pixbuf);
                    } catch (Error e) {
                        debug("Icon not loaded: %s", e.message);
                    }
                    icons_in_flight--;
                    load_next_icon();
                });
                return;
            }
            if (icons_in_flight == 0)
                debug("Finished loading all icons (%.3f seconds since app start)", app_timer.elapsed());
        }

        // In the case that neither success or failure signals are received, exit after a timeout
        private async void launch_failure_exit() {
            GLib.Timeout.add(post_launch_sleep, () => {
                session_controller.quit();
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
                AppLaunchContext ctx = new AppLaunchContext();

                ctx.launched.connect((info, platform_data) => {
                    session_controller.quit();
                });

                ctx.launch_failed.connect((startup_notify_id) => {
                    stderr.printf("Failed to launch app: %s\n", startup_notify_id);
                    session_controller.quit();
                });


                ctx.launch_started.connect((info, platform_data) => {
                    launch_failure_exit.begin();
                    // TODO ~ perhaps add some visual hint that launch process has begun
                });

                var result = runner.launch(null, ctx);

                if (result) {
                    string key = app_info.get_id();
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
                    stderr.printf("Failed to launch %s\n", app_info.get_name());
                    session_controller.quit();
                }
            } catch (GLib.Error e) {
                stderr.printf("%s\n", e.message);
                session_controller.quit();
            }
        }
    }
}
