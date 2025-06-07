using Gtk;

namespace Ilia {
    class DesktopAppPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 5;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_KEYWORDS = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;
        private const int ITEM_VIEW_COLUMN_IS_FAVORITE = 4;

        // Number of past launches to store (to determine sort rank)
        private const uint HISTORY_MAX_LEN = 32;
        // Max number of files to read in sequence before yeilding
        private const int FS_FILE_READ_COUNT = 128;
        // Roots of app dirs env var.  See https://github.com/flatpak/flatpak/issues/1286#issuecomment-354554684
        private const string XDG_DATA_DIRS = "XDG_DATA_DIRS";

        // Backup suffix for desktop files
        private const string BACKUP_SUFFIX = ".ilia-backup";

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
        private string[] favorite_apps;

        private HashTable<string, int> launch_counts;

        private int icon_size;

        private int post_launch_sleep;

        private Gtk.Widget root_widget;

        private Gtk.TreePath path;

        private Thread<void> iconLoadThread;

        // Popover for displaying app actions
        private Gtk.Popover actions_popover;
        private Gtk.TreeView actions_view;
        private Gtk.ListStore actions_model;
        private Gtk.TreePath actions_path;
        private bool actions_popover_visible = false;
        private const int ACTION_VIEW_COLUMNS = 3;
        private const int ACTION_VIEW_COLUMN_ICON = 0;
        private const int ACTION_VIEW_COLUMN_NAME = 1;
        private const int ACTION_VIEW_COLUMN_ID = 2;
        // Store the selected app when popover is open
        private DesktopAppInfo current_app_info;

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
            keybindings.set("alt+d", "Toggle Desktop Actions");
            keybindings.set("ctrl+s", "Toggle Favorite");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.settings = settings;
            this.entry = entry;
            this.session_controller = sessionController;

            launch_history = settings.get_strv("app-launch-counts");
            favorite_apps = settings.get_strv("favorite-apps");
            launch_counts = load_launch_counts(launch_history);
            icon_size = settings.get_int("icon-size");
            post_launch_sleep = settings.get_int("post-launch-sleep");

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (DesktopAppInfo), typeof (bool));

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

        // Helper function to check if a string is in an array
        private bool string_in_array(string needle, string[] haystack) {
            if (haystack == null) return false;
            
            foreach (string item in haystack) {
                if (item == needle) {
                    return true;
                }
            }
            
            return false;
        }

        public bool key_event(Gdk.EventKey key) {
            //Ctrl+D to hide the popover if open
            if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK && (key.keyval == 'd' || key.keyval == 'D')) {
                if (actions_popover_visible) {
                    hide_app_actions();
                    return true;
                }
            }
            
            // Ctrl+S to toggle favorite
            if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK && (key.keyval == 's' || key.keyval == 'S')) {
                Gtk.TreeSelection selection = item_view.get_selection();
                Gtk.TreeModel model;
                Gtk.TreeIter iter;
                if (selection.get_selected(out model, out iter)) {
                    DesktopAppInfo app_info;
                    filter.@get(iter, ITEM_VIEW_COLUMN_APPINFO, out app_info);
                    if (app_info != null) {
                        toggle_favorite(app_info);
                    }
                }
                return true;
            }
            // Alt+S to go up in popover
            if ((key.state & Gdk.ModifierType.MOD1_MASK) == Gdk.ModifierType.MOD1_MASK && (key.keyval == 's' || key.keyval == 'S')) {
                if (actions_popover_visible) {
                    navigate_actions_popover(true); // Up
                }
                return true;
            }
            // Alt+D to go down in popover and open popover if not open
            if ((key.state & Gdk.ModifierType.MOD1_MASK) == Gdk.ModifierType.MOD1_MASK && (key.keyval == 'd' || key.keyval == 'D')) {
                if (actions_popover_visible) {
                    navigate_actions_popover(false); // Down
                } else {
                    show_app_actions();
                }
                return true;
            }
            // Handle popover navigation if it's visible
            if (actions_popover_visible) {
                // Ctrl+Left to close the popover
                if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) {
                    if (key.keyval == KEY_CODE_LEFT) {
                        hide_app_actions();
                        return true;
                    }
                }
                              
                if (key.keyval == KEY_CODE_ENTER) {
                    stdout.printf("Enter key pressed in actions popover\n");
                    launch_selected_action();
                    return true;
                }
                
                if (key.keyval == KEY_CODE_ESCAPE) {
                    hide_app_actions();
                    return true;
                }
                
                return true; // Capture all key events when popover is visible
            }
            
            return handle_emacs_vim_nav(item_view, path, key);
        }

        // Helper method to navigate the actions popover
        private void navigate_actions_popover(bool up) {
            Gtk.TreeSelection selection = actions_view.get_selection();
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            
            if (selection.get_selected(out model, out iter)) {
                Gtk.TreePath path;
                path = model.get_path(iter);
                
                if (up && path.prev()) {
                    actions_view.set_cursor(path, null, false);
                } else if (!up) {
                    path.next();
                    if (model.get_iter(out iter, path)) {
                        actions_view.set_cursor(path, null, false);
                    }
                }
            } else {
                // No selection yet, select first
                actions_path = new Gtk.TreePath.first();
                actions_view.set_cursor(actions_path, null, false);
            }
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
            hide_app_actions();
        }

        public void show() {
            item_view.grab_focus ();
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
            hide_app_actions();
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
            // execute selected option from popover.
            if (actions_popover_visible) {
                launch_selected_action();
                return;
            }
            
            if (filter.get_iter(out iter, path))
                execute_app(iter);
        }

        private int app_sort_func(TreeModel model, TreeIter a, TreeIter b) {
            DesktopAppInfo app_a;
            model.@get(a, ITEM_VIEW_COLUMN_APPINFO, out app_a);
            DesktopAppInfo app_b;
            model.@get(b, ITEM_VIEW_COLUMN_APPINFO, out app_b);

            // Check if either app is a favorite
            bool is_favorite_a;
            model.@get(a, ITEM_VIEW_COLUMN_IS_FAVORITE, out is_favorite_a);
            bool is_favorite_b;
            model.@get(b, ITEM_VIEW_COLUMN_IS_FAVORITE, out is_favorite_b);

            // Favorites go on top
            if (is_favorite_a && !is_favorite_b) {
                return -1;
            } else if (!is_favorite_a && is_favorite_b) {
                return 1;
            }

            // If both are favorites or both are not favorites, sort alphabetically first
            var app_a_name = app_a.get_name().down();
            var app_b_name = app_b.get_name().down();
            
            return app_a_name.ascii_casecmp(app_b_name);
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

                // Check if this is a favorite app (will be used for sorting)
                model.get_value(iter, ITEM_VIEW_COLUMN_IS_FAVORITE, out app_info);
                bool is_favorite = app_info.get_boolean();

                // Exact substring match - highest priority
                if (strval != null && strval.down().contains(query_string)) {
                    return true;
                }

                //fuzzy matching on the app name
                if (strval != null && fuzzy_match(strval, query_string, 50)) {
                    return true;
                }

                // Check in keywords as well
                model.get_value(iter, ITEM_VIEW_COLUMN_KEYWORDS, out app_info);
                strval = app_info.get_string();

                // Try exact substring match on keywords
                if (strval != null && strval.down().contains(query_string)) {
                    return true;
                }

                // Try fuzzy matching on keywords with a lower threshold
                if (strval != null && fuzzy_match(strval, query_string, 40)) {
                    return true;
                }

                return false;
            } else {
                return true; // Show all items when no query
            }
        }

        private void load_apps() {
            // var start_time = get_monotonic_time();
            // determine theme for icons
            icon_theme = Gtk.IconTheme.get_default ();
            // Set a blank icon to avoid visual jank as real icons are loaded
            Gdk.Pixbuf blank_icon = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, icon_size, icon_size);

            var app_list = AppInfo.get_all ();
            foreach (AppInfo appinfo in app_list) {
                read_desktop_file(appinfo, blank_icon);
            }
            // stdout.printf("time cost: %" + int64.FORMAT + "\n", (get_monotonic_time() - start_time));
        }

        private void read_desktop_file(AppInfo appInfo, Gdk.Pixbuf ? icon_img) {
            DesktopAppInfo app_info = new DesktopAppInfo(appInfo.get_id ());

            if (app_info != null && app_info.should_show ()) {
                model.append(out iter);

                var keywords = app_info.get_string("Comment") + app_info.get_string("Keywords");
                bool is_favorite = string_in_array(app_info.get_id(), favorite_apps);

                if (icon_size > 0)
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_ICON, icon_img,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name (),
                        ITEM_VIEW_COLUMN_KEYWORDS, keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info,
                        ITEM_VIEW_COLUMN_IS_FAVORITE, is_favorite
                    );
                else
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_NAME, app_info.get_name (),
                        ITEM_VIEW_COLUMN_KEYWORDS, keywords,
                        ITEM_VIEW_COLUMN_APPINFO, app_info,
                        ITEM_VIEW_COLUMN_IS_FAVORITE, is_favorite
                    );
            }
        }

        // Iterate over model and load icons
        void loadAppIcons() {
            // stdout.printf("loadAppIcons start: %" + int64.FORMAT + "\n", (get_monotonic_time() - start_time));
            TreeIter app_iter;
            Value app_info_val;

            for (bool next = model.get_iter_first(out app_iter); next; next = model.iter_next(ref app_iter)) {
                model.get_value(app_iter, ITEM_VIEW_COLUMN_APPINFO, out app_info_val);

                Gdk.Pixbuf icon = Ilia.load_icon_from_info(icon_theme, (DesktopAppInfo) app_info_val, icon_size);

                model.set(
                    app_iter,
                    ITEM_VIEW_COLUMN_ICON, icon
                );
            }
            // stdout.printf("loadAppIcons end  : %" + int64.FORMAT + "\n", (get_monotonic_time() - start_time));
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

        // Show a popover with available actions for the selected app
        private void show_app_actions() {
            hide_app_actions();
            if (actions_popover != null) {
                actions_popover.destroy();
                actions_popover = null;
                actions_view = null;
                actions_model = null;
            }
            Gtk.TreeSelection selection = item_view.get_selection();
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            if (!selection.get_selected(out model, out iter)) {
                return;
            }
            DesktopAppInfo app_info;
            filter.@get(iter, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            if (app_info == null) {
                return;
            }
            
            // Store the current app info for use when popover is open
            current_app_info = app_info;
            // Clear previous selection
            item_view.get_selection().unselect_all();
            string[] actions = app_info.list_actions();
            create_actions_popover();
            actions_model.clear();
            
            // Get ready for generic options and app actions
            Gtk.TreeIter gen_iter;
            
            // Check if app is a favorite
            bool is_favorite;
            model.@get(iter, ITEM_VIEW_COLUMN_IS_FAVORITE, out is_favorite);
            
            // First populate available .desktop actions
            if (actions.length > 0) {
                // Populate available actions
                Gtk.TreeIter action_iter;
                foreach (string action_id in actions) {
                    string action_name = app_info.get_action_name(action_id);
                    // If no name, skip
                    if (action_name == null || action_name == "") {
                        continue;
                    }
                    
                    actions_model.append(out action_iter);
                    
                    Gdk.Pixbuf? action_icon = null;
                    if (icon_size > 0) {
                        // Try to get an icon for the action (use app icon as fallback)
                        string icon_name = "document-properties"; // Default icon
                        action_icon = Ilia.load_icon_from_name(icon_theme, icon_name, icon_size);
                    }
                    
                    actions_model.set(
                        action_iter,
                        ACTION_VIEW_COLUMN_ICON, action_icon,
                        ACTION_VIEW_COLUMN_NAME, action_name,
                        ACTION_VIEW_COLUMN_ID, action_id
                    );
                }
            }
            
                // Now add the favorite toggle option
            actions_model.append(out gen_iter);
            Gdk.Pixbuf? star_icon = null;
            if (icon_size > 0) {
                star_icon = Ilia.load_icon_from_name(icon_theme, 
                    is_favorite ? "starred-symbolic" : "non-starred-symbolic", icon_size);
            }
            actions_model.set(
                gen_iter,
                ACTION_VIEW_COLUMN_ICON, star_icon,
                ACTION_VIEW_COLUMN_NAME, is_favorite ? "Remove from Favorites" : "Add to Favorites",
                ACTION_VIEW_COLUMN_ID, "generic-favorite"
            );
            
            
            // Option 1: Open app in terminal
            actions_model.append(out gen_iter);
            Gdk.Pixbuf? terminal_icon = null;
            if (icon_size > 0) {
                terminal_icon = Ilia.load_icon_from_name(icon_theme, "utilities-terminal", icon_size);
            }
            actions_model.set(
                gen_iter,
                ACTION_VIEW_COLUMN_ICON, terminal_icon,
                ACTION_VIEW_COLUMN_NAME, "Open in Terminal",
                ACTION_VIEW_COLUMN_ID, "generic-terminal"
            );
            
            // Option 2: Create desktop shortcut
            actions_model.append(out gen_iter);
            Gdk.Pixbuf? shortcut_icon = null;
            if (icon_size > 0) {
                shortcut_icon = Ilia.load_icon_from_name(icon_theme, "emblem-symbolic-link", icon_size);
            }
            actions_model.set(
                gen_iter,
                ACTION_VIEW_COLUMN_ICON, shortcut_icon,
                ACTION_VIEW_COLUMN_NAME, "Create Desktop Shortcut",
                ACTION_VIEW_COLUMN_ID, "generic-shortcut"
            );
            
            // Option 3: Open app folder
            actions_model.append(out gen_iter);
            Gdk.Pixbuf? folder_icon = null;
            if (icon_size > 0) {
                folder_icon = Ilia.load_icon_from_name(icon_theme, "folder", icon_size);
            }
            actions_model.set(
                gen_iter,
                ACTION_VIEW_COLUMN_ICON, folder_icon,
                ACTION_VIEW_COLUMN_NAME, "Open App Folder",
                ACTION_VIEW_COLUMN_ID, "generic-folder"
            );
            
            // Add workspace management options
            actions_model.append(out gen_iter);
            Gdk.Pixbuf? workspace_icon = null;
            if (icon_size > 0) {
                workspace_icon = Ilia.load_icon_from_name(icon_theme, "view-grid-symbolic", icon_size);
            }
            actions_model.set(
                gen_iter,
                ACTION_VIEW_COLUMN_ICON, workspace_icon,
                ACTION_VIEW_COLUMN_NAME, "Open in New Workspace",
                ACTION_VIEW_COLUMN_ID, "generic-new-workspace"
            );
            
            
            // Position the popover relative to the selected item
            Gtk.TreePath tree_path;
            Gtk.TreeViewColumn column;
            item_view.get_cursor(out tree_path, out column);
            if (tree_path != null) {
                Gdk.Rectangle rect;
                item_view.get_cell_area(tree_path, column, out rect);
                actions_popover.set_pointing_to(rect);
                actions_path = new Gtk.TreePath.first();
                actions_view.get_selection().select_path(actions_path);
            }
            actions_popover.show_all();
            actions_popover_visible = true;
            actions_path = new Gtk.TreePath.first();
            actions_view.set_cursor(actions_path, null, false);
            
            // focus on action view
            Timeout.add(100, () => {
                actions_view.grab_focus();
                return false;
            });
        }
        
        // Create the popover and its contents
        private void create_actions_popover() {
            actions_popover = new Gtk.Popover(item_view);
            actions_popover.set_position(Gtk.PositionType.RIGHT);
            actions_popover.set_modal(true); // Set to true to capture input events
            actions_model = new Gtk.ListStore(ACTION_VIEW_COLUMNS, typeof(Gdk.Pixbuf), typeof(string), typeof(string));
            actions_view = new Gtk.TreeView.with_model(actions_model);
            actions_view.headers_visible = false;
            actions_view.enable_search = false;
            if (icon_size > 0) {
                actions_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ACTION_VIEW_COLUMN_ICON);
            }
            actions_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ACTION_VIEW_COLUMN_NAME);
            actions_view.get_selection().set_mode(SelectionMode.SINGLE);
            actions_view.row_activated.connect(on_action_activated);
            
            // Add direct key press handler to the actions view
            actions_view.key_press_event.connect((key) => {
                if (key.keyval == KEY_CODE_ENTER) {
                    stdout.printf("Direct Enter key press in actions_view\n");
                    launch_selected_action();
                    return true;
                }
                return false;
            });
            
            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(actions_view);
            scrolled.set_size_request(200, 250);
            actions_popover.add(scrolled);
            // Always reset state and focus when popover is closed
            actions_popover.closed.connect(() => {
                actions_popover_visible = false;
                item_view.grab_focus();
                // Destroy popover to avoid stale state
                if (actions_popover != null) {
                    actions_popover.destroy();
                    actions_popover = null;
                    actions_view = null;
                    actions_model = null;
                }
            });
        }
        
        // Launch the selected action
        private void launch_selected_action() {
            Gtk.TreeSelection selection = actions_view.get_selection();
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            
            if (!selection.get_selected(out model, out iter)) {
                hide_app_actions();
                return;
            }
            
            // Get action ID
            if (current_app_info == null) {
                hide_app_actions();
                return;
            }
            
            // Use the stored app info instead of trying to get it from the selection
            DesktopAppInfo app_info = current_app_info;
            
            string action_id;
            actions_model.@get(iter, ACTION_VIEW_COLUMN_ID, out action_id);
            
            // Handle separator
            if (action_id == "generic-separator") {
                return;
            }
            
            // Handle generic actions
            if (action_id.has_prefix("generic-")) {
                string? desktop_file_path = app_info.get_filename();
                string wm_cmd = get_wm_cli(this.session_controller.get_wm_name());
                
                switch (action_id) {
                    case "generic-favorite":
                        // Toggle favorite status
                        toggle_favorite(app_info);
                        hide_app_actions();
                        break;
                
                    case "generic-terminal":
                        try {
                            // Get the exec line from desktop file
                            var key_file = new KeyFile();
                            key_file.load_from_file(desktop_file_path, KeyFileFlags.NONE);
                            string exec_line = key_file.get_string("Desktop Entry", "Exec");
                            
                            // Strip % arguments
                            string clean_exec = "";
                            bool in_arg = false;
                            
                            for (int i = 0; i < exec_line.length; i++) {
                                if (exec_line[i] == '%') {
                                    in_arg = true;
                                    continue;
                                }
                                
                                if (in_arg) {
                                    in_arg = false;
                                    continue;
                                }
                                
                                clean_exec += exec_line[i].to_string();
                            }
                            
                            // Launch in terminal
                            string terminal_cmd = "x-terminal-emulator -e " + clean_exec.strip();
                            string[] args = {"sh", "-c", terminal_cmd};
                            Process.spawn_async(null, args, null, SpawnFlags.SEARCH_PATH, null, null);
                            hide_app_actions();
                            session_controller.quit();
                        } catch (Error e) {
                            stderr.printf("Failed to launch in terminal: %s\n", e.message);
                            hide_app_actions();
                        }
                        break;
                        
                    case "generic-shortcut":
                        try {
                            // Create desktop shortcut
                            string home_dir = Environment.get_home_dir();
                            string desktop_dir = Path.build_filename(home_dir, "Desktop");
                            
                            // Ensure desktop directory exists
                            var dir = File.new_for_path(desktop_dir);
                            if (!dir.query_exists()) {
                                dir.make_directory_with_parents();
                            }
                            
                            // Copy desktop file to Desktop folder
                            var source = File.new_for_path(desktop_file_path);
                            var dest = File.new_for_path(Path.build_filename(desktop_dir, Path.get_basename(desktop_file_path)));
                            
                            source.copy(dest, FileCopyFlags.OVERWRITE);
                            
                            // Make it executable
                            FileUtils.chmod(dest.get_path(), 0755);
                            
                            hide_app_actions();
                            
                            // Show a temporary notification
                            show_notification("Desktop shortcut created");
                        } catch (Error e) {
                            stderr.printf("Failed to create desktop shortcut: %s\n", e.message);
                            hide_app_actions();
                        }
                        break;
                        
                    case "generic-folder":
                        try {
                            // Open the folder containing the desktop file
                            string folder_path = Path.get_dirname(desktop_file_path);
                            string[] args = {"xdg-open", folder_path};
                            Process.spawn_async(null, args, null, SpawnFlags.SEARCH_PATH, null, null);
                            hide_app_actions();
                            session_controller.quit();
                        } catch (Error e) {
                            stderr.printf("Failed to open app folder: %s\n", e.message);
                            hide_app_actions();
                        }
                        break;
                        
                    case "generic-new-workspace":
                        try {
                            // Get the app command
                            var key_file = new KeyFile();
                            key_file.load_from_file(desktop_file_path, KeyFileFlags.NONE);
                            string exec_line = key_file.get_string("Desktop Entry", "Exec");
                            string clean_exec = "";
                            bool in_arg = false;
                            for (int i = 0; i < exec_line.length; i++) {
                                if (exec_line[i] == '%') {
                                    in_arg = true;
                                    continue;
                                }
                                if (in_arg) {
                                    in_arg = false;
                                    continue;
                                }
                                clean_exec += exec_line[i].to_string();
                            }
                            clean_exec = clean_exec.strip();
                            string[] args;
                            var wm_cmd_newws = get_wm_cli(this.session_controller.get_wm_name());
                            if (wm_cmd_newws != null) {
                                // For i3/sway: switch to next workspace and launch app
                                string launch_cmd = wm_cmd_newws + " workspace next && " + clean_exec;
                                args = {"sh", "-c", launch_cmd};
                            } else {
                                args = {"sh", "-c", clean_exec};
                            }
                            Process.spawn_async(null, args, null, SpawnFlags.SEARCH_PATH, null, null);
                            hide_app_actions();
                            session_controller.quit();
                        } catch (Error e) {
                            stderr.printf("Failed to launch in new workspace: %s\n", e.message);
                            hide_app_actions();
                        }
                        return;
                        
                    default:
                        hide_app_actions();
                        break;
                }
                return;
            }
            
            // Launch regular app action
            try {
                // Create empty AppLaunchContext instead of passing null
                AppLaunchContext context = new AppLaunchContext();
                app_info.launch_action(action_id, context);
                hide_app_actions();
                session_controller.quit();
            } catch (Error e) {
                stderr.printf("Failed to launch action: %s\n", e.message);
                hide_app_actions();
            }
        }
        
        // Toggle favorite status of an app
        private void toggle_favorite(DesktopAppInfo app_info) {
            string app_id = app_info.get_id();
            bool is_favorite = string_in_array(app_id, favorite_apps);
            
            if (is_favorite) {
                // Remove from favorites
                string[] new_favorites = {};
                foreach (string fav in favorite_apps) {
                    if (fav != app_id) {
                        new_favorites += fav;
                    }
                }
                favorite_apps = new_favorites;
            } else {
                // Add to favorites
                string[] new_favorites = favorite_apps;
                new_favorites += app_id;
                favorite_apps = new_favorites;
            }
            
            // Update settings
            settings.set_strv("favorite-apps", favorite_apps);
            
            // Update the model
            Gtk.TreeIter iter;
            bool valid = model.get_iter_first(out iter);
            
            while (valid) {
                DesktopAppInfo current_app;
                model.get(iter, ITEM_VIEW_COLUMN_APPINFO, out current_app);
                
                if (current_app.get_id() == app_id) {
                    // Update the favorite flag
                    model.set(iter, ITEM_VIEW_COLUMN_IS_FAVORITE, !is_favorite);
                    break;
                }
                
                valid = model.iter_next(ref iter);
            }
            
            // Refresh the view
            on_entry_changed();
            
            // Show confirmation notification
            if (is_favorite) {
                show_notification(@"$(app_info.get_name()) removed from favorites");
            } else {
                show_notification(@"$(app_info.get_name()) added to favorites");
            }
        }
        
        // Show a temporary notification
        private void show_notification(string message) {
            try {
                Notify.Notification notification = new Notify.Notification("Ilia", message, "org.regolith-linux.ilia");
                notification.set_timeout(2000); // 2 seconds
                notification.show();
            } catch (Error e) {
                stderr.printf("Failed to show notification: %s\n", e.message);
            }
        }
        
        // Called when an action is activated via click or enter
        private void on_action_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            launch_selected_action();
        }
        
        // Hide the actions popover
        private void hide_app_actions() {
            if (actions_popover != null && actions_popover_visible) {
                actions_popover.hide();
                actions_popover_visible = false;
                
                // Restore the app selection
                if (path != null) {
                    item_view.get_selection().select_path(path);
                }
                
                item_view.grab_focus();
            }
        }
    }
}
