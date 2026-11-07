using Gtk;

namespace Ilia {
    // draws a notification's text with its action shortcuts below it in a right
    // aligned and wrapped manner
    class NotificationCellRenderer : Gtk.CellRenderer {
        public string? text { get; set; }
        public string? hints { get; set; }
        public int wrap_width { get; set; default = 300; }
        private const int NATURAL_WIDTH = 300;

        private Pango.Layout body_layout(Gtk.Widget widget, int wrap) {
            var layout = widget.create_pango_layout(text ?? "");
            layout.set_width(int.max(wrap, 1) * Pango.SCALE);
            layout.set_wrap(Pango.WrapMode.WORD_CHAR);
            return layout;
        }

        private Pango.Layout ? shortcut_layout(Gtk.Widget widget, int wrap) {
            if (hints == null || hints.length == 0)
                return null;
            var layout = widget.create_pango_layout(hints);
            layout.set_width(int.max(wrap, 1) * Pango.SCALE);
            layout.set_wrap(Pango.WrapMode.WORD_CHAR);
            layout.set_alignment(Pango.Alignment.RIGHT);
            return layout;
        }

        public override void get_size (Gtk.Widget widget, Gdk.Rectangle? cell_area,
                                       out int x_offset, out int y_offset,
                                       out int width, out int height) {
            int wrapped = wrap_width;
            if (cell_area != null)
                wrapped = cell_area.width;

            int text_width, text_height;
            body_layout(widget, wrapped).get_pixel_size(out text_width, out text_height);

            var shortcuts = shortcut_layout(widget, wrapped);
            int hints_width, hints_height = 0;
            if (shortcuts != null)
                shortcuts.get_pixel_size(out hints_width, out hints_height);

            width = NATURAL_WIDTH;
            height = text_height + (hints_height > 0 ? hints_height + 4 : 0);
            x_offset = 0;
            y_offset = 0;
            if (cell_area != null)
                y_offset = int.max (0, (cell_area.height - height) / 2);
        }

        public override void render (Cairo.Context cr, Gtk.Widget widget,
                                     Gdk.Rectangle background_area, Gdk.Rectangle cell_area,
                                     Gtk.CellRendererState flags) {
            var style = widget.get_style_context ();
            var state = Gtk.StateFlags.NORMAL;
            if ((flags & Gtk.CellRendererState.SELECTED) != 0)
                state |= Gtk.StateFlags.SELECTED;

            int x = cell_area.x;
            int available = cell_area.width;

            var body = body_layout(widget, available);
            int body_width, body_height;
            body.get_pixel_size(out body_width, out body_height);

            var shortcuts = shortcut_layout(widget, available);
            int shortcut_width, shortcut_height = 0;
            if (shortcuts != null)
                shortcuts.get_pixel_size(out shortcut_width, out shortcut_height);

            int block_height = body_height + (shortcut_height > 0 ? shortcut_height + 4 : 0);
            int y = cell_area.y + int.max(0, (cell_area.height - block_height) / 2);

            style.save();
            style.set_state(state);
            style.render_layout(cr, (double) x, (double) y, body);

            if (shortcuts != null)
                style.render_layout(cr, (double) x, (double) (y + body_height + 4), shortcuts);
            style.restore();
        }
    }

    // A dialog page that allows management of notifications
    // [{"id": 2, "summary": "Hello! January", "body": "", "application": "notify-send", "icon": "face-wink", "urgency": 1, "actions": [], "hints": {"urgency": 1}}]
    class RoficationPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 7;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_APP = 1;
        private const int ITEM_VIEW_COLUMN_DETAIL = 2;
        private const int ITEM_VIEW_COLUMN_ID = 3;
        private const int ITEM_VIEW_COLUMN_APP_INFO = 4;
        private const int ITEM_VIEW_COLUMN_NOTIFICATION = 5;
        private const int ITEM_VIEW_COLUMN_ACTIONS = 6;

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

        private RoficationClient rofi_client;

        private int selected_notification_id = -1;

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
            return "This dialog manages desktop notifications. Type to filter the list. Press Enter to activate the highlighted notification. When the notification has actions, Alt 1 through Alt 9 run them.";
        }

        public char get_keybinding() {
            return 'n';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Activate Notification");
            keybindings.set("Alt 1..9", "Run Notification Action");
            keybindings.set("del", "Delete Notification");
            keybindings.set("shift del", "Delete All Notifications");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.icon_size = settings.get_int("icon-size");

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (string), typeof (DesktopAppInfo), typeof (NotificationDesc), typeof (string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            rofi_client = new RoficationClient("/tmp/rofi_notification_daemon");
            load_notifications.begin((obj, res) => {
                try {
                    load_notifications.end(res);

                    set_selection();
                } catch (GLib.Error err) {
                    stderr.printf("Error: load_notifications failed: %s\n", err.message);
                    show_load_error(err);
                }
            });

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;

            post_launch_sleep = settings.get_int("post-launch-sleep");
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
            // Body and shortcuts share one cell, so the shortcuts take no width from the text
            var detail_renderer = new NotificationCellRenderer();
            detail_renderer.wrap_width = 300;
            var detail_column = new Gtk.TreeViewColumn();
            detail_column.pack_start(detail_renderer, true);
            detail_column.add_attribute(detail_renderer, "text", ITEM_VIEW_COLUMN_DETAIL);
            detail_column.add_attribute(detail_renderer, "hints", ITEM_VIEW_COLUMN_ACTIONS);
            detail_column.expand = true;
            item_view.append_column(detail_column);

            // The drawn width is known only after the tree view allocates its columns
            item_view.size_allocate.connect(() => {
                var separator = GLib.Value(typeof(int));
                item_view.style_get_property("horizontal-separator", ref separator);
                int drawn_width = detail_column.get_width() - separator.get_int();
                if (drawn_width > 0 && drawn_width != detail_renderer.wrap_width) {
                    detail_renderer.wrap_width = drawn_width;
                    detail_column.queue_resize();
                }
            });

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);

            item_view.get_selection().changed.connect(on_selection);
        }

        // Delete acts on the highlighted notification, or on none
        private void on_selection(Gtk.TreeSelection selection) {
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            selected_notification_id = -1;
            if (selection.get_selected(out model, out iter)) {
                string notification_id;
                filter.@get(iter, ITEM_VIEW_COLUMN_ID, out notification_id);

                selected_notification_id = int.parse(notification_id);
            }
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            filter.get_iter(out iter, row_path);
            execute_app_from_selection(iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            filter.refilter();
            // A new text highlights its first match, wherever the arrow keys left the highlight
            if (path == null)
                path = new Gtk.TreePath.first();
            select_first_row(item_view, path);
            set_selection();
        }

        // called on enter when in text box
        void on_entry_activated() {
            if (filter.get_iter(out iter, path))
                execute_app_from_selection(iter);
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
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

        private async void load_notifications() throws GLib.Error {
            var notifications = rofi_client.get_notifications();
            notifications.sort(compare_notifications_newest_first);
            var icon_theme = Gtk.IconTheme.get_default();
            model.clear();

            foreach (var notification in notifications) {
                var desktopAppInfo = getDesktopAppInfo(notification.application);
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

                string action_hints = "";
                if (notification.action_count > 0) {
                    var labels = new StringBuilder();
                    for (int i = 0; i < notification.action_count; ++i) {
                        if (labels.len > 0) labels.append("  ");
                        // No-break spaces keep each shortcut whole when the line wraps
                        labels.append_printf("[Alt\xc2\xa0%d]\xc2\xa0%s", i + 1,
                            notification.action_label(i).replace(" ", "\xc2\xa0"));
                    }
                    action_hints = labels.str;
                }

                model.append(out iter);
                model.set(
                    iter,
                    ITEM_VIEW_COLUMN_ICON, iconPixBuff,
                    ITEM_VIEW_COLUMN_APP, notification.application,
                    ITEM_VIEW_COLUMN_DETAIL, detail,
                    ITEM_VIEW_COLUMN_ID, notification.id.to_string(),
                    ITEM_VIEW_COLUMN_APP_INFO, desktopAppInfo,
                    ITEM_VIEW_COLUMN_NOTIFICATION, notification,
                    ITEM_VIEW_COLUMN_ACTIONS, action_hints
                );
            }
        }

        // Say in the list why it is empty; the row is no notification, so Delete ignores it
        private void show_load_error(GLib.Error err) {
            model.clear();
            model.append(out iter);
            model.set(
                iter,
                ITEM_VIEW_COLUMN_ICON, Ilia.load_icon_from_name(Gtk.IconTheme.get_default(), "dialog-error", icon_size),
                ITEM_VIEW_COLUMN_DETAIL, "Could not load notifications\n" + err.message,
                ITEM_VIEW_COLUMN_ID, "-1"
            );
            set_selection();
        }

        private DesktopAppInfo ? getDesktopAppInfo(string appName) {
            string * *[] desktopApps = GLib.DesktopAppInfo.search(appName);

            if (desktopApps.length < 1) return null;

            // Take top search result
            return new DesktopAppInfo(*desktopApps[0]);
        }

        // Automatically set the first item in the list as selected.
        private void set_selection() {
            if (path == null)
                path = new Gtk.TreePath.first();
            // After deleting the last row, highlight the new last one
            clamp_path_to_rows(path, filter);
            Gtk.TreeSelection selection = item_view.get_selection();

            selection.set_mode(SelectionMode.SINGLE);
            selection.select_path(path);

            // The selection may not have changed, so the changed signal may not come
            on_selection(selection);
        }

        public void show() {
            item_view.grab_focus();
        }

        public bool key_event(Gdk.EventKey event) {
            if (handle_emacs_vim_nav(item_view, path, event))
                return true;

            if ((event.state & Gdk.ModifierType.MOD1_MASK) != 0 &&
                event.keyval >= (uint) '1' && event.keyval <= (uint) '9' &&
                invoke_selected_action((int) event.keyval - (int) '1'))
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

        private bool invoke_selected_action(int index) {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter selected;
            if (!item_view.get_selection().get_selected(out selected_model, out selected))
                return false;

            NotificationDesc notification;
            filter.@get(selected, ITEM_VIEW_COLUMN_NOTIFICATION, out notification);

            if (notification == null || index < 0 || index >= notification.action_count)
                return false;

            try {
                rofi_client.invoke_action(notification.id, notification.action_key(index));
            } catch (GLib.Error e) {
                stderr.printf("%s\n", e.message);
            }
            session_controller.quit();
            return true;
        }

        private void delete_selected_notification() {
            if (selected_notification_id > -1) {
                try {
                    rofi_client.delete_notification_by_id(selected_notification_id);

                    load_notifications.begin();
                    selected_notification_id = -1;
                    set_selection();
                } catch (GLib.Error err) {
                    stderr.printf("Error: delete_selected_notification failed: %s\n", err.message);
                }
            }
        }

        private void delete_all_notifications() {
            string[] ids = new string[10];
            for (bool next = filter.get_iter_first(out iter); next; next = filter.iter_next(ref iter)) {
                string notification_id;
                filter.@get(iter, ITEM_VIEW_COLUMN_ID, out notification_id);

                ids += notification_id;
            }

            try {
                if (ids.length > 0) rofi_client.delete_notifications_by_ids(ids);

                load_notifications.begin();
                set_selection();
            } catch (GLib.Error err) {
                stderr.printf("Error: delete_func failed: %s\n", err.message);
            }
        }

        // launch a desktop app
        public void execute_app_from_selection(Gtk.TreeIter selection) {
            NotificationDesc notification;
            filter.@get(selection, ITEM_VIEW_COLUMN_NOTIFICATION, out notification);

            // a notification with a default action behaves as it does in GNOME
            // that is activating it runs the action instead of launching the
            // application
            if (notification != null && notification.has_action("default")) {
                try {
                    rofi_client.see_notification(notification.id);
                } catch (GLib.Error e) {
                    stderr.printf("%s\n", e.message);
                }
                session_controller.quit();
                return;
            }

            DesktopAppInfo app_info;
            filter.@get(selection, ITEM_VIEW_COLUMN_APP_INFO, out app_info);

            try {
                app_info.launch_uris(null, null);

                GLib.Thread.usleep(post_launch_sleep);
                session_controller.quit();
            } catch (GLib.Error e) {
                stderr.printf("%s\n", e.message);
            }
        }
    }
}
