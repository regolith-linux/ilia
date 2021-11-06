using Gtk;

namespace Ilia {
    // A dialog page that allows management of notifications
    // [{"id": 1, "summary": "summary1", "body": "body1", "application": "Slack", "urgency": 1, "actions": []}]
    class RoficationPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 3;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_APP = 1;
        private const int ITEM_VIEW_COLUMN_DETAIL = 2;

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

        public string get_name () {
            return "Notifications";
        }

        public string get_icon_name () {
            return "mail-message-new";
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (Gdk.Pixbuf), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            rofi_client = new RoficationClient ("/tmp/rofi_notification_daemon");
            load_notifications.begin ((obj, res) => {
                try {
                    load_notifications.end (res);

                    model.set_sort_column_id (0, SortType.ASCENDING);
                    // model.set_sort_func (0, app_sort_func);
                    set_selection ();
                } catch (GLib.Error err) {
                    stderr.printf ("Error: load_notifications failed: %s\n", err.message);
                }
            });

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (item_view);
            scrolled.expand = true;

            root_widget = scrolled;
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
        }

        public void grab_focus (uint keycode) {
            if (keycode == DialogWindow.KEY_CODE_ENTER && !filter.get_iter_first (out iter) && entry.text.length > 0) {
                execute_app (entry.text);
            }

            item_view.grab_focus ();
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

            foreach (var notification in notifications) {
                var iconPixBuff = load_icon (icon_theme, notification);

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
                    ITEM_VIEW_COLUMN_DETAIL, detail
                );
            }
        }

        private Gdk.Pixbuf ? load_icon (Gtk.IconTheme icon_theme, NotificationDesc notification) {
            try {
                var icon_info = icon_theme.lookup_icon (notification.icon, 32, Gtk.IconLookupFlags.FORCE_SIZE); // from icon theme
                if (icon_info != null) {
                    return icon_info.load_icon ();
                }

                icon_info = icon_theme.lookup_icon ("emblem-generic", 32, Gtk.IconLookupFlags.FORCE_SIZE);
                if (icon_info != null) {
                    return icon_info.load_icon ();
                }
            } catch (GLib.Error err) {
                stderr.printf ("Error: load_icon failed: %s\n", err.message);
            }

            return null;
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreePath path = new Gtk.TreePath.first ();
            Gtk.TreeSelection selection = item_view.get_selection ();

            selection.set_mode (SelectionMode.SINGLE);
            selection.select_path (path);
        }

        // launch a desktop app
        public void execute_app_from_selection (Gtk.TreeIter selection) {
        }

        private void execute_app (string cmd_path) {
        }
    }
}