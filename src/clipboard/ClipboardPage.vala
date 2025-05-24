
using Gtk;

namespace Ilia {
    class ClipboardPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 3;
        private const int ITEM_VIEW_COLUMN_CONTENT = 0;
        private const int ITEM_VIEW_COLUMN_PREVIEW = 1;
        private const int ITEM_VIEW_COLUMN_TIMESTAMP = 2;
        private const int CLIPBOARD_HISTORY_MAX = 10; // change accordingly

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // Access state from model
        private Gtk.TreeIter iter;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;

        private Gtk.Entry entry;
        private GLib.Settings settings;

        private SessionContoller session_controller;

        private Gtk.Widget root_widget;

        private Gtk.TreePath path;

        // For storing clipboard history
        private string[] clipboard_history;
        private int history_index;

        // Clipboard monitor
        private Gtk.Clipboard clipboard;
        private uint clipboard_monitor_id;

        public string get_name() {
            return "Clip<u>b</u>oard";
        }

        public string get_icon_name() {
            return "edit-paste";
        }

        public string get_help() {
            return "This dialog shows the clipboard history. Use the filter box to search for specific items. The list shows clipboard content with a preview, select an item and press Enter to copy it to the clipboard.";
        }

        public char get_keybinding() {
            return 'b';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Copy Item to Clipboard");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.settings = settings;

            // Initialize clipboard history storage
            clipboard_history = new string[CLIPBOARD_HISTORY_MAX];
            history_index = 0;

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof(string), typeof(string), typeof(string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();

            // Load saved clipboard history
            load_clipboard_history();

            // Get the clipboard
            var display = Gdk.Display.get_default();
            if (display != null) {
                clipboard = Gtk.Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);

                // Initial content check
                check_clipboard_content();

                // Set up clipboard monitoring
                start_monitoring_clipboard();
            }

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;

            root_widget = scrolled;

            // Set initial selection
            set_selection();
        }

        // Load clipboard history from GSettings
        private void load_clipboard_history() {
            string[] saved_history = settings.get_strv("clipboard-history");

            // Clear existing history
            for (int i = 0; i < CLIPBOARD_HISTORY_MAX; i++) {
                clipboard_history[i] = null;
            }

            // Load saved history (limited to max size)
            int count = int.min(saved_history.length, CLIPBOARD_HISTORY_MAX);
            for (int i = 0; i < count; i++) {
                clipboard_history[i] = saved_history[i];
            }

            // Update model with loaded history
            update_model();
        }

        // Save clipboard history to GSettings
        private void save_clipboard_history() {
            // Create a list to store non-null items
            string[] items_to_save = {};

            // Add non-null entries to the list
            for (int i = 0; i < CLIPBOARD_HISTORY_MAX; i++) {
                if (clipboard_history[i] != null && clipboard_history[i].strip() != "") {
                    items_to_save += clipboard_history[i];
                }
            }

            // Save to GSettings
            settings.set_strv("clipboard-history", items_to_save);
        }

        private void check_clipboard_content() {
            if (clipboard != null) {
                clipboard.request_text((clipboard, text) => {
                    if (text != null && text.strip() != "") {
                        add_to_history(text);
                    }
                });
            }
        }

        private void start_monitoring_clipboard() {
            clipboard_monitor_id = Timeout.add(1000, () => {
                check_clipboard_content();
                return true;
            });
        }

        private void stop_monitoring_clipboard() {
            if (clipboard_monitor_id > 0) {
                Source.remove(clipboard_monitor_id);
                clipboard_monitor_id = 0;
            }
        }

        protected override void dispose() {
            // Save clipboard history before disposing
            save_clipboard_history();
            stop_monitoring_clipboard();
            base.dispose();
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        public bool key_event(Gdk.EventKey key) {
            if (handle_emacs_vim_nav(item_view, path, key))
                return true;

            var keycode = key.keyval;

            if (keycode == Ilia.KEY_CODE_ENTER) {
                if (filter.get_iter_first(out iter)) {
                    Gtk.TreeSelection selection = item_view.get_selection();
                    Gtk.TreeModel model;
                    Gtk.TreeIter selected_iter;

                    if (selection.get_selected(out model, out selected_iter)) {
                        copy_to_clipboard_from_selection(selected_iter);
                        return true;
                    }
                }
            }

            return false;
        }

        // sets the first item in the list as selected.
        private void set_selection() {
            Gtk.TreeSelection selection = item_view.get_selection();

            if (selection.count_selected_rows() == 0) {
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

        public void show() {
            item_view.grab_focus();
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);
            item_view.get_style_context().add_class("item_view");
            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Disable Gtk search
            item_view.enable_search = false;

            // Create text renderer that will wrap and show multiple lines
            var text_renderer = new CellRendererText();
            text_renderer.wrap_mode = Pango.WrapMode.WORD_CHAR;
            text_renderer.wrap_width = 300;
            text_renderer.ellipsize = Pango.EllipsizeMode.END;

            // Add columns Preview
            item_view.insert_column_with_attributes(-1, "Preview", text_renderer, "text", ITEM_VIEW_COLUMN_PREVIEW);

            // Launch on click
            item_view.set_activate_on_single_click(true);

            // Copy to clipboard on row selection
            item_view.row_activated.connect(on_row_activated);
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            filter.get_iter(out iter, row_path);
            copy_to_clipboard_from_selection(iter);
        }

        // filter selection based on contents of Entry
        public void on_entry_changed() {
            filter.refilter();
            set_selection();
        }

        // called on enter when in text box
        public void on_entry_activated() {
            if (filter.get_iter(out iter, path))
                copy_to_clipboard_from_selection(iter);
        }

        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string query_string = entry.get_text().down().strip();

            if (query_string.length > 0) {
                GLib.Value content_value;
                string content;
                model.get_value(iter, ITEM_VIEW_COLUMN_CONTENT, out content_value);
                content = content_value.get_string();

                return content != null && content.down().contains(query_string);
            } else {
                return true;
            }
        }

        // Add text to history if it's not already there
        private void add_to_history(string text) {
            // Check if text is already in the history to avoid duplicates
            for (int i = 0; i < CLIPBOARD_HISTORY_MAX; i++) {
                if (clipboard_history[i] != null && clipboard_history[i] == text) {
                    // Move this item to the top (most recent)
                    string temp = clipboard_history[i];

                    // Shift items down to make room at the top
                    for (int j = i; j > 0; j--) {
                        clipboard_history[j] = clipboard_history[j-1];
                    }

                    // Place at the top
                    clipboard_history[0] = temp;

                    // Update the model to reflect the changes
                    update_model();

                    // Save the updated history
                    save_clipboard_history();
                    return;
                }
            }

            // Make room for new item
            for (int i = CLIPBOARD_HISTORY_MAX - 1; i > 0; i--) {
                clipboard_history[i] = clipboard_history[i-1];
            }

            // to add new item at the top
            clipboard_history[0] = text;
            history_index = (history_index + 1) % CLIPBOARD_HISTORY_MAX;

            update_model();

            save_clipboard_history();
        }

        // Update the tree model with the current clipboard history
        private void update_model() {
            // Clear the model
            model.clear();

            // Add clipboard history items to the model
            for (int i = 0; i < CLIPBOARD_HISTORY_MAX; i++) {
                if (clipboard_history[i] != null && clipboard_history[i].strip() != "") {
                    // Get current date/time
                    var now = new DateTime.now_local();
                    string timestamp = now.format("%H:%M:%S");

                    // Create a preview (truncated version for display)
                    string preview = clipboard_history[i];
                    if (preview.length > 60) {
                        preview = preview.substring(0, 60) + "...";
                    }

                    // Remove newlines for the preview
                    preview = preview.replace("\n", " ");

                    model.append(out iter);
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_CONTENT, clipboard_history[i],
                        ITEM_VIEW_COLUMN_PREVIEW, preview,
                        ITEM_VIEW_COLUMN_TIMESTAMP, timestamp
                    );
                }
            }

            // Reset selection after model update
             if (model.get_iter_first(out iter))
                set_selection();
        }

        // Copy selected text to clipboard
        private void copy_to_clipboard_from_selection(Gtk.TreeIter selection) {
            GLib.Value content_value;
            filter.get_value(selection, ITEM_VIEW_COLUMN_CONTENT, out content_value);
            string content = content_value.get_string();

            if (content != null) {
                var display = Gdk.Display.get_default();
                var clipboard = Gtk.Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);

                //stop monitoring to prevent re-adding
                stop_monitoring_clipboard();

                clipboard.set_text(content, -1);
                clipboard.store();

                // Restart monitoring after a short delay
                Timeout.add(500, () => {
                    start_monitoring_clipboard();
                    return false;
                });

                // Move this item to the top of history
                add_to_history(content);

                // Exit after copying
                // session_controller.quit();
            }
        }
    }
}
