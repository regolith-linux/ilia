using Gtk;

namespace Ilia {
    /**
     * A page from a file that lists desktop entries (the Apps key), in the order the file gives
     *
     * Entries that are not installed, or that the desktop-entry rules hide here, are left out.
     * Rows are matched as on the apps page, with its match-fields and fuzzy-matching settings,
     * but never re-sorted; choosing one starts the app as the apps page does.
     */
    class PageFileAppsPage : PageFilePage {
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_MATCH = 2;
        private const int ITEM_VIEW_COLUMN_APPINFO = 3;

        private Gtk.TreeView item_view;
        private Gtk.ListStore model;
        private Gtk.TreeModelFilter filter;
        private Gtk.TreePath path;
        private Gtk.Widget root_widget;
        private Gtk.Entry entry;
        // Starts the chosen app and closes ilia
        private AppLauncher launcher;
        // Rows that fail the word rule are shown when the words are subsequences of the name
        private bool fuzzy_matching;
        // The words of the filter text the rows were last matched against
        private string[] ranked_words = {};

        public PageFileAppsPage (PageFile file, char keybinding) {
            base(file, keybinding);
        }

        public override string get_help() {
            return "This page lists the applications given by the page file %s. Choosing one launches it.".printf(file.path);
        }

        public override HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Launch Application");

            return keybindings;
        }

        public override void show() {
            item_view.grab_focus();
        }

        public override Gtk.Widget get_root() {
            return root_widget;
        }

        public override async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            launcher = new AppLauncher(settings, sessionController);
            fuzzy_matching = settings.get_boolean("fuzzy-matching");
            var match_fields = AppField.NAME | AppField.from_names(settings.get_strv("match-fields"));
            int icon_size = settings.get_int("icon-size");

            model = new Gtk.ListStore(4, typeof (Gdk.Pixbuf), typeof (string), typeof (AppMatch), typeof (DesktopAppInfo));
            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            var icon_theme = Gtk.IconTheme.get_default();
            foreach (unowned string desktop_id in file.apps) {
                DesktopAppInfo ? app_info = new DesktopAppInfo(desktop_id);
                // Not installed, failed TryExec, or not meant to be shown in this desktop
                if (app_info == null || app_info.get_is_hidden() || !app_info.should_show())
                    continue;

                var match = new AppMatch(desktop_id, app_info.get_name(), app_info.get_generic_name(),
                                         string.joinv(" ", app_info.get_keywords()), app_info.get_description(), match_fields);
                Gtk.TreeIter iter;
                model.append(out iter);
                model.set(
                    iter,
                    ITEM_VIEW_COLUMN_ICON, Ilia.load_icon_from_info(icon_theme, app_info, icon_size),
                    ITEM_VIEW_COLUMN_NAME, app_info.get_name(),
                    ITEM_VIEW_COLUMN_MATCH, match,
                    ITEM_VIEW_COLUMN_APPINFO, app_info
                );
            }

            item_view = new Gtk.TreeView.with_model(filter);
            item_view.get_style_context().add_class("item_view");
            item_view.headers_visible = false;
            item_view.fixed_height_mode = true;
            item_view.enable_search = false;
            if (icon_size > 0)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ITEM_VIEW_COLUMN_NAME);
            item_view.set_activate_on_single_click(true);
            item_view.row_activated.connect(on_row_activated);

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;
            root_widget = scrolled;

            set_selection();
        }

        // Highlight the first row
        private void set_selection() {
            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            if (path == null)
                path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
        }

        // As on the apps page: each word may match the name or one of the fields in match-fields
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            if (ranked_words.length == 0)
                return true;

            AppMatch match;
            m.@get(iter, ITEM_VIEW_COLUMN_MATCH, out match);
            return match != null && match.tier != AppTier.NONE;
        }

        public override bool key_event(Gdk.EventKey key) {
            return handle_emacs_vim_nav(item_view, path, key);
        }

        public override void on_entry_changed() {
            ranked_words = query_words(entry.get_text());

            Gtk.TreeIter iter;
            for (bool next = model.get_iter_first(out iter); next; next = model.iter_next(ref iter)) {
                AppMatch match;
                model.@get(iter, ITEM_VIEW_COLUMN_MATCH, out match);
                match.rank(ranked_words, fuzzy_matching);
            }
            filter.refilter();
            set_selection();
        }

        public override void on_entry_activated() {
            Gtk.TreeIter iter;
            if (filter.get_iter(out iter, path))
                execute_app(iter);
        }

        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            Gtk.TreeIter iter;
            if (filter.get_iter(out iter, row_path))
                execute_app(iter);
        }

        private void execute_app(Gtk.TreeIter selection) {
            DesktopAppInfo app_info;
            filter.@get(selection, ITEM_VIEW_COLUMN_APPINFO, out app_info);
            launcher.launch(app_info);
        }
    }
}
