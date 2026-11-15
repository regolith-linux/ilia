using Gtk;

namespace Ilia {
    /**
     * One row of a quick panel: a name, a detail and a state, in that order, and the key
     * that identifies what the row stands for (a network name, a device address, a profile
     * name), which the highlight follows while the list changes.
     *
     * A status row only reports that something is unavailable: typing never hides it.
     */
    public class PanelRow : GLib.Object {
        public string key { get; private set; }
        public string name { get; private set; }
        public string detail { get; private set; }
        public string state { get; private set; }
        public bool status { get; private set; }

        public PanelRow (string key, string name, string detail = "", string state = "", bool status = false) {
            this.key = key;
            this.name = name;
            this.detail = detail;
            this.state = state;
            this.status = status;
        }

        public PanelRow.status_row (string name, string state = "") {
            this("status:" + name, name, "", state, true);
        }
    }

    /**
     * True when a row named name remains for the filter text query: its name holds every
     * word of the text, ignoring case and accents as on the other pages (see
     * matches_all_words()). An empty text keeps every row.
     */
    public static bool panel_name_matches(string name, string query) {
        return matches_all_words(query, { name });
    }

    /**
     * The text of a failed call, as the panels report it: the message the service sent
     * with its error, or "no reply" when it did not answer in time.
     */
    public static string panel_error_message(GLib.Error err) {
        if (err is IOError.TIMED_OUT || err is DBusError.NO_REPLY || err is DBusError.TIMEOUT || err is DBusError.TIMED_OUT)
            return "no reply";
        DBusError.strip_remote_error(err);
        return err.message;
    }

    /**
     * The common part of the Wi-Fi, Bluetooth and power panels: a list of rows of three
     * cells that the filter text narrows by name, filled from a service on the system bus
     * and read again whenever that service announces a change. Enter runs the page's
     * action on the highlighted row; a failed action is reported on standard error as
     * "ilia: <row name>: <message>", and the list stays as it was.
     *
     * Nothing waits for a service: the window takes keys while the rows are read.
     */
    abstract class QuickPanelPage : DialogPage, GLib.Object {
        protected const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";
        protected const string OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager";
        // How long an action waits for the service's reply
        protected const int ACTION_TIMEOUT_MS = 5000;
        // Reading the state waits as long as the service takes; the list stays empty meanwhile
        protected const int READ_TIMEOUT_MS = int.MAX;
        // A change is announced in several signals (an object, then its properties): read once they are in
        private const uint REFRESH_DELAY_MS = 40;

        private const int ITEM_VIEW_COLUMN_NAME = 0;
        private const int ITEM_VIEW_COLUMN_DETAIL = 1;
        private const int ITEM_VIEW_COLUMN_STATE = 2;
        private const int ITEM_VIEW_COLUMN_KEY = 3;
        private const int ITEM_VIEW_COLUMN_STATUS = 4;

        // The system bus; null until connected, or when it cannot be reached
        protected DBusConnection ? bus = null;
        protected SessionContoller session_controller;
        protected Gtk.Entry entry;

        private Gtk.ListStore model;
        private Gtk.TreeModelFilter filter;
        private Gtk.TreeView item_view;
        private Gtk.Widget root_widget;

        // The row whose password is being typed; null outside the password prompt
        private string ? prompt_key = null;
        // An action is waiting for its reply: Enter does nothing until it has one
        private bool action_running = false;

        private uint refresh_source = 0;
        private bool refreshing = false;
        private bool refresh_again = false;
        private bool left = false;

        /**
         * Connect to the service, follow its signals and read the rows the first time.
         * Called once the system bus is connected, or failed to connect (bus is null then).
         */
        protected abstract async void start();

        /**
         * Read the rows from the service; null when they could not be read, which leaves
         * the list as it is.
         */
        protected abstract async GenericArray<PanelRow> ? read_rows();

        /**
         * Act on the row identified by key, which is highlighted: Enter was pressed.
         */
        protected abstract async void activate(string key);

        /**
         * Enter was pressed in the password prompt for the row identified by key.
         */
        protected virtual async void submit_password(string key, string password) {
        }

        /**
         * The launcher is about to leave: undo what the page started.
         */
        protected virtual void leaving() {
        }

        public abstract string get_name();

        public abstract string get_icon_name();

        public abstract string get_help();

        public abstract char get_keybinding();

        public abstract HashTable<string, string> ? get_keybindings();

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore(5, typeof (string), typeof (string), typeof (string), typeof (string), typeof (bool));
            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(item_view);
            scrolled.expand = true;
            root_widget = scrolled;
            // After an action, after Escape, or when the window is closed
            root_widget.destroy.connect(leave);

            Bus.get.begin(BusType.SYSTEM, null, (obj, res) => {
                try {
                    bus = Bus.get.end(res);
                } catch (GLib.Error err) {
                    bus = null;
                }
                start.begin();
            });
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.headers_visible = false;
            item_view.enable_search = false;
            item_view.get_selection().set_mode(SelectionMode.SINGLE);

            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", ITEM_VIEW_COLUMN_NAME);
            item_view.insert_column_with_attributes(-1, "Detail", new CellRendererText(), "text", ITEM_VIEW_COLUMN_DETAIL);
            item_view.insert_column_with_attributes(-1, "State", new CellRendererText(), "text", ITEM_VIEW_COLUMN_STATE);

            item_view.set_activate_on_single_click(true);
            item_view.row_activated.connect((row_path, column) => {
                Gtk.TreeIter iter;
                if (filter.get_iter(out iter, row_path)) {
                    item_view.set_cursor(row_path, null, false);
                    activate_highlighted();
                }
            });
        }

        // Status rows always remain; in the password prompt only the network's row does
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string key, name;
            bool status;
            m.@get(iter, ITEM_VIEW_COLUMN_KEY, out key, ITEM_VIEW_COLUMN_NAME, out name, ITEM_VIEW_COLUMN_STATUS, out status);

            if (prompt_key != null)
                return key == prompt_key;
            if (status)
                return true;
            return panel_name_matches(name ?? "", entry.get_text());
        }

        public void on_entry_changed() {
            filter.refilter();
            highlight(null);
        }

        public void on_entry_activated() {
            // Enter is taken in key_event()
        }

        public void show() {
            item_view.grab_focus();
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (is_enter_key(event_key.keyval)) {
                activate_highlighted();
                return true;
            }
            return false;
        }

        public bool cancel() {
            if (prompt_key == null)
                return false;
            close_prompt();
            return true;
        }

        // The key of the highlighted row, or null when no row is highlighted
        protected string ? highlighted_key() {
            Gtk.TreeModel m;
            Gtk.TreeIter iter;
            if (!item_view.get_selection().get_selected(out m, out iter))
                return null;
            string key;
            m.@get(iter, ITEM_VIEW_COLUMN_KEY, out key);
            return key;
        }

        // Highlight the row identified by key, or the first row when there is no such row
        private void highlight(string ? key) {
            Gtk.TreeIter iter;
            if (!filter.get_iter_first(out iter))
                return;

            Gtk.TreePath target = new Gtk.TreePath.first();
            if (key != null) {
                do {
                    string row_key;
                    filter.@get(iter, ITEM_VIEW_COLUMN_KEY, out row_key);
                    if (row_key == key) {
                        target = filter.get_path(iter);
                        break;
                    }
                } while (filter.iter_next(ref iter));
            }
            item_view.set_cursor(target, null, false);
        }

        /**
         * Show these rows in place of the current ones; the highlight stays on the row it
         * was on while that row is listed.
         */
        protected void set_rows(GenericArray<PanelRow> rows) {
            string ? highlighted = highlighted_key();

            // Change only the cells that differ: rows that stay the same are left alone, for
            // the accessibility tools reading them meanwhile as much as for the highlight
            Gtk.TreeIter iter;
            bool more = model.get_iter_first(out iter);
            foreach (var row in rows.data) {
                if (!more) {
                    model.append(out iter);
                    model.set(iter,
                              ITEM_VIEW_COLUMN_NAME, row.name,
                              ITEM_VIEW_COLUMN_DETAIL, row.detail,
                              ITEM_VIEW_COLUMN_STATE, row.state,
                              ITEM_VIEW_COLUMN_KEY, row.key,
                              ITEM_VIEW_COLUMN_STATUS, row.status);
                } else {
                    update_row(iter, row);
                    more = model.iter_next(ref iter);
                }
            }
            while (more)
                more = model.remove(ref iter);

            if (highlighted == null || highlighted_key() != highlighted)
                highlight(highlighted);
        }

        private void update_row(Gtk.TreeIter iter, PanelRow row) {
            string name, detail, state, key;
            bool status;
            model.@get(iter,
                       ITEM_VIEW_COLUMN_NAME, out name,
                       ITEM_VIEW_COLUMN_DETAIL, out detail,
                       ITEM_VIEW_COLUMN_STATE, out state,
                       ITEM_VIEW_COLUMN_KEY, out key,
                       ITEM_VIEW_COLUMN_STATUS, out status);
            if (key != row.key)
                model.set(iter, ITEM_VIEW_COLUMN_KEY, row.key);
            if (status != row.status)
                model.set(iter, ITEM_VIEW_COLUMN_STATUS, row.status);
            if (name != row.name)
                model.set(iter, ITEM_VIEW_COLUMN_NAME, row.name);
            if (detail != row.detail)
                model.set(iter, ITEM_VIEW_COLUMN_DETAIL, row.detail);
            if (state != row.state)
                model.set(iter, ITEM_VIEW_COLUMN_STATE, row.state);
        }

        // Show a single status row
        protected void set_status(string name, string state = "") {
            var rows = new GenericArray<PanelRow>();
            rows.add(new PanelRow.status_row(name, state));
            set_rows(rows);
        }

        // Read the rows again soon: the service announced a change
        protected void request_refresh() {
            if (refresh_source != 0 || left)
                return;
            refresh_source = Timeout.add(REFRESH_DELAY_MS, () => {
                refresh_source = 0;
                refresh.begin();
                return Source.REMOVE;
            });
        }

        // Read the rows now; one reading at a time, so that an older one never replaces a newer one
        protected async void refresh() {
            if (refreshing) {
                refresh_again = true;
                return;
            }
            refreshing = true;
            do {
                refresh_again = false;
                var rows = yield read_rows();
                if (rows != null && !left)
                    set_rows(rows);
            } while (refresh_again && !left);
            refreshing = false;
        }

        // Read the rows again whenever the service sends a signal
        protected void follow_service(string bus_name) {
            bus.signal_subscribe(bus_name, null, null, null, null, DBusSignalFlags.NONE,
                                 (connection, sender, path, iface, signal_name, parameters) => request_refresh());
        }

        private void activate_highlighted() {
            if (action_running)
                return;
            string ? key = highlighted_key();
            if (key == null)
                return;

            action_running = true;
            if (prompt_key != null) {
                string password = entry.get_text();
                submit_password.begin(key, password, (obj, res) => {
                    submit_password.end(res);
                    action_running = false;
                });
            } else {
                activate.begin(key, (obj, res) => {
                    activate.end(res);
                    action_running = false;
                });
            }
        }

        /**
         * Ask for the password of the row identified by key: the filter text is cleared, the
         * entry hides what is typed, and only that row is listed.
         */
        protected void open_prompt(string key) {
            prompt_key = key;
            entry.visibility = false;
            entry.input_purpose = InputPurpose.PASSWORD;
            entry.set_text("");
            filter.refilter();
            highlight(key);
            entry.grab_focus_without_selecting();
        }

        // Back from the password prompt to the full list, the row of the prompt highlighted
        protected void close_prompt() {
            string ? key = prompt_key;
            prompt_key = null;
            entry.set_text("");
            entry.visibility = true;
            entry.input_purpose = InputPurpose.FREE_FORM;
            filter.refilter();
            highlight(key);
        }

        // An action succeeded: leave
        protected void finish() {
            session_controller.quit();
        }

        // Say on standard error that the action on the row named row_name failed
        protected void report_failure(string row_name, GLib.Error err) {
            stderr.printf("ilia: %s: %s\n", row_name, panel_error_message(err));
        }

        private void leave() {
            if (left)
                return;
            left = true;
            if (refresh_source != 0) {
                Source.remove(refresh_source);
                refresh_source = 0;
            }
            leaving();
        }

        /**
         * Call a method of a service on the system bus. Reading calls wait as long as the
         * service takes; actions pass ACTION_TIMEOUT_MS.
         */
        protected async Variant call(string bus_name, string path, string iface, string method, Variant ? parameters,
                                     string ? reply_type, int timeout = READ_TIMEOUT_MS) throws GLib.Error {
            if (bus == null)
                throw new IOError.NOT_CONNECTED("The system bus is not connected");
            return yield bus.call(bus_name, path, iface, method, parameters,
                                  reply_type != null ? new VariantType(reply_type) : null,
                                  DBusCallFlags.NO_AUTO_START, timeout, null);
        }

        // Whether bus_name has an owner on the system bus
        protected async bool has_owner(string bus_name) {
            try {
                var reply = yield call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                       "NameHasOwner", new Variant("(s)", bus_name), "(b)");
                return reply.get_child_value(0).get_boolean();
            } catch (GLib.Error err) {
                return false;
            }
        }

        // All the properties of an interface, as a{sv}
        protected async Variant get_all(string bus_name, string path, string iface) throws GLib.Error {
            var reply = yield call(bus_name, path, PROPERTIES_IFACE, "GetAll", new Variant("(s)", iface), "(a{sv})");
            return reply.get_child_value(0);
        }

        // One property of an interface
        protected async Variant read_property(string bus_name, string path, string iface, string name) throws GLib.Error {
            var reply = yield call(bus_name, path, PROPERTIES_IFACE, "Get", new Variant("(ss)", iface, name), "(v)");
            return reply.get_child_value(0).get_variant();
        }

        // Set a property as an action: an error or no reply within five seconds throws
        protected async void write_property(string bus_name, string path, string iface, string name, Variant value) throws GLib.Error {
            yield call(bus_name, path, PROPERTIES_IFACE, "Set", new Variant("(ssv)", iface, name, value), null, ACTION_TIMEOUT_MS);
        }
    }
}
