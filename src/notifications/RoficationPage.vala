using Gtk;

namespace Ilia {
    // A dialog page that allows management of notifications
    // [{"id": 2, "summary": "Hello! January", "body": "", "application": "notify-send", "icon": "face-wink", "urgency": 1, "actions": [], "hints": {"urgency": 1}}]
    class RoficationPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 5;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_APP = 1;
        private const int ITEM_VIEW_COLUMN_DETAIL = 2;
        private const int ITEM_VIEW_COLUMN_ID = 3;
        private const int ITEM_VIEW_COLUMN_APP_INFO = 4;

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

        public string get_name () {
            return "<u>N</u>otifications";
        }

        public string get_icon_name () {
            return "mail-message-new";
        }

        public string get_help () {
            return "This dialog manages desktop notifications. Initially all desktop apps are presented. The user may filter the list in the top text box.";
        }

        public char get_keybinding() {
            return 'n';
        }

        public HashTable<string, string>? get_keybindings() {
            var keybindings = new HashTable<string, string ? >(str_hash, str_equal);

            keybindings.set("del", "Delete Notification");
            keybindings.set("shift del", "Delete All Notifications");

            return keybindings;
        }

        public async void initialize (GLib.Settings settings, HashTable<string, string ? > arg_map, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.icon_size = settings.get_int ("icon-size");

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (string), typeof (DesktopAppInfo));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            rofi_client = new RoficationClient ("/tmp/rofi_notification_daemon");
            load_notifications.begin ((obj, res) => {
                try {
                    load_notifications.end (res);

                    model.set_sort_column_id (1, SortType.ASCENDING);
                    set_selection ();
                } catch (GLib.Error err) {
                    stderr.printf ("Error: load_notifications failed: %s\n", err.message);
                }
            });

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (item_view);
            scrolled.expand = true;

            root_widget = scrolled;

            post_launch_sleep = settings.get_int("post-launch-sleep");
        }

        public Gtk.Widget get_root () {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view () {
            item_view = new Gtk.TreeView.with_model (filter);

            // Do not show column headers
            item_view.headers_visible = false;
            item_view.fixed_height_mode = false;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes (-1, "Icon", new CellRendererPixbuf (), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes (-1, "App", new CellRendererText (), "text", ITEM_VIEW_COLUMN_APP);
            var wrapping_cell_renderer = new CellRendererText ();
            wrapping_cell_renderer.wrap_mode = Pango.WrapMode.WORD;
            wrapping_cell_renderer.wrap_width = 300;
            item_view.insert_column_with_attributes (-1, "Body", wrapping_cell_renderer, "text", ITEM_VIEW_COLUMN_DETAIL);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);

            item_view.get_selection ().changed.connect (on_selection);
        }

        public void grab_focus (uint keycode) {            
            item_view.grab_focus ();
        }

        private void on_selection (Gtk.TreeSelection selection) {
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            if (selection.get_selected (out model, out iter)) {
                string notification_id;
                filter.@get (iter, ITEM_VIEW_COLUMN_ID, out notification_id);

                selected_notification_id = int.parse (notification_id);
            }
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            execute_app_from_selection (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            if (filter.get_iter_first (out iter)) {
                execute_app_from_selection (iter);
            }
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string query_string = entry.get_text ().down ().strip ();
            GLib.Value table_info;

            if (query_string.length > 0) {
                model.get_value (iter, ITEM_VIEW_COLUMN_DETAIL, out table_info);
                string body = table_info.get_string ();

                model.get_value (iter, ITEM_VIEW_COLUMN_APP, out table_info);
                string app = table_info.get_string ();

                if (body != null && body.down ().contains (query_string)) return true;
                if (app != null && app.down ().contains (query_string)) return true;

                return false;
            } else {
                return true;
            }
        }

        private async void load_notifications () throws GLib.Error {
            var notifications = rofi_client.get_notifications ();
            var icon_theme = Gtk.IconTheme.get_default ();
            model.clear ();

            foreach (var notification in notifications) {
                var desktopAppInfo = getDesktopAppInfo(notification.application);
                Gdk.Pixbuf? iconPixBuff = null;
                if (desktopAppInfo != null) {
                    iconPixBuff = Ilia.load_icon_from_info (icon_theme, desktopAppInfo, icon_size);
                } else {
                    iconPixBuff = Ilia.load_icon_from_name(icon_theme, notification.icon, icon_size);
                }

                string detail;
                if (notification.summary.length > 0 && notification.body.length > 0) {
                    detail = notification.summary + "\n" + notification.body;
                } else if (notification.summary.length == 0 && notification.body.length > 0) {
                    detail = notification.body;
                } else if (notification.summary.length > 0 && notification.body.length == 0) {
                    detail = notification.summary;
                } else {
                    detail = "<no content>";
                }

                model.append (out iter);
                model.set (
                    iter,
                    ITEM_VIEW_COLUMN_ICON, iconPixBuff,
                    ITEM_VIEW_COLUMN_APP, notification.application,
                    ITEM_VIEW_COLUMN_DETAIL, detail,
                    ITEM_VIEW_COLUMN_ID, notification.id.to_string (),
                    ITEM_VIEW_COLUMN_APP_INFO, desktopAppInfo
                );
            }
        }

        private DesktopAppInfo? getDesktopAppInfo(string appName) {            
            string**[] desktopApps = GLib.DesktopAppInfo.search(appName);

            if (desktopApps.length < 1) return null;

            // Take top search result
            return new DesktopAppInfo (*desktopApps[0]);
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreePath path = new Gtk.TreePath.first ();
            Gtk.TreeSelection selection = item_view.get_selection ();

            selection.set_mode (SelectionMode.SINGLE);
            selection.select_path (path);

            if (filter.get_iter_first (out iter)) {
                string notification_id;
                filter.@get (iter, ITEM_VIEW_COLUMN_ID, out notification_id);
                
                selected_notification_id = int.parse (notification_id);
            }
        }

        public bool key_event (Gdk.EventKey event) {
            if (event.keyval == 65535) {
                if ((event.state & Gdk.ModifierType.SHIFT_MASK) == Gdk.ModifierType.SHIFT_MASK) {
                    delete_all_notifications ();
                } else {
                    delete_selected_notification ();
                }
                return true;
            }

            return false;
        }

        private void delete_selected_notification () {
            if (selected_notification_id > -1) {
                try {
                    rofi_client.delete_notification_by_id (selected_notification_id);

                    load_notifications.begin ();
                    selected_notification_id = -1;
                    set_selection ();
                } catch (GLib.Error err) {
                    stderr.printf ("Error: delete_selected_notification failed: %s\n", err.message);
                }                
            } 
        }

        private void delete_all_notifications () {
            string[] ids = new string[10];
            for (bool next = filter.get_iter_first (out iter); next; next = filter.iter_next (ref iter)) {
                string notification_id;
                filter.@get (iter, ITEM_VIEW_COLUMN_ID, out notification_id);

                ids += notification_id;
            }

            try {
                if (ids.length > 0) rofi_client.delete_notifications_by_ids (ids);
                
                load_notifications.begin ();
                set_selection ();
            } catch (GLib.Error err) {
                stderr.printf ("Error: delete_func failed: %s\n", err.message);
            }
        }

        // launch a desktop app
        public void execute_app_from_selection (Gtk.TreeIter selection) {            
            DesktopAppInfo app_info;
            filter.@get (selection, ITEM_VIEW_COLUMN_APP_INFO, out app_info);

            try {
                app_info.launch_uris (null, null);
                
                GLib.Thread.usleep(post_launch_sleep);
                session_controller.quit ();
            } catch (GLib.Error e) {
                stderr.printf ("%s\n", e.message);
            }
        }
    }
}