using Gtk;

namespace Ilia {
    /**
     * A page from a file whose rows are a menu (the Entries key): submenus, bindings of the
     * window manager, and commands
     *
     * When the page is first shown (with -a, once it is visited), binding rows are matched
     * with the bindings the keybindings page lists, before the rows are listed, and the When
     * and State commands of all entries start together, without a shell, with stdin from
     * /dev/null; they are stopped after two seconds. Rows wait for their condition without
     * holding the window back; rows that appear later leave the highlight where it is.
     *
     * With an empty filter the rows of the open submenu are listed; BackSpace and Alt+Left go
     * up a level. Once a filter is typed, the rows anywhere below the open submenu whose path
     * holds every word are listed, compared as on the other pages (see fold_text()).
     */
    class PageFileMenuPage : PageFilePage {
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_KEYS = 2;
        private const int ITEM_VIEW_COLUMN_STATE = 3;

        // Shown after the name of a row that opens a submenu, and between the names of a path
        public const string SUBMENU_MARK = "›";
        public const string PATH_SEPARATOR = " › ";

        // How long a When or State command may run
        private const uint COMMAND_TIMEOUT_MS = 2000;

        private Gtk.TreeView item_view;
        private Gtk.ListStore model;
        private Gtk.TreePath path;
        private Gtk.Widget root_widget;
        private Gtk.Entry entry;
        private SessionContoller session_controller;
        private string wm_name;
        private int icon_size;
        private HashTable<string, Gdk.Pixbuf ?> icons;

        // The top level: an item without an entry
        private MenuRow root;
        // The submenus opened, from the top level down; the last is listed
        private MenuRow[] open_menus = {};
        // The submenus a link on the command line opens, from the top level down; null for none
        private MenuEntry[] ? start_path;
        // The listed rows, in the order of the model
        private MenuRow[] listed = {};

        // Bindings were matched and the When and State commands started: the page was shown
        private bool started = false;
        // The bindings were matched: some entry has a Binding
        private bool has_bindings = false;
        // When and State commands still running
        private GenericArray<EntryCommand> commands = new GenericArray<EntryCommand> ();
        // A row was chosen, or the view is gone: nothing more is done
        private bool closed = false;
        // The row a primary button press went down on, until its release; a release acts only on that row
        private MenuRow ? pressed = null;

        /**
         * @param start_path The submenus to open first, from the top level down (see PageFile.find_menu())
         */
        public PageFileMenuPage (PageFile file, char keybinding, MenuEntry[] ? start_path = null) {
            base(file, keybinding);
            this.start_path = start_path;
        }

        public override string get_help() {
            return "This page lists the menu given by the page file %s. Choosing a row opens its submenu, runs its keybinding or runs its command. Typing searches every level below the one shown.".printf(file.path);
        }

        public override HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Open Submenu or Run");
            keybindings.set("backspace", "Up a Level");
            keybindings.set("alt+left", "Up a Level");

            return keybindings;
        }

        public override void show() {
            start();
            item_view.grab_focus();
        }

        public override Gtk.Widget get_root() {
            return root_widget;
        }

        public override async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.wm_name = wm_name;
            icon_size = settings.get_int("icon-size");
            icons = new HashTable<string, Gdk.Pixbuf ?>(str_hash, str_equal);

            root = new MenuRow(null, null);
            add_items(root, file.entries);

            // The submenus a link names exist: PageFile.find_menu() found them
            if (start_path != null) {
                var parent = root;
                foreach (var menu_entry in start_path) {
                    foreach (var child in parent.children) {
                        if (child.entry == menu_entry) {
                            parent = child;
                            break;
                        }
                    }
                    open_menus += parent;
                }
            }

            model = new Gtk.ListStore(4, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (string));
            create_item_view();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;
            root_widget = scrolled;

            refresh(false);
        }

        // Rows for entries and, depth first, their submenus
        private void add_items(MenuRow parent, MenuEntry[] entries) {
            foreach (var menu_entry in entries) {
                var item = new MenuRow(menu_entry, parent);
                item.allowed = menu_entry.is_shown_under(wm_name);
                parent.children += item;
                if (menu_entry.kind == MenuEntryKind.BINDING)
                    has_bindings = true;
                add_items(item, menu_entry.children);
            }
        }

        /**
         * Match the binding rows and start the When and State commands, the first time the
         * page is shown; with -a, a menu page that is never visited runs nothing
         *
         * The bindings are read before the rows are listed again, so that binding rows are
         * there when the page is first displayed, and Enter never lands on a row that moves.
         */
        private void start() {
            if (started || closed)
                return;
            started = true;

            if (has_bindings && (wm_name == "i3" || wm_name == "sway")) {
                read_bindings();
                // Not yet displayed: the first row is highlighted, binding rows included
                refresh(false);
            }
            start_commands(root);
        }

        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(model);
            item_view.get_style_context().add_class("item_view");
            item_view.headers_visible = false;
            item_view.enable_search = false;

            if (icon_size > 0)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ITEM_VIEW_COLUMN_NAME);
            item_view.get_column(icon_size > 0 ? 1 : 0).expand = true;
            item_view.insert_column_with_attributes(-1, "Keys", new CellRendererText(), "text", ITEM_VIEW_COLUMN_KEYS);
            item_view.insert_column_with_attributes(-1, "State", new CellRendererText(), "text", ITEM_VIEW_COLUMN_STATE);

            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            path = new Gtk.TreePath.first();

            // A click opens or runs the row under the pointer; under the X11 input grab the
            // tree view does not activate a clicked row itself
            item_view.button_press_event.connect(on_button_pressed);
            item_view.button_release_event.connect(on_button_released);

            // The commands may still run when the window closes: leave the view alone, and stop them
            item_view.destroy.connect(() => {
                closed = true;
                stop_commands();
            });
        }

        // --------------------------------------------------------------- the rows

        // The submenu listed: the last one opened, or the top level
        private MenuRow current_menu() {
            return open_menus.length > 0 ? open_menus[open_menus.length - 1] : root;
        }

        /**
         * List the rows again, for the filter text and the submenu open
         *
         * @param keep_selection Keep the highlighted row highlighted, as when rows appear; else
         * highlight the first row
         * @param select A row to highlight instead, if it is listed
         */
        private void refresh(bool keep_selection, MenuRow ? select = null) {
            if (closed)
                return;

            MenuRow ? highlighted = select;
            if (highlighted == null && keep_selection)
                highlighted = selected_item();
            // The rows move: a release no longer acts on the row pressed
            pressed = null;

            string[] words = query_words(entry.get_text());
            var rows = new GenericArray<MenuRow> ();
            var labels = new GenericArray<string> ();
            if (words.length == 0) {
                foreach (var child in current_menu().children) {
                    if (child.is_visible()) {
                        rows.add(child);
                        labels.add(child.entry.name);
                    }
                }
            } else {
                collect_matches(current_menu(), "", words, rows, labels);
            }

            item_view.set_model(null);
            model.clear();
            for (int i = 0; i < rows.length; ++i) {
                Gtk.TreeIter iter;
                model.append(out iter);
                model.set(
                    iter,
                    ITEM_VIEW_COLUMN_ICON, row_icon(rows[i].entry),
                    ITEM_VIEW_COLUMN_NAME, labels[i],
                    ITEM_VIEW_COLUMN_KEYS, rows[i].keys_text(),
                    ITEM_VIEW_COLUMN_STATE, rows[i].state ?? ""
                );
            }
            listed = rows.data;
            item_view.set_model(model);

            int position = -1;
            for (int i = 0; highlighted != null && i < listed.length; ++i) {
                if (listed[i] == highlighted)
                    position = i;
            }
            if (position < 0) {
                select_first_row(item_view, path);
            } else {
                move_path_to(path, new Gtk.TreePath.from_indices(position));
                item_view.set_cursor(path, null, false);
            }
        }

        // The visible rows below menu whose path, from menu down, holds every word; depth first, in the listed order
        private void collect_matches(MenuRow menu, string prefix, string[] words, GenericArray<MenuRow> rows, GenericArray<string> labels) {
            foreach (var child in menu.children) {
                if (!child.is_visible())
                    continue;
                string label = prefix == "" ? child.entry.name : prefix + PATH_SEPARATOR + child.entry.name;
                if (contains_all_words(fold_text(label), words)) {
                    rows.add(child);
                    labels.add(label);
                }
                if (child.entry.kind == MenuEntryKind.SUBMENU)
                    collect_matches(child, label, words, rows, labels);
            }
        }

        private Gdk.Pixbuf ? row_icon(MenuEntry menu_entry) {
            if (icon_size <= 0)
                return null;
            string name = menu_entry.icon ?? file.icon;
            if (!icons.contains(name))
                icons.insert(name, Ilia.load_icon_from_name(Gtk.IconTheme.get_default(), name, icon_size));
            return icons.get(name);
        }

        // The highlighted row, or null
        private MenuRow ? selected_item() {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter iter;
            if (!item_view.get_selection().get_selected(out selected_model, out iter))
                return null;
            int index = selected_model.get_path(iter).get_indices()[0];
            return index < listed.length ? listed[index] : null;
        }

        // Show the On/Off text of a row that is listed, in place
        private void update_state(MenuRow item) {
            if (closed)
                return;
            for (int i = 0; i < listed.length; ++i) {
                if (listed[i] != item)
                    continue;
                Gtk.TreeIter iter;
                if (model.iter_nth_child(out iter, null, i))
                    model.set(iter, ITEM_VIEW_COLUMN_STATE, item.state ?? "");
            }
        }

        // --------------------------------------------------------------- moving and choosing

        private void open_submenu(MenuRow item) {
            MenuRow[] menus = {};
            for (var menu = item; menu != root; menu = menu.parent)
                menus += menu;
            open_menus = {};
            for (int i = menus.length - 1; i >= 0; --i)
                open_menus += menus[i];

            // Clearing the filter lists the submenu; it may already be clear
            entry.set_text("");
            refresh(false);
        }

        // Back to the submenu above, highlighting the row of the one that was open
        private void go_up() {
            var left = open_menus[open_menus.length - 1];
            MenuRow[] above = {};
            for (int i = 0; i < open_menus.length - 1; ++i)
                above += open_menus[i];
            open_menus = above;
            refresh(false, left);
        }

        private void choose(MenuRow item) {
            if (closed)
                return;

            switch (item.entry.kind) {
                case MenuEntryKind.SUBMENU:
                    open_submenu(item);
                    break;
                case MenuEntryKind.BINDING:
                    closed = true;
                    try {
                        new IPCClient(wm_name).runCommand(item.binding.exec);
                    } catch (GLib.Error e) {
                        stderr.printf("ilia: page file '%s': cannot run the binding of entry '%s': %s\n", file.path, item.entry.id, e.message);
                    }
                    session_controller.quit();
                    break;
                case MenuEntryKind.EXEC:
                    closed = true;
                    string[] argv = get_scope_argv(file.id, item.entry.exec_argv);
                    try {
                        Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
                    } catch (SpawnError e) {
                        stderr.printf("ilia: page file '%s': cannot run the Exec of entry '%s': %s\n", file.path, item.entry.id, e.message);
                    }
                    session_controller.quit();
                    break;
            }
        }

        public override bool key_event(Gdk.EventKey event_key) {
            if (handle_emacs_vim_nav(item_view, path, event_key))
                return true;

            if (is_enter_key(event_key.keyval)) {
                // No row matches: Enter does nothing
                var item = selected_item();
                if (item != null)
                    choose(item);
                return true;
            }

            bool alt = (event_key.state & Gdk.ModifierType.MOD1_MASK) != 0;
            if (event_key.keyval == Gdk.Key.BackSpace || (alt && event_key.keyval == Gdk.Key.Left)) {
                // With a filter, BackSpace edits it
                if (entry.get_text() != "")
                    return false;
                // At the top level there is nowhere to go
                if (open_menus.length > 0)
                    go_up();
                return true;
            }

            return false;
        }

        public override void on_entry_changed() {
            refresh(false);
        }

        public override void on_entry_activated() {
            var item = selected_item();
            if (item != null)
                choose(item);
        }

        /*
         * A click opens or runs the row under the pointer: the row the primary button went down
         * on, if it is still under the pointer and in the same place when the button comes up.
         * A double click is two clicks, the second on whatever the first one listed: only the
         * first counts. A release without a press, as when the click that opened ilia ends
         * over it, does nothing.
         */
        private bool on_button_pressed(Gdk.EventButton event) {
            pressed = null;
            if (event.type == Gdk.EventType.BUTTON_PRESS && is_plain_primary(event))
                pressed = row_at(event);
            return false;
        }

        private bool on_button_released(Gdk.EventButton event) {
            var item = pressed;
            pressed = null;
            if (item == null || !is_plain_primary(event) || row_at(event) != item)
                return false;

            choose(item);
            return true;
        }

        private static bool is_plain_primary(Gdk.EventButton event) {
            return event.button == Gdk.BUTTON_PRIMARY &&
                   (event.state & (Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.CONTROL_MASK)) == 0;
        }

        // The listed row under the pointer, or null
        private MenuRow ? row_at(Gdk.EventButton event) {
            var bin_window = item_view.get_bin_window();
            if (bin_window == null)
                return null;

            double x = event.x, y = event.y;
            if (event.window != bin_window) {
                int origin_x, origin_y;
                bin_window.get_origin(out origin_x, out origin_y);
                x = event.x_root - origin_x;
                y = event.y_root - origin_y;
            }

            Gtk.TreePath ? clicked = null;
            if (!item_view.get_path_at_pos((int) x, (int) y, out clicked, null, null, null) || clicked == null)
                return null;

            int index = clicked.get_indices()[0];
            return index < listed.length ? listed[index] : null;
        }

        // --------------------------------------------------------------- bindings and commands

        // Match the binding rows with the window manager's bindings, as the keybindings page lists them
        private void read_bindings() {
            try {
                var resources = wm_name == "sway" ? KeybingingsPage.read_trawl_resources_sync() : null;
                match_bindings(root, KeybingingsPage.read_binding_rows(wm_name, resources));
            } catch (GLib.Error e) {
                // The binding rows stay hidden
                debug("No bindings for the menu of %s: %s", file.path, e.message);
            }
        }

        private void match_bindings(MenuRow menu, KeybindingRow[] rows) {
            foreach (var child in menu.children) {
                if (child.entry.kind == MenuEntryKind.BINDING) {
                    string wanted = child.entry.binding;
                    // A description with no binding line after it has no command to run
                    child.binding = KeybingingsPage.first_listed(rows, (row) => {
                        return row.exec != null && MenuEntry.binding_matches(wanted, row.category, row.label);
                    });
                }
                match_bindings(child, rows);
            }
        }

        // Start the When and State commands of the entries below menu
        private void start_commands(MenuRow menu) {
            foreach (var child in menu.children) {
                if (child.entry.has_condition)
                    start_condition(child);
                if (child.entry.state_argv != null)
                    start_state(child);
                start_commands(child);
            }
        }

        // The row is shown once the command exits with status 0
        private void start_condition(MenuRow item) {
            if (item.entry.when_argv == null) {
                item.condition = MenuCondition.FAILED;
                return;
            }
            var command = start_command(item.entry.when_argv, SubprocessFlags.STDOUT_SILENCE);
            if (command == null) {
                item.condition = MenuCondition.FAILED;
                return;
            }
            command.process.wait_async.begin(null, (obj, res) => {
                try {
                    command.process.wait_async.end(res);
                } catch (GLib.Error e) {
                    debug("When of %s: %s", item.entry.id, e.message);
                }
                finish_command(command);
                var process = command.process;
                bool succeeded = !command.stopped && process.get_if_exited() && process.get_exit_status() == 0;
                item.condition = succeeded ? MenuCondition.SUCCEEDED : MenuCondition.FAILED;
                if (succeeded)
                    refresh(true);
            });
        }

        // The first line the command prints decides the row's On/Off text
        private void start_state(MenuRow item) {
            var command = start_command(item.entry.state_argv, SubprocessFlags.STDOUT_PIPE);
            if (command == null)
                return;
            var output = new DataInputStream(command.process.get_stdout_pipe());
            output.read_line_async.begin(Priority.DEFAULT, null, (obj, res) => {
                string ? line = null;
                try {
                    line = output.read_line_async.end(res);
                } catch (GLib.Error e) {
                    debug("State of %s: %s", item.entry.id, e.message);
                }
                // Output cut short by the deadline does not count
                if (command.stopped)
                    return;
                item.state = MenuEntry.state_text(line);
                if (item.state != null)
                    update_state(item);
            });
            command.process.wait_async.begin(null, (obj, res) => {
                try {
                    command.process.wait_async.end(res);
                } catch (GLib.Error e) {
                    debug("State of %s: %s", item.entry.id, e.message);
                }
                finish_command(command);
            });
        }

        // Run a command directly, in a process group of its own, stdin from /dev/null; stop it after the deadline
        private EntryCommand ? start_command(string[] argv, SubprocessFlags flags) {
            Subprocess process;
            try {
                var launcher = new SubprocessLauncher(flags);
                // A process group of its own, so that stopping the command also stops what it started
                launcher.set_child_setup(() => {
                    Posix.setpgid(0, 0);
                });
                process = launcher.spawnv(argv);
            } catch (GLib.Error e) {
                debug("Cannot run %s: %s", argv[0], e.message);
                return null;
            }

            var command = new EntryCommand(process);
            commands.add(command);
            command.timeout_id = Timeout.add(COMMAND_TIMEOUT_MS, () => {
                command.timeout_id = 0;
                command.stop();
                return Source.REMOVE;
            });
            return command;
        }

        private void finish_command(EntryCommand command) {
            if (command.timeout_id != 0) {
                Source.remove(command.timeout_id);
                command.timeout_id = 0;
            }
            command.pid = 0;
            commands.remove(command);
        }

        private void stop_commands() {
            foreach (var command in commands.data) {
                if (command.timeout_id != 0) {
                    Source.remove(command.timeout_id);
                    command.timeout_id = 0;
                }
                command.stop();
            }
        }
    }

    // What the When command of a row has decided so far
    enum MenuCondition {
        // There is no When, or it has not finished
        NONE,
        SUCCEEDED,
        FAILED
    }

    /**
     * A row of a menu page during one run: its entry, and what its commands and the window
     * manager have told about it
     */
    class MenuRow : GLib.Object {
        // Null for the top level
        public MenuEntry ? entry;
        public weak MenuRow ? parent;
        public MenuRow[] children = {};
        // OnlyShowIn and NotShowIn allow the row under this window manager
        public bool allowed = true;
        public MenuCondition condition = MenuCondition.NONE;
        // "On" or "Off", or null
        public string ? state = null;
        // BINDING: the binding the description names, or null
        public KeybindingRow ? binding = null;

        public MenuRow (MenuEntry ? entry, MenuRow ? parent) {
            this.entry = entry;
            this.parent = parent;
        }

        /**
         * True if the row is shown: allowed under the window manager, its condition (if any)
         * succeeded, its binding found, and for a submenu, some row below it shown
         */
        public bool is_visible() {
            if (!allowed)
                return false;
            if (entry.has_condition && condition != MenuCondition.SUCCEEDED)
                return false;
            switch (entry.kind) {
                case MenuEntryKind.BINDING:
                    return binding != null;
                case MenuEntryKind.SUBMENU:
                    foreach (var child in children) {
                        if (child.is_visible())
                            return true;
                    }
                    return false;
                default:
                    return true;
            }
        }

        // The second column: the submenu mark, or the binding's key text
        public string keys_text() {
            switch (entry.kind) {
                case MenuEntryKind.SUBMENU:
                    return PageFileMenuPage.SUBMENU_MARK;
                case MenuEntryKind.BINDING:
                    return binding != null ? binding.keys : "";
                default:
                    return "";
            }
        }
    }

    /**
     * A When or State command while it may run
     */
    class EntryCommand : GLib.Object {
        public Subprocess process;
        // The process group the command leads; 0 once it has finished
        public int pid = 0;
        // Stopped at the deadline, or when the page went away
        public bool stopped = false;
        public uint timeout_id = 0;

        public EntryCommand (Subprocess process) {
            this.process = process;
            unowned string ? identifier = process.get_identifier();
            if (identifier != null)
                pid = int.parse(identifier);
        }

        public void stop() {
            if (pid == 0)
                return;
            stopped = true;
            // Also what the command started, which may outlive it
            Posix.kill((Posix.pid_t) (-pid), Posix.Signal.KILL);
            process.force_exit();
            pid = 0;
        }
    }
}
