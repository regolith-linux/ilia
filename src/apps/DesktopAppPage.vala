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

        // Marks the rows of the apps whose actions Right shows
        private const string ACTIONS_CUE = "›";
        // How far the names of action rows are set in, in pixels
        private const int ACTION_INDENT = 24;

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
        // Shows the cue on the rows of apps with actions
        private Gtk.TreeViewColumn cue_column;
        // Sets the names in while actions are listed on their own, see update_action_indent()
        private Gtk.TreeViewColumn indent_column;
        // Model for selections: the apps, each with its actions under it, and the actions
        // again on their own, for the filters that list them without their app
        private Gtk.TreeStore model;
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

        // The filter text the rows were last ranked for, and its words; for a filter with a
        // colon, the words before the first colon, which the apps are ranked for
        private string ? ranked_text = null;
        private string[] ranked_words = {};
        // For a filter with a colon, the words after the first colon, which the names of the
        // listed actions hold; null for a filter without a colon
        private string[] ? action_words = null;

        // The app whose actions are shown under its row (Right), or null
        private DesktopAppInfo ? expanded_app = null;

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
            return "This dialog allows for the launching of desktop applications. Initially all desktop apps are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will launch it. Applications that offer additional actions, such as opening a new window, are marked with › at the end of their row: the right arrow key, or a click on the mark, shows the actions under the application, and the left arrow key hides them. Actions are also listed on their own, as \"Application: Action\", once the filter text names them, and a filter written as \"application:action\" lists the actions of the matching applications.";
        }

        public char get_keybinding() {
            return 'a';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Launch Application");
            keybindings.set("ctrl+delete", "Hide Application");
            keybindings.set("right", "Show Actions");
            keybindings.set("left", "Hide Actions");

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

            model = new Gtk.TreeStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (AppMatch), typeof (DesktopAppInfo), typeof (DesktopAction));

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

            model.set_sort_func(ITEM_VIEW_COLUMN_NAME, app_sort_func);
            model.set_sort_column_id(ITEM_VIEW_COLUMN_NAME, SortType.ASCENDING);

            update_action_indent();
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
            if (key.keyval == Gdk.Key.Right)
                return on_right_key();
            if (key.keyval == Gdk.Key.Left)
                return on_left_key();
            return handle_emacs_vim_nav(item_view, path, key);
        }

        /**
         * Right: show the actions of the highlighted app under it, or, once they are shown,
         * highlight the first of them. On one of those actions it does nothing.
         *
         * @return false when the highlighted row has no actions to show, so Right switches pages
         */
        private bool on_right_key() {
            var row = selected_path();
            if (row == null)
                return false;
            if (in_expanded_app(row)) {
                if (row.get_depth() == 1) {
                    row.down();
                    select_row(row);
                }
                return true;
            }

            Gtk.TreeIter selected;
            filter.get_iter(out selected, row);
            if (!filter.iter_has_child(selected))
                return false;
            DesktopAppInfo app_info;
            filter.@get(selected, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            expand_app(app_info);
            return true;
        }

        /**
         * Left: hide the actions shown under an app, from the app or from one of the actions
         *
         * @return false on any other row, so Left switches pages
         */
        private bool on_left_key() {
            if (!in_expanded_app(selected_path()))
                return false;
            collapse_app();
            return true;
        }

        /**
         * Show the actions of an app under its row, which is highlighted. Meanwhile they are
         * not listed on their own, and the actions of any other app are hidden.
         */
        private void expand_app(DesktopAppInfo app_info) {
            collapse_app();
            expanded_app = app_info;
            refilter();
            var app_row = app_row_path(app_info);
            item_view.expand_row(app_row, false);
            select_row(app_row);
        }

        /**
         * Hide the actions shown under an app. When one of them was highlighted, the app is.
         */
        private void collapse_app() {
            if (expanded_app == null)
                return;
            var app_row = app_row_path(expanded_app);
            expanded_app = null;
            if (app_row != null)
                item_view.collapse_row(app_row);
            // The filter may list some of the actions on their own again
            refilter();
        }

        // Moving the highlight off the app whose actions are shown, and off those actions, hides them
        private void on_cursor_changed() {
            Gtk.TreePath ? cursor;
            item_view.get_cursor(out cursor, null);
            if (expanded_app != null && !in_expanded_app(cursor))
                collapse_app();
        }

        // A click on the cue shows or hides the actions of the app, and launches nothing
        private bool on_button_press(Gdk.EventButton event) {
            if (event.button != Gdk.BUTTON_PRIMARY || event.window != item_view.get_bin_window())
                return false;
            Gtk.TreePath row;
            unowned Gtk.TreeViewColumn column;
            int cell_x, cell_y;
            if (!item_view.get_path_at_pos((int) event.x, (int) event.y, out row, out column, out cell_x, out cell_y) || column != cue_column)
                return false;

            Gtk.TreeIter clicked;
            filter.get_iter(out clicked, row);
            if (!filter.iter_has_child(clicked))
                return false;
            // The second press of a double click is taken too, so that it does not launch the app
            if (event.type == Gdk.EventType.BUTTON_PRESS) {
                DesktopAppInfo app_info;
                filter.@get(clicked, ITEM_VIEW_COLUMN_APPINFO, out app_info);
                if (app_info == expanded_app)
                    collapse_app();
                else
                    expand_app(app_info);
            }
            return true;
        }

        // The path of the row of an app itself, or null when the filter does not list it
        private Gtk.TreePath ? app_row_path(DesktopAppInfo app_info) {
            Gtk.TreeIter row;
            for (bool next = filter.get_iter_first(out row); next; next = filter.iter_next(ref row)) {
                DesktopAppInfo row_app;
                DesktopAction ? action;
                filter.@get(row, ITEM_VIEW_COLUMN_APPINFO, out row_app, ITEM_VIEW_COLUMN_ACTION, out action);
                if (row_app == app_info && action == null)
                    return filter.get_path(row);
            }
            return null;
        }

        // True if row is the row of the app whose actions are shown, or of one of those actions
        private bool in_expanded_app(Gtk.TreePath ? row) {
            if (row == null || expanded_app == null)
                return false;
            var app_row = app_row_path(expanded_app);
            return app_row != null && (row.compare(app_row) == 0 || row.is_descendant(app_row));
        }

        private Gtk.TreePath ? selected_path() {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter selected;
            if (!item_view.get_selection().get_selected(out selected_model, out selected))
                return null;
            return selected_model.get_path(selected);
        }

        // Highlight a row, and have Ctrl+n and Ctrl+p start from it
        private void select_row(Gtk.TreePath row) {
            item_view.set_cursor(row, null, false);
            move_path_to(path, row);
        }

        /**
         * Hide the highlighted app or action: add its desktop id, or <desktop id>#<action id>,
         * to the hidden-apps setting, unless it is listed already, and take its rows out of
         * the list. The row that takes its place is highlighted, or the new last row when it
         * was the last; see select_after_hidden_action() for an action under its app.
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
            DesktopAppInfo app_info;
            filter.@get(selected, ITEM_VIEW_COLUMN_MATCH, out match, ITEM_VIEW_COLUMN_APPINFO, out app_info);
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
            // An app goes with the actions shown under it
            if (app_info == expanded_app && !match.is_action)
                expanded_app = null;
            refilter();
            // The app loses its cue with its last action
            if (match.is_action)
                refresh_app_row(app_info);

            if (position.get_depth() > 1) {
                select_after_hidden_action(position);
            } else if (filter.iter_n_children(null) > 0) {
                move_path_to(path, position);
                clamp_path_to_rows(path, filter);
                item_view.set_cursor(path, null, false);
            }
        }

        /**
         * After an action shown under its app was hidden, highlight the action that takes its
         * place, else the new last action, else the app, whose actions are then closed
         */
        private void select_after_hidden_action(Gtk.TreePath action_row) {
            var app_row = action_row.copy();
            app_row.up();
            Gtk.TreeIter app_iter;
            filter.get_iter(out app_iter, app_row);
            int remaining = filter.iter_n_children(app_iter);
            if (remaining == 0) {
                // The view collapsed the row with its last child
                expanded_app = null;
                select_row(app_row);
                return;
            }
            select_row(new Gtk.TreePath.from_indices(app_row.get_indices()[0], int.min(action_row.get_indices()[1], remaining - 1)));
        }

        /**
         * Have the view take the row of an app again, so that the cue, also as assistive
         * technology reads it, follows the actions it has left
         */
        private void refresh_app_row(DesktopAppInfo app_info) {
            var app_row = app_row_path(app_info);
            if (app_row == null)
                return;
            Gtk.TreeIter filter_iter, row;
            filter.get_iter(out filter_iter, app_row);
            filter.convert_iter_to_child_iter(out row, filter_iter);
            model.row_changed(model.get_path(row), row);
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

            // The actions of an app are listed under it, set in, once Right shows them. The
            // cue at the end of the row stands in for GTK's expander arrow.
            item_view.show_expanders = false;
            item_view.level_indentation = ACTION_INDENT;

            // Create columns
            if (icon_size > 0)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);

            indent_column = new Gtk.TreeViewColumn();
            indent_column.sizing = Gtk.TreeViewColumnSizing.FIXED;
            indent_column.fixed_width = ACTION_INDENT;
            indent_column.visible = false;
            item_view.append_column(indent_column);

            int columns = item_view.insert_column_with_data_func(-1, "Name", new CellRendererText(), render_name);
            var name_column = item_view.get_column(columns - 1);
            name_column.expand = true;
            // Its cell is the one assistive technology reports as expandable and expanded
            item_view.set_expander_column(name_column);

            var cue_renderer = new CellRendererText();
            // As wide whatever row is measured first
            cue_renderer.width_chars = 2;
            cue_renderer.xalign = 0.5f;
            columns = item_view.insert_column_with_data_func(-1, "Actions", cue_renderer, render_cue);
            cue_column = item_view.get_column(columns - 1);

            // The list keeps the table role it has always had: GTK makes the view of a tree
            // model a tree table
            item_view.get_accessible().set_role(Atk.Role.TABLE);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);
            item_view.button_press_event.connect(on_button_press);
            item_view.cursor_changed.connect(on_cursor_changed);
        }

        /**
         * The name of an action row is "App: Action", and the app part is drawn in the dimmed
         * text colour of the theme: a colour between the row's text and its background
         */
        private void render_name(Gtk.TreeViewColumn column, Gtk.CellRenderer cell, Gtk.TreeModel row_model, Gtk.TreeIter row) {
            string name;
            DesktopAction ? action;
            row_model.@get(row, ITEM_VIEW_COLUMN_NAME, out name, ITEM_VIEW_COLUMN_ACTION, out action);

            Pango.AttrList ? attributes = null;
            if (action != null) {
                var state = Gtk.StateFlags.INSENSITIVE;
                if (item_view.get_selection().iter_is_selected(row))
                    state |= Gtk.StateFlags.SELECTED;
                var colour = item_view.get_style_context().get_color(state);
                var dimmed = Pango.attr_foreground_new((uint16) (colour.red * uint16.MAX), (uint16) (colour.green * uint16.MAX),
                                                       (uint16) (colour.blue * uint16.MAX));
                // The app name, the colon and the space
                dimmed.start_index = 0;
                dimmed.end_index = name.length - action.name.length;
                attributes = new Pango.AttrList();
                attributes.insert((owned) dimmed);
            }

            var text_cell = (Gtk.CellRendererText) cell;
            text_cell.text = name;
            text_cell.attributes = attributes;
        }

        // The cue marks the rows of the apps with actions to show: those with rows under them
        private void render_cue(Gtk.TreeViewColumn column, Gtk.CellRenderer cell, Gtk.TreeModel row_model, Gtk.TreeIter row) {
            ((Gtk.CellRendererText) cell).text = row_model.iter_has_child(row) ? ACTIONS_CUE : "";
        }

        /**
         * Set the names in while the list holds actions on their own. The view sets rows in by
         * their depth in the tree only, and those rows are at the top level, with the apps.
         */
        private void update_action_indent() {
            bool actions_on_their_own = false;
            Gtk.TreeIter row;
            for (bool next = filter.get_iter_first(out row); next && !actions_on_their_own; next = filter.iter_next(ref row)) {
                DesktopAction ? action;
                filter.@get(row, ITEM_VIEW_COLUMN_ACTION, out action);
                actions_on_their_own = action != null;
            }
            indent_column.visible = actions_on_their_own;
        }

        private void refilter() {
            filter.refilter();
            update_action_indent();
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            filter.get_iter(out iter, row_path);
            execute_app(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            // Any change to the filter hides the actions shown under an app
            expanded_app = null;
            item_view.collapse_all();

            rank_rows();
            // Cause resorting
            // TODO: find cleaner way of causing re-sort
            model.set_sort_func(ITEM_VIEW_COLUMN_NAME, app_sort_func);
            refilter();
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
            string[] program_words, words_after_colon;
            if (split_action_query(text, out program_words, out words_after_colon)) {
                ranked_words = program_words;
                action_words = words_after_colon;
            } else {
                ranked_words = query_words(text);
                action_words = null;
            }

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
         * the testable compare_desktop_apps utility function. With a colon, the actions are
         * grouped by app, the apps in the order their rows have for the words before the
         * colon. The actions of an app keep the order of its entry.
         */
        private int app_sort_func(TreeModel model, TreeIter a, TreeIter b) {
            rank_rows();

            AppMatch match_a;
            DesktopAppInfo app_a;
            DesktopAction ? action_a;
            model.@get(a, ITEM_VIEW_COLUMN_MATCH, out match_a, ITEM_VIEW_COLUMN_APPINFO, out app_a, ITEM_VIEW_COLUMN_ACTION, out action_a);
            AppMatch match_b;
            DesktopAppInfo app_b;
            DesktopAction ? action_b;
            model.@get(b, ITEM_VIEW_COLUMN_MATCH, out match_b, ITEM_VIEW_COLUMN_APPINFO, out app_b, ITEM_VIEW_COLUMN_ACTION, out action_b);

            // The actions under an app
            Gtk.TreeIter parent;
            if (model.iter_parent(out parent, a))
                return action_a.position - action_b.position;

            if (action_words != null) {
                if (app_a != app_b && ranked_words.length > 0)
                    return compare_app_matches(match_a.app ?? match_a, match_b.app ?? match_b, launch_counts);
                if (app_a != app_b) {
                    // Without words before the colon, the apps go in the order of the list without a filter
                    int by_app = compare_desktop_apps(app_a.get_name().down(), app_b.get_name().down(),
                                                      app_a.get_id(), app_b.get_id(), "", launch_counts);
                    return by_app != 0 ? by_app : strcmp(app_a.get_id(), app_b.get_id());
                }
                // The app's own row, which is not listed, then its actions
                return (action_a != null ? action_a.position : -1) - (action_b != null ? action_b.position : -1);
            }

            if (ranked_words.length > 0 && match_a != null && match_b != null)
                return compare_app_matches(match_a, match_b, launch_counts);

            string query_string = entry.get_text().down();

            // Action rows are ranked with the app rows by their text, "App: Action", and by
            // their own launch count
            string name_a;
            model.@get(a, ITEM_VIEW_COLUMN_NAME, out name_a);
            string name_b;
            model.@get(b, ITEM_VIEW_COLUMN_NAME, out name_b);

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
            DesktopAppInfo app_info;
            model.@get(iter, ITEM_VIEW_COLUMN_MATCH, out match, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            if (match == null || match.removed || (match.is_action && match.app.removed))
                return false;
            // The actions under their app, shown while it is expanded: every action that is not hidden
            if (model.iter_depth(iter) > 0)
                return true;

            // With a colon only actions are listed: those of the apps listed for the words
            // before it (all apps without words), whose names hold the words after it
            if (action_words != null)
                return match.is_action && (ranked_words.length == 0 || match.app.tier != AppTier.NONE)
                       && match.names_action_with(action_words);

            // The actions of the app whose actions are shown are only listed under it
            if (match.is_action && app_info == expanded_app)
                return false;
            // Without a filter only the apps are listed
            if (ranked_words.length == 0)
                return !match.is_action;

            // Each word may match one of the fields in match-fields. The name of an action
            // row is "App: Action", and one word must occur in the action name and not in
            // the app name: actions are only listed for a filter that names them
            return match.tier != AppTier.NONE;
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

                var app_match = desktop_app_match(app_info, match_fields);
                var app_row = append_row(null, app_info.get_name(), app_match, app_info, null, icon_img);

                // Each action the entry declares has a row under the app, shown once Right expands it, and
                // a row of its own, shown by filter_func() when the filter names it. The two rows share their
                // AppMatch. An action is counted, and hidden by Ctrl+Delete, as <desktop id>#<action id>.
                unowned GenericArray<DesktopAction> ? actions = app_info.get_id() != null ? prefetched_actions.lookup(app_info.get_id()) : null;

                if (actions != null) {
                    foreach (var action in actions) {
                        string key = launch_history_key(app_id, action.id);
                        if (is_hidden_app(key, hidden_apps))
                            continue;
                        string name = desktop_action_row_name(app_info, action);
                        var match = desktop_action_match(app_match, action);
                        append_row(app_row, name, match, app_info, action, icon_img);
                        append_row(null, name, match, app_info, action, icon_img);
                    }
                }
            }
        }

        private Gtk.TreeIter append_row(Gtk.TreeIter ? parent, string name, AppMatch match, DesktopAppInfo app_info, DesktopAction ? action, Gdk.Pixbuf ? icon_img) {
            // Text typed before the list arrived
            if (ranked_text != null)
                match.rank(ranked_words, fuzzy_matching);

            Gtk.TreeIter row;
            model.append(out row, parent);

            if (icon_size > 0)
                model.set(row, ITEM_VIEW_COLUMN_ICON, icon_img);

            model.set(
                row,
                ITEM_VIEW_COLUMN_NAME, name,
                ITEM_VIEW_COLUMN_MATCH, match,
                ITEM_VIEW_COLUMN_APPINFO, app_info,
                ITEM_VIEW_COLUMN_ACTION, action
            );
            return row;
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
        // that rows hidden by text typed before the list arrived, and the actions under
        // their apps, still get their icons
        private void start_icon_loading() {
            var queued = new GenericSet<string>(str_hash, str_equal);
            TreeIter filter_iter;
            for (bool next = filter.get_iter_first(out filter_iter); next; next = filter.iter_next(ref filter_iter)) {
                TreeIter child_iter;
                filter.convert_iter_to_child_iter(out child_iter, filter_iter);
                icon_queue += child_iter;
                queued.add(model.get_string_from_iter(child_iter));
            }
            model.@foreach((rows, row_path, row) => {
                if (!(row_path.to_string() in queued))
                    icon_queue += row;
                return false;
            });
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
                        // GtkTreeStore iterators persist across re-sorting and rows are never removed
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
