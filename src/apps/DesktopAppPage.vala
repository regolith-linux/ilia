using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage, GLib.Object {
        private static GLib.Timer app_timer;
        private const int ITEM_VIEW_COLUMNS = 4;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_MATCH = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;

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

        // Starts the chosen app and closes ilia
        private AppLauncher launcher;

        private HashTable<string, int> launch_counts;

        private int icon_size;

        // Rows that fail the word rule are shown when the words are subsequences of the name
        private bool fuzzy_matching;

        // Desktop ids and patterns of the apps that are never listed
        private string[] hidden_apps;

        // The fields of an app that filtering uses: the name and those in match-fields
        private AppField match_fields;

        // The filter text the rows were last ranked for, and its words
        private string ? ranked_text = null;
        private string[] ranked_words = {};

        private Gtk.Widget root_widget;

        private Gtk.TreePath path;

        // The desktop files, enumerated on a worker thread started as early as possible so that
        // the parse overlaps with GTK's own startup (theme CSS, fontconfig). Handed to the main
        // thread through an idle callback; only the main thread touches these fields.
        private static bool prefetch_started = false;
        private static bool prefetch_done = false;
        private static GLib.List<AppInfo> ? prefetched_apps = null;
        private static SourceFunc ? prefetch_waiter = null;

        // Set once the desktop files are in the model
        private bool apps_loaded = false;
        // Enter was pressed before the list arrived: launch the best match once it has
        private bool activate_when_loaded = false;

        public static void prefetch_apps() {
            if (prefetch_started) return;
            prefetch_started = true;
            new Thread<void *>("ilia-apps", () => {
                var list = AppInfo.get_all();
                Idle.add(() => {
                    prefetched_apps = (owned) list;
                    prefetch_done = true;
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
            if (!prefetch_done) {
                prefetch_waiter = get_app_list.callback;
                yield;
            }
            return (owned) prefetched_apps;
        }

        public string get_name() {
            return "<u>A</u>pplications";
        }

        public string get_icon_name() {
            return "view-app-grid-symbolic";
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
            keybindings.set("ctrl+delete", "Hide Application");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            app_timer = new GLib.Timer();
            app_timer.start();
            this.settings = settings;
            this.entry = entry;
            launcher = new AppLauncher(settings, sessionController);

            launch_counts = load_launch_counts(settings.get_strv("app-launch-counts"));
            icon_size = settings.get_int("icon-size");
            fuzzy_matching = settings.get_boolean("fuzzy-matching");
            hidden_apps = settings.get_strv("hidden-apps");
            match_fields = AppField.NAME | AppField.from_names(settings.get_strv("match-fields"));

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (AppMatch), typeof (DesktopAppInfo));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;

            // Keys can arrive before the list does: the navigation handler needs a path
            set_selection();

            // The window is built and shown while the desktop files are still being read
            var app_list = yield get_app_list();

            load_apps(app_list);

            model.set_sort_func(1, app_sort_func);
            model.set_sort_column_id(1, SortType.ASCENDING);

            set_selection();
            apps_loaded = true;
            if (activate_when_loaded)
                on_entry_activated();

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
            if (!apps_loaded && is_enter_key(key.keyval)) {
                activate_when_loaded = true;
                return true;
            }
            if (key.keyval == Gdk.Key.Delete && (key.state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                // Taken whether or not a row is highlighted: it never edits the filter here
                hide_selected_app();
                return true;
            }
            return handle_emacs_vim_nav(item_view, path, key);
        }

        /**
         * Hide the highlighted app: add its desktop id to the hidden-apps setting, unless
         * it is listed already, and take its row out of the list. The row that takes its
         * place is highlighted, or the new last row when it was the last.
         *
         * The setting is read again rather than taken from startup, so the id is added to
         * the list as it is stored now.
         */
        private void hide_selected_app() {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter selected;
            if (!item_view.get_selection().get_selected(out selected_model, out selected))
                return;

            AppMatch match;
            filter.@get(selected, ITEM_VIEW_COLUMN_MATCH, out match);
            if (match == null)
                return;
            var position = filter.get_path(selected);

            string[] hidden = settings.get_strv("hidden-apps");
            if (!(match.id in hidden)) {
                hidden += match.id;
                settings.set_strv("hidden-apps", hidden);
                GLib.Settings.sync();
            }

            match.removed = true;
            filter.refilter();
            if (filter.iter_n_children(null) > 0) {
                move_path_to(path, position);
                clamp_path_to_rows(path, filter);
                item_view.set_cursor(path, null, false);
            }
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
            rank_rows();
            // Cause resorting
            // TODO: find cleaner way of causing re-sort
            model.set_sort_func(1, app_sort_func);
            filter.refilter();
            set_selection();
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (!apps_loaded) {
                activate_when_loaded = true;
                return;
            }
            if (filter.get_iter(out iter, path))
                execute_app(iter);
        }

        /**
         * Rank every row for the text in the filter box, unless that was done already
         *
         * Filtering and sorting both use the ranks, and either may run first for a new text.
         */
        private void rank_rows() {
            string text = entry.get_text();
            if (text == ranked_text)
                return;
            ranked_text = text;
            ranked_words = query_words(text);

            Gtk.TreeIter row_iter;
            for (bool next = model.get_iter_first(out row_iter); next; next = model.iter_next(ref row_iter)) {
                AppMatch match;
                model.@get(row_iter, ITEM_VIEW_COLUMN_MATCH, out match);
                if (match != null)
                    match.rank(ranked_words, fuzzy_matching);
            }
        }

        /**
         * Sort function for the application list
         *
         * With a filter, rows go by the tiers of compare_app_matches(); without one, by
         * the testable compare_desktop_apps utility function
         */
        private int app_sort_func(TreeModel model, TreeIter a, TreeIter b) {
            rank_rows();

            if (ranked_words.length > 0) {
                AppMatch match_a;
                model.@get(a, ITEM_VIEW_COLUMN_MATCH, out match_a);
                AppMatch match_b;
                model.@get(b, ITEM_VIEW_COLUMN_MATCH, out match_b);
                if (match_a != null && match_b != null)
                    return compare_app_matches(match_a, match_b, launch_counts);
            }

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
            rank_rows();

            AppMatch match;
            model.@get(iter, ITEM_VIEW_COLUMN_MATCH, out match);
            if (match != null && match.removed)
                return false;
            if (ranked_words.length == 0)
                return true;

            // Each word may match one of the fields in match-fields
            return match != null && match.tier != AppTier.NONE;
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
            if (app_info != null && app_info.should_show() && !is_hidden_app(app_info.get_id() ?? "", hidden_apps)) {
                var match = new AppMatch(app_info.get_id() ?? "", app_info.get_name(), app_info.get_generic_name(),
                                         string.joinv(" ", app_info.get_keywords()), app_info.get_description(), match_fields);
                // Text typed before the list arrived
                if (ranked_text != null)
                    match.rank(ranked_words, fuzzy_matching);

                model.append(out iter);

                if (icon_size > 0)
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_ICON, icon_img,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name(),
                        ITEM_VIEW_COLUMN_MATCH, match,
                        ITEM_VIEW_COLUMN_APPINFO, app_info
                    );
                else
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name(),
                        ITEM_VIEW_COLUMN_MATCH, match,
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

        // Queue every row: the ones visible through the filter first, then the rest, so
        // that rows hidden by text typed before the list arrived still get their icons
        private void start_icon_loading() {
            var queued = new bool[model.iter_n_children(null)];
            TreeIter filter_iter;
            for (bool next = filter.get_iter_first(out filter_iter); next; next = filter.iter_next(ref filter_iter)) {
                TreeIter child_iter;
                filter.convert_iter_to_child_iter(out child_iter, filter_iter);
                icon_queue += child_iter;
                queued[model.get_path(child_iter).get_indices()[0]] = true;
            }
            TreeIter model_iter;
            int row = 0;
            for (bool next = model.get_iter_first(out model_iter); next; next = model.iter_next(ref model_iter), ++row) {
                if (!queued[row])
                    icon_queue += model_iter;
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

                // Themed icons go by their plain name: lookup_by_gicon() also tries the "-symbolic"
                // variant (GLib adds it to the icon's name list), which the theme chain finds (grey,
                // in Adwaita) before the colour icon in gnome
                Gtk.IconInfo ? icon_info;
                if (icon is ThemedIcon)
                    icon_info = icon_theme.lookup_icon(icon.to_string(), icon_size, Gtk.IconLookupFlags.FORCE_SIZE);
                else
                    icon_info = icon_theme.lookup_by_gicon(icon, icon_size, Gtk.IconLookupFlags.FORCE_SIZE);
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

        // Launch a desktop app, at most once: a double click activates the row twice
        public void execute_app(Gtk.TreeIter selection) {
            DesktopAppInfo app_info;
            filter.@get(selection, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            launcher.launch(app_info);
        }
    }
}
