using Gtk;

namespace Ilia {
    /**
     * Describes another page: what it is for, its keys, and the keys that work on every page.
     * The keys are a list that scrolls, so the page fits any window size and the
     * navigation keys move through it like through the other pages' lists.
     */
    class HelpPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMN_KEY = 0;
        private const int ITEM_VIEW_COLUMN_FUNCTION = 1;

        // The pages of the dialog, this one excluded; their letters are listed as keys
        private DialogPage[] pages;
        // The page being described
        private DialogPage described;
        // Alt and this letter show the page; 0 if another page already has it
        private char letter = 'h';

        private Gtk.Label title_label;
        private Gtk.Label help_label;
        private Gtk.ListStore model;
        private Gtk.TreeView item_view;
        private Gtk.TreePath path;
        private Gtk.Widget root_widget;

        public HelpPage(DialogPage[] pages) {
            this.pages = pages;
            this.described = pages[0];
            foreach (var page in pages) {
                if (page.get_keybinding() == letter)
                    letter = 0;
            }
        }

        public string get_name() {
            return "<u>H</u>elp";
        }

        public string get_icon_name() {
            return "help-browser";
        }

        public string get_help() {
            return "This page describes the page shown before it and lists the keys that work there.";
        }

        public char get_keybinding() {
            return letter;
        }

        public HashTable<string, string> ? get_keybindings() {
            return null;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            title_label = new Gtk.Label(null);
            title_label.get_style_context().add_class("help_heading");
            title_label.xalign = 0;

            help_label = new Gtk.Label(null);
            help_label.set_line_wrap(true);
            help_label.xalign = 0;

            var keys_title = new Gtk.Label("Keys");
            keys_title.get_style_context().add_class("help_heading");
            keys_title.xalign = 0;

            model = new Gtk.ListStore(2, typeof (string), typeof (string));
            item_view = new Gtk.TreeView.with_model(model);
            item_view.headers_visible = false;
            item_view.enable_search = false;
            item_view.insert_column_with_attributes(-1, "Key", new CellRendererText(), "text", ITEM_VIEW_COLUMN_KEY);
            item_view.insert_column_with_attributes(-1, "Function", new CellRendererText(), "text", ITEM_VIEW_COLUMN_FUNCTION);
            item_view.get_selection().set_mode(SelectionMode.SINGLE);

            // The list takes the room the text leaves and scrolls within it
            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.set_policy(PolicyType.NEVER, PolicyType.AUTOMATIC);
            scrolled.add(item_view);
            scrolled.expand = true;

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
            box.pack_start(title_label, false, false, 0);
            box.pack_start(help_label, false, false, 0);
            box.pack_start(keys_title, false, false, 0);
            box.pack_start(scrolled, true, true, 0);
            root_widget = box;

            describe(described);
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        /**
         * Show the help of page.
         */
        public void describe(DialogPage page) {
            described = page;
            if (model == null)
                return;

            title_label.set_text(plain_page_name(page.get_name()));
            help_label.set_text(page.get_help());

            string[] keys, functions;
            help_rows(page.get_keybindings(), page_switch_keys(), out keys, out functions);
            model.clear();
            for (int i = 0; i < keys.length; ++i) {
                Gtk.TreeIter iter;
                model.append(out iter);
                model.set(iter, ITEM_VIEW_COLUMN_KEY, keys[i], ITEM_VIEW_COLUMN_FUNCTION, functions[i]);
            }

            path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
        }

        // "Alt+letter" and what it shows, for each page with a letter, this one included
        private string[] page_switch_keys() {
            DialogPage[] all = pages;
            all += this;

            string[] rows = {};
            foreach (var page in all) {
                char letter = page.get_keybinding();
                if (letter == 0)
                    continue;
                rows += "Alt+%c".printf(letter);
                rows += "Show %s".printf(plain_page_name(page.get_name()));
            }
            return rows;
        }

        /**
         * The rows of the keys list: the page's own keys (by key), then the keys of every page.
         * page_switch_keys holds pairs of a key and what it does.
         */
        public static void help_rows(HashTable<string, string> ? page_keys, string[] page_switch_keys,
                                     out string[] keys, out string[] functions) {
            string[] key_list = {};
            string[] function_list = {};

            if (page_keys != null) {
                var names = page_keys.get_keys();
                names.sort(strcmp);
                foreach (unowned string name in names) {
                    key_list += name;
                    function_list += page_keys.get(name);
                }
            }

            const string[] COMMON = {
                "↑ ↓", "Change Selected Item",
                "Page Up Page Down", "Move One Page",
                "Home End", "Select First or Last Item",
                "Ctrl+p Ctrl+n", "Change Selected Item (emacs style)",
                "Ctrl+k Ctrl+j", "Change Selected Item (vim style)",
                "← →", "Switch Page",
            };
            for (int i = 0; i + 1 < COMMON.length; i += 2) {
                key_list += COMMON[i];
                function_list += COMMON[i + 1];
            }
            for (int i = 0; i + 1 < page_switch_keys.length; i += 2) {
                key_list += page_switch_keys[i];
                function_list += page_switch_keys[i + 1];
            }

            key_list += "Alt -";
            function_list += "Decrease Dialog Size";
            key_list += "Alt +";
            function_list += "Increase Dialog Size";
            key_list += "Esc";
            function_list += "Exit";

            keys = key_list;
            functions = function_list;
        }

        // A page name without the markup that underlines its letter
        public static string plain_page_name(string name) {
            string text;
            try {
                if (Pango.parse_markup(name, -1, 0, null, out text, null))
                    return text;
            } catch (GLib.Error e) {
            }
            return name;
        }

        public void on_entry_changed() {
        }

        public void on_entry_activated() {
        }

        public bool key_event(Gdk.EventKey event_key) {
            return handle_emacs_vim_nav(item_view, path, event_key);
        }

        public void show() {
            item_view.grab_focus();
        }
    }
}
