using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage, GLib.Object {
        private static GLib.Timer app_timer;
        private const int ITEM_VIEW_COLUMNS = 5;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_MATCH = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;
        // The desktop action of the row, null for the row of the app itself
        private const int ITEM_VIEW_COLUMN_ACTION = 4;

        // Number of past launches to store (to determine sort rank)
        private const uint HISTORY_MAX_LEN = 32;
        // Max number of files to read in sequence before yeilding
        private const int FS_FILE_READ_COUNT = 128;
        // Roots of app dirs env var.  See https://github.com/flatpak/flatpak/issues/1286#issuecomment-354554684
        private const string XDG_DATA_DIRS = "XDG_DATA_DIRS";
        // The message bus itself, which starts apps from their service files
        private const string DBUS_NAME = "org.freedesktop.DBus";
        private const string DBUS_PATH = "/org/freedesktop/DBus";
        // Time an app has to answer an activation request before the page closes
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
        // The actions of the entries by desktop ID, read on the same thread (that reads the files again)
        private static HashTable<string, GenericArray<DesktopAction> > ? prefetched_actions = null;
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
                var actions = read_actions(list);
                Idle.add(() => {
                    prefetched_apps = (owned) list;
                    prefetched_actions = actions;
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

        private static HashTable<string, GenericArray<DesktopAction> > read_actions(GLib.List<AppInfo> app_list) {
            var actions = new HashTable<string, GenericArray<DesktopAction> >(str_hash, str_equal);
            foreach (unowned AppInfo app in app_list) {
                var desktop_app = app as DesktopAppInfo;
                if (desktop_app == null || desktop_app.get_id() == null || !desktop_app.should_show())
                    continue;

                var app_actions = new GenericArray<DesktopAction>();
                foreach (var action in get_desktop_actions(desktop_app))
                    app_actions.add(action);
                if (app_actions.length > 0)
                    actions.insert(desktop_app.get_id(), app_actions);
            }
            return actions;
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
            return "This dialog allows for the launching of desktop applications. Initially all desktop apps are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will launch it. Additional actions that an application offers, such as opening a new window, are listed as \"Application: Action\" once the filter text names them.";
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
            this.session_controller = sessionController;

            launch_history = settings.get_strv("app-launch-counts");
            launch_counts = load_launch_counts(launch_history);
            icon_size = settings.get_int("icon-size");
            fuzzy_matching = settings.get_boolean("fuzzy-matching");
            hidden_apps = settings.get_strv("hidden-apps");
            match_fields = AppField.NAME | AppField.from_names(settings.get_strv("match-fields"));

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (AppMatch), typeof (DesktopAppInfo), typeof (DesktopAction));

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

            // Action rows are ranked with the app rows by their text, "App: Action", and by
            // their own launch count
            string name_a;
            DesktopAppInfo app_a;
            DesktopAction ? action_a;
            model.@get(a, ITEM_VIEW_COLUMN_NAME, out name_a, ITEM_VIEW_COLUMN_APPINFO, out app_a, ITEM_VIEW_COLUMN_ACTION, out action_a);
            string name_b;
            DesktopAppInfo app_b;
            DesktopAction ? action_b;
            model.@get(b, ITEM_VIEW_COLUMN_NAME, out name_b, ITEM_VIEW_COLUMN_APPINFO, out app_b, ITEM_VIEW_COLUMN_ACTION, out action_b);

            return compare_desktop_apps(
                name_a.down(),
                name_b.down(),
                launch_history_key(app_a.get_id(), action_a != null ? action_a.id : null),
                launch_history_key(app_b.get_id(), action_b != null ? action_b.id : null),
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
            // Without a filter only the apps are listed
            if (ranked_words.length == 0)
                return match == null || !match.is_action;

            // Each word may match one of the fields in match-fields. The name of an action
            // row is "App: Action", and one word must occur in the action name: actions are
            // only listed for a filter that names them
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
                string app_id = app_info.get_id() ?? "";
                string ? keywords = string.joinv(" ", app_info.get_keywords());

                append_row(app_info.get_name(), new AppMatch(app_id, app_info.get_name(), app_info.get_generic_name(),
                                                             keywords, app_info.get_description(), match_fields),
                           app_info, null, icon_img);

                // A row for each action the entry declares, shown by filter_func() when the filter names it.
                // An action is counted, and hidden by Ctrl+Delete, as <desktop id>#<action id>.
                unowned GenericArray<DesktopAction> ? actions = app_info.get_id() != null ? prefetched_actions.lookup(app_info.get_id()) : null;

                if (actions != null) {
                    foreach (var action in actions) {
                        string key = launch_history_key(app_id, action.id);
                        if (is_hidden_app(key, hidden_apps))
                            continue;
                        string row_name = app_info.get_name() + ": " + action.name;
                        append_row(row_name, new AppMatch(key, row_name, app_info.get_generic_name(), keywords,
                                                          app_info.get_description(), match_fields, action.name),
                                   app_info, action, icon_img);
                    }
                }
            }
        }

        private void append_row(string name, AppMatch match, DesktopAppInfo app_info, DesktopAction ? action, Gdk.Pixbuf ? icon_img) {
            // Text typed before the list arrived
            if (ranked_text != null)
                match.rank(ranked_words, fuzzy_matching);

            model.append(out iter);

            if (icon_size > 0)
                model.set(iter, ITEM_VIEW_COLUMN_ICON, icon_img);

            model.set(
                iter,
                ITEM_VIEW_COLUMN_NAME, name,
                ITEM_VIEW_COLUMN_MATCH, match,
                ITEM_VIEW_COLUMN_APPINFO, app_info,
                ITEM_VIEW_COLUMN_ACTION, action
            );
        }

        // Icons are looked up on the main thread (the theme cache makes that cheap) and decoded
        // on GTK's worker threads, a few at a time. Rows are queued in the order they are shown
        // so the visible rows get their icons first.
        private const int ICON_LOAD_PARALLELISM = 4;
        private TreeIter[] icon_queue = {};
        private int icon_queue_next = 0;
        private int icons_in_flight = 0;
        // Decoded icons by file: action rows show the icon of their app, which is decoded once
        private HashTable<string, Gdk.Pixbuf> decoded_icons = new HashTable<string, Gdk.Pixbuf>(str_hash, str_equal);

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

                DesktopAppInfo app_info;
                DesktopAction ? action;
                model.@get(iter, ITEM_VIEW_COLUMN_APPINFO, out app_info, ITEM_VIEW_COLUMN_ACTION, out action);

                // An action may name an icon of its own; the app's icon stands in when it names none or it is not found
                Gtk.IconInfo ? icon_info = null;
                if (action != null && action.icon != null) {
                    try {
                        icon_info = lookup_icon(Icon.new_for_string(action.icon));
                    } catch (GLib.Error e) {
                        debug("Icon %s not loaded: %s", action.icon, e.message);
                    }
                }
                if (icon_info == null)
                    icon_info = lookup_icon(app_info.get_icon());
                if (icon_info == null) continue;

                unowned string ? icon_file = icon_info.get_filename();
                if (icon_file != null && decoded_icons.contains(icon_file)) {
                    model.set(iter, ITEM_VIEW_COLUMN_ICON, decoded_icons.get(icon_file));
                    continue;
                }

                icons_in_flight++;
                icon_info.load_icon_async.begin(null, (obj, res) => {
                    try {
                        var pixbuf = icon_info.load_icon_async.end(res);
                        if (icon_info.get_filename() != null)
                            decoded_icons.insert(icon_info.get_filename(), pixbuf);
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

        private Gtk.IconInfo ? lookup_icon(GLib.Icon ? icon) {
            if (icon == null)
                return null;

            // Themed icons go by their plain name: lookup_by_gicon() also tries the "-symbolic"
            // variant (GLib adds it to the icon's name list), which the theme chain finds (grey,
            // in Adwaita) before the colour icon in gnome
            if (icon is ThemedIcon)
                return icon_theme.lookup_icon(icon.to_string(), icon_size, Gtk.IconLookupFlags.FORCE_SIZE);
            return icon_theme.lookup_by_gicon(icon, icon_size, Gtk.IconLookupFlags.FORCE_SIZE);
        }

        // Launch a desktop app, or one of its actions, at most once: a double click activates the row twice
        public void execute_app(Gtk.TreeIter selection) {
            if (launching)
                return;
            launching = true;

            DesktopAppInfo app_info;
            DesktopAction ? action;
            filter.@get(selection, ITEM_VIEW_COLUMN_APPINFO, out app_info, ITEM_VIEW_COLUMN_ACTION, out action);

            if (action != null) {
                execute_action(app_info, action);
                return;
            }

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
                    Process.spawn_async(get_desktop_working_directory(app_info), get_desktop_launch_argv(app_info, app_info.get_commandline() ?? ""),
                                        null, SpawnFlags.SEARCH_PATH, null, out pid);
                }

                if (launched)
                    add_to_launch_history(launch_history_key(app_info.get_id(), null));
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

                add_to_launch_history(launch_history_key(app_info.get_id(), null));
            } catch (GLib.Error e) {
                stderr.printf("Failed to activate %s: %s\n", app_info.get_name(), e.message);
            }
            session_controller.quit();
        }

        /*
         * Start an action of a desktop app
         *
         * The action's command runs in its own scope, as the app does. A DBusActivatable app is
         * asked over the session bus instead, and its command is not used.
         */
        private void execute_action(DesktopAppInfo app_info, DesktopAction action) {
            string ? bus_name = get_dbus_activation_name(app_info);
            if (bus_name != null) {
                activate_action.begin(app_info, action, bus_name);
                return;
            }

            if (needs_terminal(app_info) && GLib.Environment.find_program_in_path("x-terminal-emulator") == null) {
                // GLib picks a terminal it knows, and runs the action outside a scope, as for the app
                app_info.launch_action(action.id, new AppLaunchContext());
                add_to_launch_history(launch_history_key(app_info.get_id(), action.id));
                session_controller.quit();
                return;
            }

            try {
                Process.spawn_async(get_desktop_working_directory(app_info),
                                    get_desktop_launch_argv(app_info, action.exec),
                                    null, SpawnFlags.SEARCH_PATH, null, null);
                add_to_launch_history(launch_history_key(app_info.get_id(), action.id));
            } catch (GLib.Error e) {
                stderr.printf("Failed to launch %s: %s\n", action.name, e.message);
            }
            session_controller.quit();
        }

        /*
         * Start an action of a DBusActivatable app with ActivateAction on its
         * org.freedesktop.Application interface, as the Desktop Entry Specification describes
         */
        private async void activate_action(DesktopAppInfo app_info, DesktopAction action, string bus_name) {
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

                var parameters = new VariantBuilder(new VariantType("av"));
                var platform_data = new VariantBuilder(new VariantType("a{sv}"));
                yield bus.call(bus_name, get_dbus_activation_path(bus_name), "org.freedesktop.Application",
                               "ActivateAction", new Variant("(sava{sv})", action.id, parameters, platform_data),
                               null, DBusCallFlags.NO_AUTO_START, ACTIVATE_TIMEOUT_MS);

                add_to_launch_history(launch_history_key(app_info.get_id(), action.id));
            } catch (GLib.Error e) {
                stderr.printf("Failed to activate %s: %s\n", action.name, e.message);
            }
            session_controller.quit();
        }

        // Record a launch, for the sort order
        private void add_to_launch_history(string key) {
            launch_history = append_launch_history(launch_history, key, (int) HISTORY_MAX_LEN);
            settings.set_strv("app-launch-counts", launch_history);
        }
    }
}
