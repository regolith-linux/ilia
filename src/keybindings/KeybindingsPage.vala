using Gtk;
using Gee;

namespace Ilia {
    class KeybingingsPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 5;
        private const int ITEM_VIEW_COLUMN_KEYBINDING = 0;
        private const int ITEM_VIEW_COLUMN_SUMMARY = 1;
        private const int ITEM_VIEW_COLUMN_EXEC = 2;
        private const int ITEM_VIEW_COLUMN_FOLDED_KEYBINDING = 3;
        private const int ITEM_VIEW_COLUMN_FOLDED_SUMMARY = 4;

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

        private Gtk.TreePath path;

        private string wm_name;

        // The binding has been run; ilia is closing
        private bool executed = false;

        // Bindings whose description or keys hold the words as subsequences are listed after the others
        private bool fuzzy_matching;

        private QueryWords query = new QueryWords();

        public string get_name() {
            return "<u>K</u>eybindings";
        }

        public string get_icon_name() {
            return "input-keyboard";
        }

        public string get_help() {
            return "This dialog allows for viewing desktop keybindings. Initially all keybindings are presented. The user may filter the list in the top text box. The arrow keys may be used to select from the list, and enter or clicking on an item will perform the keybinding action.";
        }

        public char get_keybinding() {
            return 'k';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Invoke Keybinding");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) {
            this.entry = entry;
            this.session_controller = sessionController;
            this.wm_name = wm_name;
            fuzzy_matching = settings.get_boolean("fuzzy-matching");

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (string), typeof (string), typeof (string), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            read_config.begin((obj, res) => {
                read_config.end(res);

                item_view.columns_autosize();
                if (fuzzy_matching)
                    model.set_sort_func(ITEM_VIEW_COLUMN_SUMMARY, summary_sort_func);
                model.set_sort_column_id(1, SortType.ASCENDING);
                // model.set_sort_func (0, app_sort_func);
                set_selection();
            });

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;
        }

        public void show() {
            item_view.grab_focus();
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.get_style_context().add_class("keybindings");

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes(-1, "Keybinding", new CellRendererText(), "text", ITEM_VIEW_COLUMN_KEYBINDING);
            item_view.insert_column_with_attributes(-1, "Action", new CellRendererText(), "text", ITEM_VIEW_COLUMN_SUMMARY);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);

            // Under the X11 input grab the tree view doesn't activate a clicked row itself
            item_view.button_release_event.connect(on_button_released);
        }

        // A click runs the binding of the row under the pointer, whichever row is highlighted
        private bool on_button_released(Gdk.EventButton event) {
            if (event.button != Gdk.BUTTON_PRIMARY ||
                (event.state & (Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.CONTROL_MASK)) != 0)
                return false;

            var bin_window = item_view.get_bin_window();
            if (bin_window == null)
                return false;

            double x = event.x, y = event.y;
            if (event.window != bin_window) {
                int origin_x, origin_y;
                bin_window.get_origin(out origin_x, out origin_y);
                x = event.x_root - origin_x;
                y = event.y_root - origin_y;
            }

            Gtk.TreePath ? clicked = null;
            if (!item_view.get_path_at_pos((int) x, (int) y, out clicked, null, null, null) || clicked == null)
                return false;

            Gtk.TreeIter clicked_iter;
            if (filter.get_iter(out clicked_iter, clicked))
                execute_app_from_selection(clicked_iter);
            return false;
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
            execute_app_from_selection(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            if (fuzzy_matching) // subsequence matches go last: sort again
                model.set_sort_func(ITEM_VIEW_COLUMN_SUMMARY, summary_sort_func);
            filter.refilter();
            set_selection();
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (filter.get_iter(out iter, path))
                execute_app_from_selection(iter);
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            int span;
            return match_row(iter, out span) != MatchKind.NONE;
        }

        // Each word may be found in, or be a subsequence of, the description or the key text
        private MatchKind match_row(Gtk.TreeIter row, out int span) {
            string ? summary, keybinding;
            model.@get(row, ITEM_VIEW_COLUMN_FOLDED_SUMMARY, out summary, ITEM_VIEW_COLUMN_FOLDED_KEYBINDING, out keybinding);
            string ?[] fields = { summary, keybinding };
            return match_words(query.words_for(entry.get_text()), fields, fields, fuzzy_matching, out span);
        }

        // By description, as the default sort does, with the bindings that match only by subsequence last
        private int summary_sort_func(Gtk.TreeModel m, Gtk.TreeIter a, Gtk.TreeIter b) {
            int span_a, span_b;
            var kind_a = match_row(a, out span_a);
            var kind_b = match_row(b, out span_b);
            string ? summary_a, summary_b;
            model.@get(a, ITEM_VIEW_COLUMN_SUMMARY, out summary_a);
            model.@get(b, ITEM_VIEW_COLUMN_SUMMARY, out summary_b);
            return compare_matched_rows(kind_a, span_a, summary_a, kind_b, span_b, summary_b);
        }

        // Read the active configuration and populate the model with keybindings
        private async void read_config() {
            try {
                var ipc_client = new IPCClient(this.wm_name);
                var reply = ipc_client.getConfig();
                // sway hands over its files as written; i3 has already replaced the variables
                bool is_sway = this.wm_name == "sway";
                ConfigParser parser;
                // The same configuration with no resource set, every set_from_resource at its fallback
                ConfigParser unset_parser;
                if (is_sway) {
                    parser = new ConfigParser.from_files(reply.configs, "", true, yield read_trawl_resources());
                    unset_parser = new ConfigParser.from_files(reply.configs, "", true);
                } else {
                    parser = new ConfigParser.from_files(reply.configs, "");
                    unset_parser = new ConfigParser.from_files(reply.unset_resources_configs, "");
                }

                Map<string, ArrayList<Keybinding> > kbmodel = parser.parse();
                Map<string, ArrayList<Keybinding> > unset_model = unset_parser.parse();

                foreach (var entry in kbmodel.entries) {
                    var category = entry.key;
                    var bindings = entry.value;
                    var unset_bindings = unset_model.has_key(category) ? unset_model.get(category) : null;

                    for (int i = 0; i < bindings.size; i++) {
                        var binding = bindings[i];
                        var unset_binding = unset_bindings != null && i < unset_bindings.size ? unset_bindings[i] : null;
                        var formatted_spec = row_keys_label(binding, unset_binding);
                        var summary = category + " - " + binding.label;
                        model.append(out iter);
                        model.set(
                            iter,
                            ITEM_VIEW_COLUMN_KEYBINDING, formatted_spec,
                            ITEM_VIEW_COLUMN_SUMMARY, summary,
                            ITEM_VIEW_COLUMN_EXEC, binding.exec,
                            ITEM_VIEW_COLUMN_FOLDED_KEYBINDING, fold_text(formatted_spec),
                            ITEM_VIEW_COLUMN_FOLDED_SUMMARY, fold_text(summary)
                        );
                    }
                }
            } catch (GLib.Error err) {
                // TODO consistent error handling
                stderr.printf("Failed to read config from %s: %s\n", this.wm_name, err.message);
            }
        }

        /**
         * The resources sway-regolith reads set_from_resource values from: the trawl
         * service on the session bus. Empty when trawl is not running, in which case
         * sway uses each set_from_resource default too.
         */
        private async HashTable<string, string> read_trawl_resources() {
            var resources = new HashTable<string, string> (str_hash, str_equal);
            try {
                var bus = yield Bus.get(BusType.SESSION);
                var reply = yield bus.call(
                    "org.regolith.Trawl", "/org/regolith/Trawl",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "org.regolith.trawl1", "Resources"),
                    new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, 1000, null);
                Variant all;
                reply.get("(v)", out all);
                if (all.is_of_type(new VariantType("a{ss}"))) {
                    var iter = all.iterator();
                    string key;
                    string value;
                    while (iter.next("{ss}", out key, out value))
                        resources.insert(key.strip(), value);
                }
            } catch (GLib.Error err) {
                debug("No trawl resources: %s", err.message);
            }
            return resources;
        }

        /**
         * The key text of a row: the one its comment gives while the row binds the keys it
         * has with no resource set, or binds none at all; otherwise the keys it binds.
         */
        public static string row_keys_label(Keybinding binding, Keybinding ? unset_binding) {
            var active = new ArrayList<BoundKeys> ();
            foreach (var keys in binding.bound_keys) {
                if (keys.active)
                    active.add(keys);
            }

            if (binding.bound_keys.size == 0 ||
                (active.size == binding.bound_keys.size && unset_binding != null && same_keys(binding.bound_keys, unset_binding.bound_keys)))
                return format_spec(binding.spec);
            return format_keys(active);
        }

        // Whether two lists of bindings name the same keys, whatever their spelling
        private static bool same_keys(Gee.List<BoundKeys> a, Gee.List<BoundKeys> b) {
            if (a.size != b.size)
                return false;
            for (int i = 0; i < a.size; i++) {
                if (a[i].is_keycode != b[i].is_keycode || key_identity(a[i].combination) != key_identity(b[i].combination))
                    return false;
            }
            return true;
        }

        // A key combination with its modifier and key names in one spelling: "control+Return" is "ctrl+enter"
        private static string key_identity(string combination) {
            string[] parts = combination.split("+");
            string[] modifiers = shown_modifiers(parts[0: parts.length - 1]);
            string key = format_key(parts[parts.length - 1]);
            return string.joinv("+", modifiers).down() + "+" + key.down();
        }

        // Modifiers as the page shows them, in their order, each once
        private static string[] shown_modifiers(string[] modifiers) {
            string[] shown = {};
            foreach (unowned string modifier in modifiers) {
                string name = format_modifier(modifier);
                if (!(name in shown))
                    shown += name;
            }
            return shown;
        }

        private static string format_modifier(string modifier) {
            switch (modifier.ascii_down()) {
                case "mod4":
                case "super":
                case "logo":
                    return "\uf17a";
                case "mod1":
                case "alt":
                    return "Alt";
                case "control":
                case "ctrl":
                    return "Ctrl";
                case "shift":
                    return "Shift";
                default:
                    return modifier;
            }
        }

        private static string format_key(string key) {
            switch (key.ascii_down()) {
                case "return": return "Enter";
                case "space": return "Space";
                case "left": return "\u2190";
                case "right": return "\u2192";
                case "up": return "\u2191";
                case "down": return "\u2193";
                case "question": return "?";
                case "grave": return "`";
                case "period": return ".";
                case "plus": return "+";
                case "minus": return "-";
                case "backspace": return "Backspace";
            }

            // A keysym that types a character, such as bracketleft or odiaeresis, shows the character
            if (key.length > 1 && !key.has_prefix("KP_")) {
                unichar character = Gdk.keyval_to_unicode(Gdk.keyval_from_name(key));
                if (character.isgraph())
                    return character.to_string();
            }
            return key;
        }

        // The key a bindcode keycode stands for in the first keyboard layout, or the keycode
        private static string format_keycode(string keycode) {
            uint64 code = 0;
            var display = Gdk.Display.get_default();
            if (display == null || !uint64.try_parse(keycode, out code))
                return keycode;

            uint keyval;
            int group, level;
            Gdk.ModifierType consumed;
            var keymap = Gdk.Keymap.get_for_display(display);
            if (keymap.translate_keyboard_state((uint) code, 0, 0, out keyval, out group, out level, out consumed)) {
                string ? name = Gdk.keyval_name(keyval);
                if (name != null)
                    return format_key(name);
            }
            return keycode;
        }

        /**
         * Bindings as the page shows them: "Mod4+Shift+Return" is "\uf17a Shift Enter".
         * Bindings whose modifiers are shown the same, in the same order, show them once,
         * followed by each key; otherwise each binding is shown in full, joined by " or ".
         * Bindings shown the same, such as a keysym and its keycode, are shown once.
         */
        public static string format_keys(Gee.List<BoundKeys> bindings) {
            string[] modifiers = {};  // each binding's modifiers, as shown
            string[] keys = {};       // each binding's key, as shown
            var shown = new HashSet<string> ();
            foreach (var binding in bindings) {
                string[] parts = binding.combination.split("+");
                int last = parts.length - 1;
                string binding_modifiers = string.joinv(" ", shown_modifiers(parts[0: last]));
                string key = binding.is_keycode ? format_keycode(parts[last]) : format_key(parts[last]);
                if (shown.add(binding_modifiers + "\n" + key)) {
                    modifiers += binding_modifiers;
                    keys += key;
                }
            }

            bool shared = true;
            foreach (unowned string binding_modifiers in modifiers)
                shared = shared && binding_modifiers == modifiers[0];

            if (shared) {
                string text = string.joinv(" ", keys);
                return modifiers.length > 0 && modifiers[0] != "" ? modifiers[0] + " " + text : text;
            }

            string[] labels = {};
            for (int i = 0; i < keys.length; i++)
                labels += modifiers[i] != "" ? modifiers[i] + " " + keys[i] : keys[i];
            return string.joinv(" or ", labels);
        }

        public static string format_spec(string raw_keybinding) {
            // TODO: this won't work for keybindings with < > characters
            return raw_keybinding
                    .replace("<", "")
                    .replace(">", " ")
                    .replace("  ", " ");
        }

        // Highlight the first row: the best match for the text typed
        private void set_selection() {
            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            if (path == null)
                path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
        }

        // launch a desktop app
        public void execute_app_from_selection(Gtk.TreeIter selection) {
            string cmd_path;
            filter.@get(selection, ITEM_VIEW_COLUMN_EXEC, out cmd_path);

            if (cmd_path != null) execute_keybinding(cmd_path);
        }

        // Run the binding's command in the window manager, as pressing the key does
        private void execute_keybinding(string exec) {
            // A click can activate the row twice, through the tree view and on release
            if (executed)
                return;
            executed = true;

            try {
                new IPCClient(this.wm_name).runCommand(exec);
            } catch (GLib.Error err) {
                stderr.printf("Error: execute_keybinding failed: %s\n", err.message);
            }
            session_controller.quit();
        }
    }
}
