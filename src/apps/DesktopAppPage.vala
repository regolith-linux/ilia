using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage, GLib.Object {
        private static GLib.Timer app_timer;
        private const int ITEM_VIEW_COLUMNS = 5;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_MATCH = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;
        private const int ITEM_VIEW_COLUMN_FAVORITE = 4;
        // The text of the favourite column in the row of a favourite
        private const string FAVORITE_MARKER = "★";

        // Number of past launches to store (to determine sort rank)
        private const uint HISTORY_MAX_LEN = 32;
        // Max number of files to read in sequence before yeilding
        private const int FS_FILE_READ_COUNT = 128;
        // Roots of app dirs env var.  See https://github.com/flatpak/flatpak/issues/1286#issuecomment-354554684
        private const string XDG_DATA_DIRS = "XDG_DATA_DIRS";
        // The message bus itself, which starts apps from their service files
        private const string DBUS_NAME = "org.freedesktop.DBus";
        private const string DBUS_PATH = "/org/freedesktop/DBus";
        // Time a running app has to answer an activation request before the page closes
        private const int ACTIVATE_TIMEOUT_MS = 3000;

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

        // Set once an app is launched; the page closes afterwards
        private bool launching = false;

        // Rows that fail the word rule are shown when the words are subsequences of the name
        private bool fuzzy_matching;

        // Desktop ids and patterns of the apps that are never listed
        private string[] hidden_apps;

        // The fields of an app that filtering uses: the name and those in match-fields
        private AppField match_fields;

        // The place of each favourite in favorite-apps
        private HashTable<string, int> favorite_ranks;

        // The window manager, which a launch on a new workspace asks to switch
        private string wm_name;

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
        // That Enter was Ctrl+Enter: launch on a new workspace
        private bool new_workspace_when_loaded = false;

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
            keybindings.set("ctrl+f", "Add or Remove Favorite");
            keybindings.set("alt+up", "Move Favorite Up");
            keybindings.set("alt+down", "Move Favorite Down");
            keybindings.set("ctrl+enter", "Launch on a New Workspace");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            app_timer = new GLib.Timer();
            app_timer.start();
            this.settings = settings;
            this.entry = entry;
            this.session_controller = sessionController;
            this.wm_name = wm_name;

            launch_history = settings.get_strv("app-launch-counts");
            launch_counts = load_launch_counts(launch_history);
            icon_size = settings.get_int("icon-size");
            fuzzy_matching = settings.get_boolean("fuzzy-matching");
            hidden_apps = settings.get_strv("hidden-apps");
            match_fields = AppField.NAME | AppField.from_names(settings.get_strv("match-fields"));
            favorite_ranks = rank_favorites(settings.get_strv("favorite-apps"));
            // Changes by other programs, and the page's own: its keys only write the setting
            settings.changed["favorite-apps"].connect(on_favorites_changed);

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (AppMatch), typeof (DesktopAppInfo), typeof (string));

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
            if (activate_when_loaded && new_workspace_when_loaded)
                launch_selected_on_new_workspace();
            else if (activate_when_loaded)
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
            if (is_enter_key(key.keyval) && only_control(key)) {
                // Taken here, or the list would launch the app as for Enter
                if (apps_loaded) {
                    launch_selected_on_new_workspace();
                } else {
                    activate_when_loaded = true;
                    new_workspace_when_loaded = true;
                }
                return true;
            }
            if (!apps_loaded && is_enter_key(key.keyval)) {
                activate_when_loaded = true;
                return true;
            }
            if (key.keyval == Gdk.Key.Delete && (key.state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                // Taken whether or not a row is highlighted: it never edits the filter here
                hide_selected_app();
                return true;
            }
            if (is_favorite_key(key)) {
                toggle_selected_favorite();
                return true;
            }
            if ((key.keyval == Gdk.Key.Up || key.keyval == Gdk.Key.Down) && only_alt(key)) {
                // Taken even when the favourite cannot move, so that the selection does not move instead
                move_selected_favorite(key.keyval == Gdk.Key.Up);
                return true;
            }
            return handle_emacs_vim_nav(item_view, path, key);
        }

        // Ctrl+f is ilia's on this page, also when i3 binds it
        public bool owns_key(Gdk.EventKey key) {
            return is_favorite_key(key);
        }

        // Ctrl+f, which pins or unpins the highlighted app
        private static bool is_favorite_key(Gdk.EventKey key) {
            return (key.keyval == Gdk.Key.f || key.keyval == Gdk.Key.F) && only_control(key);
        }

        // Control held, without Alt or Super
        private static bool only_control(Gdk.EventKey key) {
            return (key.state & Gdk.ModifierType.CONTROL_MASK) != 0
                   && (key.state & (Gdk.ModifierType.MOD1_MASK | Gdk.ModifierType.SUPER_MASK)) == 0;
        }

        // Alt held, without Control or Super
        private static bool only_alt(Gdk.EventKey key) {
            return (key.state & Gdk.ModifierType.MOD1_MASK) != 0
                   && (key.state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SUPER_MASK)) == 0;
        }

        // The desktop id of the highlighted app, or null when no row is highlighted
        private string ? selected_app_id() {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter selected;
            if (!item_view.get_selection().get_selected(out selected_model, out selected))
                return null;

            AppMatch match;
            filter.@get(selected, ITEM_VIEW_COLUMN_MATCH, out match);
            return match.id;
        }

        /**
         * Pin the highlighted app, or unpin it when it is a favourite. The favourites are read
         * as they are stored now, so changes other programs made since the page opened are kept.
         */
        private void toggle_selected_favorite() {
            string ? id = selected_app_id();
            if (id == null)
                return;

            settings.set_strv("favorite-apps", toggle_favorite(settings.get_strv("favorite-apps"), id));
            GLib.Settings.sync();
        }

        /**
         * Move the highlighted favourite before the favourite shown above it, or after the one
         * shown below it, as stored now. Nothing moves while the filter holds words, which may
         * leave out favourites between the two; nor when the highlighted app is no favourite, or
         * no favourite is shown on that side of it.
         */
        private void move_selected_favorite(bool up) {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter selected;
            if (!item_view.get_selection().get_selected(out selected_model, out selected) || ranked_words.length > 0)
                return;

            // Without words the favourites come first, so the neighbouring favourite is the neighbouring row
            Gtk.TreeIter neighbor = selected;
            if (!(up ? filter.iter_previous(ref neighbor) : filter.iter_next(ref neighbor)))
                return;
            AppMatch match;
            filter.@get(selected, ITEM_VIEW_COLUMN_MATCH, out match);
            AppMatch neighbor_match;
            filter.@get(neighbor, ITEM_VIEW_COLUMN_MATCH, out neighbor_match);
            if (!favorite_ranks.contains(match.id) || !favorite_ranks.contains(neighbor_match.id))
                return;

            settings.set_strv("favorite-apps", move_favorite(settings.get_strv("favorite-apps"), match.id, neighbor_match.id, up));
            GLib.Settings.sync();
        }

        /**
         * Mark and order the rows for favorite-apps as it is now, whoever changed it. The
         * highlighted app stays highlighted.
         */
        private void on_favorites_changed() {
            favorite_ranks = rank_favorites(settings.get_strv("favorite-apps"));
            // Rows read later are marked as they are added
            if (!apps_loaded)
                return;

            string ? selected_id = selected_app_id();
            // A changed row of a sorted store moves at once: leave the rows in place until all are marked
            model.set_sort_column_id(Gtk.SortColumn.UNSORTED, SortType.ASCENDING);
            Gtk.TreeIter row_iter;
            for (bool next = model.get_iter_first(out row_iter); next; next = model.iter_next(ref row_iter)) {
                AppMatch match;
                model.@get(row_iter, ITEM_VIEW_COLUMN_MATCH, out match);
                model.set(row_iter, ITEM_VIEW_COLUMN_FAVORITE, favorite_marker(match.id));
            }
            model.set_sort_column_id(1, SortType.ASCENDING);

            if (selected_id != null)
                select_app(selected_id);
        }

        // The text of the favourite column for an app
        private string favorite_marker(string id) {
            return favorite_ranks.contains(id) ? FAVORITE_MARKER : "";
        }

        // Highlight the row of an app, if it is shown
        private void select_app(string id) {
            Gtk.TreeIter row_iter;
            for (bool next = filter.get_iter_first(out row_iter); next; next = filter.iter_next(ref row_iter)) {
                AppMatch match;
                filter.@get(row_iter, ITEM_VIEW_COLUMN_MATCH, out match);
                if (match.id == id) {
                    move_path_to(path, filter.get_path(row_iter));
                    item_view.set_cursor(path, null, false);
                    return;
                }
            }
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
            item_view.insert_column_with_attributes(-1, "Favorite", new CellRendererText(), "text", ITEM_VIEW_COLUMN_FAVORITE);

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
         * With a filter, rows go by the tiers of compare_app_matches(), favourites first in
         * each; without one, favourites first and then the rest by the testable
         * compare_desktop_apps utility function
         */
        private int app_sort_func(TreeModel model, TreeIter a, TreeIter b) {
            rank_rows();

            if (ranked_words.length > 0) {
                AppMatch match_a;
                model.@get(a, ITEM_VIEW_COLUMN_MATCH, out match_a);
                AppMatch match_b;
                model.@get(b, ITEM_VIEW_COLUMN_MATCH, out match_b);
                if (match_a != null && match_b != null)
                    return compare_app_matches(match_a, match_b, launch_counts, favorite_ranks);
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

            int by_favorite = compare_favorites(app_a_id, app_b_id, favorite_ranks);
            if (by_favorite != 0)
                return by_favorite;

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
                        ITEM_VIEW_COLUMN_APPINFO, app_info,
                        ITEM_VIEW_COLUMN_FAVORITE, favorite_marker(match.id)
                    );
                else
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name(),
                        ITEM_VIEW_COLUMN_MATCH, match,
                        ITEM_VIEW_COLUMN_APPINFO, app_info,
                        ITEM_VIEW_COLUMN_FAVORITE, favorite_marker(match.id)
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
            if (launching)
                return;
            launching = true;

            DesktopAppInfo app_info;
            filter.@get(selection, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            start_app(app_info);
        }

        /**
         * Launch the highlighted app on the next free workspace, at most once. Nothing happens
         * when no row is highlighted.
         */
        private void launch_selected_on_new_workspace() {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter selected;
            if (!item_view.get_selection().get_selected(out selected_model, out selected) || launching)
                return;
            launching = true;

            DesktopAppInfo app_info;
            filter.@get(selected, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            launch_on_new_workspace.begin(app_info);
        }

        /**
         * Switch to the next free workspace, which the switch creates, and then start the app
         * there as Enter does. The workspace gets the name its wm.workspace.NN.name resource
         * gives it; under sway the resources are the ones trawl serves, elsewhere those of the
         * X resource database.
         */
        private async void launch_on_new_workspace(DesktopAppInfo app_info) {
            // Read first: no other window manager request may come between finding the free
            // number and switching to it
            HashTable<string, string> ? trawl_resources = null;
            if (wm_name == "sway")
                trawl_resources = yield read_trawl_resources();

            try {
                var ipc = new IPCClient(wm_name);
                int[] taken = {};
                foreach (var workspace in ipc.getWorkspaces())
                    taken += workspace.num;
                int number = next_free_workspace_number(taken);

                string resource = workspace_name_resource(number);
                string ? name = trawl_resources != null ? trawl_resources.get(resource) : read_x_resource(item_view.get_display(), resource);
                if (name == null || name == "")
                    name = number.to_string();

                // The window manager answers once it has switched, so the app opens there
                ipc.runCommand("workspace number " + quote_workspace_name(name, wm_name));
            } catch (GLib.Error e) {
                stderr.printf("Failed to switch to a new workspace: %s\n", e.message);
            }
            start_app(app_info);
        }

        // Start a desktop app as its desktop entry says, record the launch and close
        private void start_app(DesktopAppInfo app_info) {
            string ? bus_name = get_dbus_activation_name(app_info);
            if (bus_name != null) {
                activate_app.begin(app_info, bus_name);
                return;
            }

            try {
                bool launched = true;
                if (needs_terminal(app_info) && GLib.Environment.find_program_in_path("x-terminal-emulator") == null) {
                    // GLib picks a terminal it knows, and runs the entry outside a scope
                    launched = app_info.launch(null, null);
                } else {
                    Pid pid;
                    Process.spawn_async(get_desktop_working_directory(app_info), get_desktop_launch_argv(app_info),
                                        null, SpawnFlags.SEARCH_PATH, null, out pid);
                }

                if (launched)
                    add_to_launch_history(app_info.get_id());
                else
                    stderr.printf("Failed to launch %s\n", app_info.get_name());
            } catch (GLib.Error e) {
                stderr.printf("Failed to launch %s: %s\n", app_info.get_name(), e.message);
            }
            session_controller.quit();
        }

        /*
         * Start a DBusActivatable app over the session bus, with Activate on its
         * org.freedesktop.Application interface, as the Desktop Entry Specification describes
         */
        private async void activate_app(DesktopAppInfo app_info, string bus_name) {
            // Keep running until the app answers, also once the window has closed on losing the
            // focus, as it does when the launch has switched the workspace
            var application = GLib.Application.get_default();
            application.hold();
            try {
                var bus = yield Bus.get(BusType.SESSION);

                // Have the bus start the app first if it is not running: a message that waits
                // for its destination to start is dropped once the sender has disconnected.
                var has_owner = yield bus.call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "NameHasOwner",
                                               new Variant("(s)", bus_name), new VariantType("(b)"),
                                               DBusCallFlags.NONE, -1);

                if (!has_owner.get_child_value(0).get_boolean())
                    yield bus.call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "StartServiceByName",
                                   new Variant("(su)", bus_name, (uint32) 0), new VariantType("(u)"),
                                   DBusCallFlags.NONE, -1);

                var platform_data = new VariantBuilder(new VariantType("a{sv}"));
                yield bus.call(bus_name, get_dbus_activation_path(bus_name), "org.freedesktop.Application",
                               "Activate", new Variant("(a{sv})", platform_data),
                               null, DBusCallFlags.NO_AUTO_START, ACTIVATE_TIMEOUT_MS);

                add_to_launch_history(app_info.get_id());
            } catch (GLib.Error e) {
                stderr.printf("Failed to activate %s: %s\n", app_info.get_name(), e.message);
            }
            session_controller.quit();
            application.release();
        }

        // Record a launch, for the sort order
        private void add_to_launch_history(string key) {
            if (launch_history == null) {
                launch_history = { key };
            } else {
                launch_history += key;
            }

            if (launch_history.length <= HISTORY_MAX_LEN)
                settings.set_strv("app-launch-counts", launch_history);
            else
                settings.set_strv("app-launch-counts", launch_history[1 : HISTORY_MAX_LEN]);
        }
    }
}
