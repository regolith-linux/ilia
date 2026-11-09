using Gtk;

namespace Ilia {
    class WindowPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 3;
        private const int ITEM_VIEW_COLUMN_APP_ICON = 0;
        private const int ITEM_VIEW_COLUMN_TITLE = 1;
        private const int ITEM_VIEW_COLUMN_ID = 2;

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
        // Active icon theme
        private Gtk.IconTheme icon_theme;

        private int icon_size;

        private Gtk.TreePath path;

        private string wm_name;

        private bool is_wayland;

        public string get_name() {
            return "<u>W</u>indows";
        }

        public string get_icon_name() {
            return "window-new";
        }

        public string get_help() {
            return "This dialog allows for navigating between open windows in the desktop environment.  Selecting a window from the list will cause it to be viewed on screen and focused.";
        }

        public char get_keybinding() {
            return 'w';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Navigate to Window");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.wm_name = wm_name;
            this.is_wayland = is_wayland;

            icon_size = settings.get_int("icon-size");

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            load_windows();
            model.set_sort_column_id(1, SortType.ASCENDING);
            // model.set_sort_func (0, app_sort_func);
            set_selection();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            // With fixed_height_mode GTK sizes the column from one row: a fixed size keeps every
            // icon shown when that row has none
            var icon_renderer = new CellRendererPixbuf();
            if (icon_size > 0)
                icon_renderer.set_fixed_size(icon_size, icon_size);
            item_view.insert_column_with_attributes(-1, "App", icon_renderer, "pixbuf", ITEM_VIEW_COLUMN_APP_ICON);
            item_view.insert_column_with_attributes(-1, "Title", new CellRendererText(), "text", ITEM_VIEW_COLUMN_TITLE);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);
        }

        public void show() {
            item_view.grab_focus();
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (handle_emacs_vim_nav(item_view, path, event_key))
                return true;

            // Typed text that matches no item is not something this page can act on, so Enter does nothing then
            return false;
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            filter.get_iter(out iter, row_path);
            _from_selection(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            filter.refilter();
            set_selection();
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (filter.get_iter(out iter, path))
                _from_selection(iter);
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text().down().strip();

            if (queryString.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value(iter, ITEM_VIEW_COLUMN_TITLE, out app_info);
                strval = app_info.get_string();

                return matches_all_words(queryString, { strval });
            } else {
                return true;
            }
        }

        private void load_windows() {
            try {
                var ipc_client = new IPCClient(this.wm_name);
                var node = ipc_client.getTree();

                if (node != null) {
                    icon_theme = Gtk.IconTheme.get_default();
                    traverse_nodes(node);
                }
            } catch (GLib.Error err) {
                // TODO consistent error handling
                stderr.printf("Failed to read or parse window tree from %s: %s\n", this.wm_name, err.message);
            }
        }

        private void traverse_nodes(TreeReply node) {
            if (navigable_window(node, is_wayland)) {
                Gdk.Pixbuf pixbuf = load_icon_from_app_name(icon_theme, icon_app_name(node), icon_size);
                if (pixbuf == null) // the app has no icon, or it cannot be loaded
                    pixbuf = load_icon_from_name(icon_theme, "application-x-executable", icon_size);

                model.append(out iter);
                model.set(
                    iter,
                    ITEM_VIEW_COLUMN_APP_ICON, pixbuf,
                    ITEM_VIEW_COLUMN_TITLE, node.name,
                    ITEM_VIEW_COLUMN_ID, node.id
                );
            }

            if (node.nodes != null) {
                for (int i = 0; i < node.nodes.length; ++i) {
                    traverse_nodes(node.nodes[i]);
                }
            }

            if (node.floating_nodes != null) {
                for (int i = 0; i < node.floating_nodes.length; ++i) {
                    traverse_nodes(node.floating_nodes[i]);
                }
            }
        }

        /**
         * Filter controls which TreeReply instances should be shown in window view
         *
         * Every window the window manager manages is listed, dialogs included, as sway does.
         * i3 reports the type of each window; dock windows (bars) are left out.
         */
        public static bool navigable_window(TreeReply node, bool is_wayland) {
            bool is_window = node.ntype == "con" || node.ntype == "floating_con";         // specifies actual windows
            bool is_listed_type = (node.window_type != null && node.window_type != "dock") // X11 window, not a bar
                                  || is_wayland && node.layout == "none";                  // leaf container in sway
            bool is_i3bar = node.windowProperties != null && node.windowProperties.clazz == "i3bar";

            return is_window && is_listed_type && !is_i3bar;
        }

        /**
         * The name to look a window's icon up by: the instance of an X11 or Xwayland window,
         * the app id of a native Wayland window, which has no window properties.
         */
        public static string ? icon_app_name(TreeReply node) {
            if (node.windowProperties != null && node.windowProperties.instance != null)
                return node.windowProperties.instance;
            return node.app_id;
        }

        // Highlight the first row: the best match for the text typed
        private void set_selection() {
            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            if (path == null)
                path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
        }

        // switch to window
        public void _from_selection(Gtk.TreeIter selection) {
            string id;
            filter.@get(selection, ITEM_VIEW_COLUMN_ID, out id);

            focus_window(id);
        }

        // [window_role="gnome-terminal-window-6bee2ec0-eb8b-4b10-aafc-7c2708201d43" title="Terminal"] focus
        private void focus_window(string id) {
            string exec = "[con_id=\"" + id + "\"] focus";
            string cli_bin = get_wm_cli(this.wm_name);

            if (cli_bin == null) {
                stderr.printf("Error: Cannot focus window - action not supported for your WM.\n");
                return;
            }

            string commandline = cli_bin + exec;

            try {
                var app_info = AppInfo.create_from_commandline(commandline, null, AppInfoCreateFlags.NONE);

                if (!app_info.launch(null, null))
                    stderr.printf("Error: execute_keybinding failed\n");
                session_controller.quit();
            } catch (GLib.Error err) {
                stderr.printf("Error: execute_keybinding failed: %s\n", err.message);
            }
        }
    }
}
