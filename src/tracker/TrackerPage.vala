using Gtk;
using GLib;

namespace Ilia {
    class TrackerPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 3;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_TITLE = 1;
        private const int ITEM_VIEW_COLUMN_FILE = 2;

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // Access state from model
        private Gtk.TreeIter iter;

        private Gtk.Entry entry;

        private SessionContoller session_controller;

        private Gtk.Widget root_widget;
        // Active icon theme
        private Gtk.IconTheme icon_theme;

        // Number of microseconds to wait before exiting
        private int post_launch_sleep;

        private int icon_size;

        private Gtk.TreePath path;

        // Debounced, asynchronous search; the GTK main thread never waits for Tracker
        private SearchController search;
        // Icons by MIME type, so each type is looked up once
        private HashTable<string, Gdk.Pixbuf ?> icon_cache = new HashTable<string, Gdk.Pixbuf ?>(str_hash, str_equal);

        public string get_name() {
            return "<u>F</u>iles";
        }

        public string get_icon_name() {
            return "emblem-documents";
        }

        public string get_help() {
            return "This dialog allows for searching for files based on content. Type in a text query, hit enter and select from the list of files which contain the search string to open it.";
        }

        public char get_keybinding() {
            return 'f';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Open File");

            return keybindings;
        }

        public void show() {
            item_view.grab_focus();
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            icon_size = settings.get_int("icon-size");
            post_launch_sleep = settings.get_int("post-launch-sleep");

            // determine theme for icons
            icon_theme = Gtk.IconTheme.get_default();

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string));

            create_item_view();

            model.set_sort_column_id(1, SortType.ASCENDING);

            set_selection();

            search = new SearchController(new TrackerFileSearch(), new MainLoopScheduler());
            search.results.connect(on_search_results);

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
            item_view = new Gtk.TreeView.with_model(model);

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Title", new CellRendererText(), "text", ITEM_VIEW_COLUMN_TITLE);
            item_view.insert_column_with_attributes(-1, "Path", new CellRendererText(), "text", ITEM_VIEW_COLUMN_FILE);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (handle_emacs_vim_nav(item_view, path, event_key))
                return true;

            // Enter before the results for the typed text are in: open the first of them when they arrive
            if (event_key.keyval == Ilia.KEY_CODE_ENTER && search.activate())
                return true;

            // Typed text that matches no item is not something this page can act on, so Enter does nothing then
            return false;
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            model.get_iter(out iter, row_path);
            execute_app_from_selection(iter);
        }

        // Search for the contents of Entry once typing pauses
        void on_entry_changed() {
            search.text_changed(entry.get_text());
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (search.activate())
                return;
            if (model.get_iter(out iter, path))
                execute_app_from_selection(iter);
        }

        // Show the results for the current text; open the first if Enter was pressed while searching
        private void on_search_results(string text, GenericArray<FileHit> hits, bool activate) {
            model.clear();
            foreach (var hit in hits) {
                model.append(out iter);
                model.set(
                    iter,
                    ITEM_VIEW_COLUMN_ICON, icon_for_mime_type(hit.mime_type),
                    ITEM_VIEW_COLUMN_TITLE, hit.title,
                    ITEM_VIEW_COLUMN_FILE, hit.path
                );
            }
            set_selection();

            if (activate && model.get_iter(out iter, path))
                execute_app_from_selection(iter);
        }

        private Gdk.Pixbuf ? icon_for_mime_type(string mime_type) {
            if (icon_cache.contains(mime_type))
                return icon_cache.get(mime_type);

            Gdk.Pixbuf ? icon_pixbuf = null;
            var icon = ContentType.get_icon(mime_type) as ThemedIcon;
            if (icon != null) {
                foreach (unowned string icon_name in icon.get_names()) {
                    icon_pixbuf = Ilia.load_icon_from_name(icon_theme, icon_name, icon_size);
                    if (icon_pixbuf != null) break;
                }
            }

            if (icon_pixbuf == null)
                icon_pixbuf = Ilia.load_icon_from_name(icon_theme, "text-x-generic", icon_size);

            icon_cache.set(mime_type, icon_pixbuf);
            return icon_pixbuf;
        }

        // Automatically set the first item in the list as selected.
        private void set_selection() {
            Gtk.TreeSelection selection = item_view.get_selection();

            if (selection.count_selected_rows() == 0) {  // initial state, nothing explicitly selected by user
                selection.set_mode(SelectionMode.SINGLE);
                if (path == null)
                    path = new Gtk.TreePath.first();
                selection.select_path(path);
            } else { // an existing item has selection, ensure it's visible
                var path_list = selection.get_selected_rows(null);
                if (path_list != null) {
                    unowned var element = path_list.first();
                    item_view.scroll_to_cell(element.data, null, false, 0f, 0f);
                }
            }
        }

        // switch to window
        public void execute_app_from_selection(Gtk.TreeIter selection) {
            string file;
            model.@get(selection, ITEM_VIEW_COLUMN_FILE, out file);

            execute_app(file);
        }

        // tracker sparql -q "SELECT DISTINCT nie:url(?f) nie:title(?f) WHERE { ?f fts:match 'regolith' }"
        private void execute_app(string id) {
            try {
                var uri = GLib.Filename.to_uri(id);
                if (!AppInfo.launch_default_for_uri(uri, null))
                    stderr.printf("Error: execute_app failed\n");
            } catch (GLib.Error err) {
                stderr.printf("Error: execute_app failed: %s\n", err.message);
            }
            GLib.Thread.usleep(post_launch_sleep);
            session_controller.quit();
        }
    }
}
