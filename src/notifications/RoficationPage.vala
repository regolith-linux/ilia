using Gtk;

namespace Ilia {
    // A dialog page that allows management of notifications
    // [{"id": 2, "summary": "Hello! January", "body": "", "application": "notify-send", "icon": "face-wink", "urgency": 1, "actions": [], "hints": {"urgency": 1}}]
    class RoficationPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 6;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_APP = 1;
        private const int ITEM_VIEW_COLUMN_DETAIL = 2;
        private const int ITEM_VIEW_COLUMN_ID = 3;
        private const int ITEM_VIEW_COLUMN_APP_INFO = 4;
        private const int ITEM_VIEW_COLUMN_STATUS = 5;

        // First lines of the row that reports a state; there is at most one, ahead of the notifications
        private const string STATUS_LOADING = "Loading notifications";
        private const string STATUS_LOAD_FAILED = "Could not load notifications";
        private const string STATUS_UNREADABLE = "Some notifications could not be read";
        private const string STATUS_OPEN_FAILED = "Could not open notification";
        private const string STATUS_DELETE_FAILED = "Could not delete notification";
        private const string STATUS_DELETE_ALL_FAILED = "Could not delete notifications";

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;

        private Gtk.Entry entry;

        private SessionContoller session_controller;

        private Gtk.Widget root_widget;

        private RoficationClient rofi_client;

        // The list request in progress, if any; a newer one takes over from it
        private Cancellable ? load_cancellable = null;

        // Whether a load has finished; later loads keep the highlight where the user left it
        private bool first_load_done = false;

        // The pending place_view_later() step, if any; 0 when none
        private uint place_view_source = 0;

        private int post_launch_sleep;

        private int icon_size;

        private Gtk.TreePath path;

        public string get_name() {
            return "<u>N</u>otifications";
        }

        public string get_icon_name() {
            return "mail-message-new";
        }

        public string get_help() {
            return "This dialog manages desktop notifications. Initially all desktop apps are presented. The user may filter the list in the top text box.";
        }

        public char get_keybinding() {
            return 'n';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("del", "Delete Notification");
            keybindings.set("shift del", "Delete All Notifications");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.icon_size = settings.get_int("icon-size");
            this.post_launch_sleep = settings.get_int("post-launch-sleep");
            this.path = new Gtk.TreePath.first();

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (int64), typeof (DesktopAppInfo), typeof (bool));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            rofi_client = new RoficationClient("/tmp/rofi_notification_daemon");

            // The window comes up at once; the notifications follow when the daemon has answered
            show_status(STATUS_LOADING, "Waiting for the notification daemon", false);
            highlight_first_notification();
            load_notifications.begin();

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
            item_view.fixed_height_mode = false;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "App", new CellRendererText(), "text", ITEM_VIEW_COLUMN_APP);
            var wrapping_cell_renderer = new CellRendererText();
            wrapping_cell_renderer.wrap_mode = Pango.WrapMode.WORD;
            wrapping_cell_renderer.wrap_width = 300;
            item_view.insert_column_with_attributes(-1, "Body", wrapping_cell_renderer, "text", ITEM_VIEW_COLUMN_DETAIL);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);

            item_view.get_selection().set_mode(SelectionMode.SINGLE);
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            Gtk.TreeIter iter;
            if (filter.get_iter(out iter, row_path))
                execute_app_from_selection(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            filter.refilter();
            // A new text highlights its first match, wherever the arrow keys left the highlight
            highlight_first_notification();
        }

        // called on enter when in text box
        void on_entry_activated() {
            Gtk.TreeIter iter;
            if (get_highlighted(out iter))
                execute_app_from_selection(iter);
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            // The row that reports a state shows whatever the filter text
            if (is_status_row(m, iter))
                return true;

            string query_string = entry.get_text().down().strip();
            GLib.Value table_info;

            if (query_string.length > 0) {
                model.get_value(iter, ITEM_VIEW_COLUMN_DETAIL, out table_info);
                string body = table_info.get_string();

                model.get_value(iter, ITEM_VIEW_COLUMN_APP, out table_info);
                string app = table_info.get_string();

                return matches_all_words(query_string, { body, app });
            } else {
                return true;
            }
        }

        // Ask the daemon for its list; the rows on show stay until the reply is in or has failed
        private async void load_notifications() {
            if (load_cancellable != null)
                load_cancellable.cancel();
            var cancellable = new Cancellable();
            load_cancellable = cancellable;

            NotificationList ? notifications = null;
            try {
                notifications = yield rofi_client.get_notifications(cancellable);
            } catch (GLib.Error err) {
                if (cancellable.is_cancelled())
                    return; // a newer request took over
                load_cancellable = null;
                stderr.printf("Error: load_notifications failed: %s\n", err.message);
                show_load_error(err);
                return;
            }
            if (cancellable.is_cancelled())
                return;
            load_cancellable = null;

            show_notifications(notifications);
        }

        private void show_notifications(NotificationList notifications) {
            notifications.notifications.sort(compare_notifications_newest_first);
            var icon_theme = Gtk.IconTheme.get_default();

            // What to highlight again once the rows are rebuilt, and where; see restore_highlight()
            bool keep_place = first_load_done;
            first_load_done = true;
            bool notification_highlighted = false;
            int64[] wanted_ids = {};
            int highlight_offset = 0;
            if (keep_place)
                notification_highlighted = note_highlight(out wanted_ids, out highlight_offset);

            model.clear();

            if (notifications.unreadable > 0)
                show_status(STATUS_UNREADABLE, notifications.unreadable == 1
                            ? "1 entry of the list was left out"
                            : "%u entries of the list were left out".printf(notifications.unreadable));

            foreach (var notification in notifications.notifications) {
                // DesktopAppInfo.search() has nothing to look for in empty text
                DesktopAppInfo ? desktopAppInfo = null;
                if (notification.application.length > 0)
                    desktopAppInfo = getDesktopAppInfo(notification.application);
                Gdk.Pixbuf ? iconPixBuff = null;
                if (desktopAppInfo != null)
                    iconPixBuff = Ilia.load_icon_from_info(icon_theme, desktopAppInfo, icon_size);
                else
                    iconPixBuff = Ilia.load_icon_from_name(icon_theme, notification.icon, icon_size);

                string detail;
                if (notification.summary.length > 0 && notification.body.length > 0)
                    detail = notification.summary + "\n" + notification.body;
                else if (notification.summary.length == 0 && notification.body.length > 0)
                    detail = notification.body;
                else if (notification.summary.length > 0 && notification.body.length == 0)
                    detail = notification.summary;
                else
                    detail = "<no content>";

                Gtk.TreeIter iter;
                model.insert_with_values(
                    out iter, -1,
                    ITEM_VIEW_COLUMN_ICON, iconPixBuff,
                    ITEM_VIEW_COLUMN_APP, notification.application,
                    ITEM_VIEW_COLUMN_DETAIL, detail,
                    ITEM_VIEW_COLUMN_ID, notification.id,
                    ITEM_VIEW_COLUMN_APP_INFO, desktopAppInfo,
                    ITEM_VIEW_COLUMN_STATUS, false
                );
            }

            // The new highlight takes the place of the old one; otherwise the list shows its top
            if (notification_highlighted) {
                restore_highlight(wanted_ids);
                place_view_later(highlight_offset);
            } else {
                highlight_first_notification();
                place_view_later(null);
            }
        }

        /*
         * Before the rows of a later load replace the ones on show: the usable ids of the
         * highlighted notification and of the notifications on show after it, in display order,
         * and how far below the top of the visible part the highlighted row starts.
         * A highlighted row without a usable id is left out, as it can never be found again.
         * Returns false when the status row or no row holds the highlight.
         */
        private bool note_highlight(out int64[] ids, out int offset) {
            ids = {};
            offset = 0;
            Gtk.TreeIter iter;
            if (!get_highlighted(out iter) || is_status_row(filter, iter))
                return false;

            offset = row_offset(filter.get_path(iter));
            int64[] found = {};
            do {
                int64 id;
                filter.@get(iter, ITEM_VIEW_COLUMN_ID, out id);
                if (id > 0)
                    found += id;
            } while (filter.iter_next(ref iter));
            ids = found;
            return true;
        }

        /*
         * Highlight the first of ids whose notification is on show among the rows just loaded,
         * or else the last row on show: the last notification, or the status row without one.
         */
        private void restore_highlight(int64[] ids) {
            foreach (int64 wanted in ids) {
                Gtk.TreeIter iter;
                for (bool more = filter.get_iter_first(out iter); more; more = filter.iter_next(ref iter)) {
                    int64 id;
                    bool is_status;
                    filter.@get(iter, ITEM_VIEW_COLUMN_ID, out id, ITEM_VIEW_COLUMN_STATUS, out is_status);
                    if (!is_status && id == wanted) {
                        highlight_path(filter.get_path(iter));
                        return;
                    }
                }
            }

            highlight_row_at(int.MAX);
        }

        // Highlight the row at index among those on show, or the last one when there are fewer
        private void highlight_row_at(int index) {
            int rows = filter.iter_n_children(null);
            if (rows > 0)
                highlight_path(new Gtk.TreePath.from_indices(int.min(index, rows - 1)));
        }

        private void highlight_path(Gtk.TreePath target) {
            move_path_to(path, target);
            item_view.set_cursor(target, null, false); // also selects the row and scrolls to it
        }

        // How far the top edge of the row starts below the top of the visible part of the list
        private int row_offset(Gtk.TreePath row) {
            Gdk.Rectangle area;
            item_view.get_background_area(row, null, out area); // in bin window coordinates
            return area.y;
        }

        /*
         * Scroll the list so that the highlighted row starts offset pixels below the top of its
         * visible part, as far as the ends of the list allow, or to the top of the list when
         * offset is null or the status row holds the highlight. This waits for the rows just put
         * in place: GTK lays them out, and does the scrolling set_cursor() asked for, in idle
         * handlers of its own that run ahead of Priority.LOW.
         */
        private void place_view_later(int ? offset) {
            if (place_view_source != 0)
                Source.remove(place_view_source);

            place_view_source = Idle.add(() => {
                place_view_source = 0;
                var adjustment = ((Gtk.Scrollable) item_view).get_vadjustment();
                Gtk.TreeIter iter;
                bool highlighted = get_highlighted(out iter);
                if (offset == null || !highlighted || is_status_row(filter, iter)) {
                    adjustment.value = adjustment.lower;
                } else {
                    int tree_x, tree_y;
                    item_view.convert_bin_window_to_tree_coords(0, row_offset(filter.get_path(iter)), out tree_x, out tree_y);
                    adjustment.value = tree_y - offset; // the adjustment keeps it within the ends
                }
                return Source.REMOVE;
            }, Priority.LOW);
        }

        // Take a notification row out of the list at once, ahead of the daemon's next list
        private void remove_row(Gtk.TreeIter filter_iter) {
            Gtk.TreeIter child;
            filter.convert_iter_to_child_iter(out child, filter_iter);
            model.remove(ref child);
        }

        // Say in the list why it is empty; the row is no notification, so Delete ignores it
        private void show_load_error(GLib.Error err) {
            first_load_done = true;
            model.clear();
            show_status(STATUS_LOAD_FAILED, err.message);
            highlight_first_notification();
        }

        /*
         * Report a state in the row ahead of the notifications, in place of what it reported
         * before. The notification rows and the highlight stay as they are.
         */
        private void show_status(string title, string detail, bool with_picture = true) {
            string text = title + "\n" + (detail.strip().length > 0 ? detail : "No reason given");
            Gdk.Pixbuf ? picture = null;
            if (with_picture)
                picture = Ilia.load_icon_from_name(Gtk.IconTheme.get_default(), "dialog-error", icon_size);

            Gtk.TreeIter iter;
            if (model.get_iter_first(out iter) && is_status_row(model, iter))
                model.set(iter, ITEM_VIEW_COLUMN_ICON, picture, ITEM_VIEW_COLUMN_DETAIL, text);
            else
                model.insert_with_values(
                    out iter, 0,
                    ITEM_VIEW_COLUMN_ICON, picture,
                    ITEM_VIEW_COLUMN_APP, "",
                    ITEM_VIEW_COLUMN_DETAIL, text,
                    ITEM_VIEW_COLUMN_ID, (int64) 0,
                    ITEM_VIEW_COLUMN_STATUS, true
                );
        }

        private static bool is_status_row(Gtk.TreeModel m, Gtk.TreeIter iter) {
            bool is_status;
            m.@get(iter, ITEM_VIEW_COLUMN_STATUS, out is_status);
            return is_status;
        }

        private DesktopAppInfo ? getDesktopAppInfo(string appName) {
            string * *[] desktopApps = GLib.DesktopAppInfo.search(appName);

            if (desktopApps.length < 1) return null;

            // Take top search result
            return new DesktopAppInfo(*desktopApps[0]);
        }

        // Highlight the first notification on show, or else the row that reports a state
        private void highlight_first_notification() {
            Gtk.TreeIter iter;
            if (!filter.get_iter_first(out iter))
                return;
            Gtk.TreeIter next = iter;
            if (is_status_row(filter, iter) && filter.iter_next(ref next))
                iter = next;

            highlight_path(filter.get_path(iter));
        }

        private bool get_highlighted(out Gtk.TreeIter iter) {
            Gtk.TreeModel selected_model;
            return item_view.get_selection().get_selected(out selected_model, out iter);
        }

        public void show() {
            item_view.grab_focus();
        }

        public bool key_event(Gdk.EventKey event) {
            if (handle_emacs_vim_nav(item_view, path, event))
                return true;

            if (event.keyval == 65535) {
                if ((event.state & Gdk.ModifierType.SHIFT_MASK) == Gdk.ModifierType.SHIFT_MASK)
                    delete_all_notifications();
                else
                    delete_selected_notification();
                return true;
            }

            return false;
        }

        private void delete_selected_notification() {
            Gtk.TreeIter iter;
            if (!get_highlighted(out iter))
                return;

            int64 id;
            bool is_status;
            filter.@get(iter, ITEM_VIEW_COLUMN_ID, out id, ITEM_VIEW_COLUMN_STATUS, out is_status);
            // A row that reports a state, or a notification without a usable id, names nothing to delete
            if (is_status || id <= 0)
                return;

            try {
                rofi_client.delete_notification_by_id(id);
            } catch (GLib.Error err) {
                stderr.printf("Error: delete_selected_notification failed: %s\n", err.message);
                show_status(STATUS_DELETE_FAILED, err.message);
                return;
            }

            /*
             * The row leaves at once and the highlight takes its place: the notification on show
             * below it, else the new last one, else the status row. The next Delete then acts on
             * that one even while the new list is on its way.
             */
            int index = filter.get_path(iter).get_indices()[0];
            remove_row(iter);
            highlight_row_at(index);

            load_notifications.begin();
        }

        // Delete the notifications on show that have a usable id, in the order shown
        private void delete_all_notifications() {
            Gtk.TreeIter iter;
            if (get_highlighted(out iter) && is_status_row(filter, iter))
                return;

            string[] ids = {};
            Gtk.TreeRowReference[] rows = {};
            for (bool next = filter.get_iter_first(out iter); next; next = filter.iter_next(ref iter)) {
                int64 id;
                bool is_status;
                filter.@get(iter, ITEM_VIEW_COLUMN_ID, out id, ITEM_VIEW_COLUMN_STATUS, out is_status);

                if (!is_status && id > 0) {
                    ids += id.to_string();
                    rows += new Gtk.TreeRowReference(filter, filter.get_path(iter));
                }
            }

            if (ids.length == 0)
                return;

            try {
                rofi_client.delete_notifications_by_ids(ids);
            } catch (GLib.Error err) {
                stderr.printf("Error: delete_func failed: %s\n", err.message);
                show_status(STATUS_DELETE_ALL_FAILED, err.message);
                return;
            }

            // The rows named leave at once; rows without a usable id and the status row stay
            foreach (var row in rows) {
                if (row.valid() && filter.get_iter(out iter, row.get_path()))
                    remove_row(iter);
            }
            highlight_first_notification();
            place_view_later(null);

            load_notifications.begin();
        }

        // launch a desktop app; on failure say so in the list and stay open
        public void execute_app_from_selection(Gtk.TreeIter selection) {
            DesktopAppInfo ? app_info;
            string ? application;
            bool is_status;
            filter.@get(selection, ITEM_VIEW_COLUMN_APP_INFO, out app_info, ITEM_VIEW_COLUMN_APP, out application, ITEM_VIEW_COLUMN_STATUS, out is_status);

            if (is_status)
                return;

            if (app_info == null) {
                if (application != null && application.length > 0)
                    show_status(STATUS_OPEN_FAILED, application);
                else
                    show_status(STATUS_OPEN_FAILED, "The notification names no application");
                return;
            }

            try {
                if (!app_info.launch_uris(null, null))
                    throw new IOError.FAILED("%s did not start", app_info.get_display_name());

                GLib.Thread.usleep(post_launch_sleep);
                session_controller.quit();
            } catch (GLib.Error e) {
                stderr.printf("%s\n", e.message);
                show_status(STATUS_OPEN_FAILED, e.message);
            }
        }
    }
}
