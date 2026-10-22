using Gtk;

namespace Ilia {
    class TextListPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 2;
        private const int ITEM_VIEW_COLUMN_ICON = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // The lines read so far, and the ones matching the entry text
        private TextFilter text_filter;
        // View on the matching lines
        private FilteredLinesModel model;
        // Access state from model
        private Gtk.TreeIter iter;
        // Reads stdin without blocking, so the window shows at once
        private LineReader reader;
        // Filters and fills the view from idle
        private FilterWork work;
        // Enter was pressed with no match while input was still being read
        private bool enter_pending = false;

        private Gtk.Entry entry;

        private SessionContoller session_controller;

        private Gtk.Widget root_widget;

        private Gtk.TreePath path;

        private string name = "TextList";

        private string icon = "utilities-terminal";

        // The following items track UI state between icon or no icon
        private bool render_icon_flag = true;
        private int name_column_index = ITEM_VIEW_COLUMN_NAME;

        public string get_name() {
            return name;
        }

        public string get_icon_name() {
            return icon;
        }

        public string get_help() {
            return "This dialog presents a filterable list of items to select from. If no item matches, enter returns the typed text.";
        }

        public char get_keybinding() {
            // FIXME - this is never used
            return 't';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Select Item");

            return keybindings;
        }

        public void show() {
            item_view.grab_focus();
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            if (arg_map.contains("-l"))
                this.name = arg_map.get("-l");
            if (arg_map.contains("-i"))
                this.icon = arg_map.get("-i");
            if (arg_map.contains("-n")) {
                this.render_icon_flag = false;
                name_column_index = 0;
            }

            text_filter = new TextFilter();
            text_filter.reset.connect(on_filter_reset);
            text_filter.appended.connect(on_filter_appended);
            model = new FilteredLinesModel(text_filter, render_icon_flag, load_item_icon(settings.get_int("icon-size")));
            work = new FilterWork(text_filter, model);
            work.first_rows.connect(select_first);
            work.done.connect(resolve_pending_enter);

            create_item_view();
            set_selection();

            // Read stdin in the background; lines show up as they arrive
            reader = new LineReader(new UnixInputStream(0, false));
            reader.lines_read.connect((lines) => {
                text_filter.add_lines(lines);
                work.schedule();
            });
            reader.finished.connect(resolve_pending_enter);
            reader.read_all.begin();

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
            item_view = new Gtk.TreeView.with_model(model);

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            if (this.render_icon_flag)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", name_column_index);

            // Launch app on one click
            item_view.set_activate_on_single_click(true);

            // Launch app on row selection
            item_view.row_activated.connect(on_row_activated);

            // Input may still be read and filtered when the window closes: leave the view alone
            item_view.destroy.connect(stop_work);
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (handle_emacs_vim_nav(item_view, path, event_key))
                return true;

            var keycode = event_key.keyval;

            if (is_enter_key(keycode)) {
                // Act on the matches for the text as typed, among all lines read so far
                text_filter.finish();
                // The view activates the selected row: make sure the first match is in it
                if (model.row_count == 0 && model.pending > 0) {
                    model.announce(1);
                    select_first();
                }
                if (text_filter.visible_count == 0 && entry.text.length > 0) {
                    // While input is still being read a later line may match: decide once one does or input ends
                    if (reader.done)
                        print(entry.text);
                    else
                        enter_pending = true;
                    return true;
                }
            }

            return false;
        }

        // called on enter from TreeView
        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            if (model.get_iter(out iter, row_path))
                print_selection(iter);
        }

        // filter selection based on contents of Entry; the work is done in slices from idle
        void on_entry_changed() {
            enter_pending = false;
            text_filter.set_query(entry.get_text());
            work.schedule();
        }

        // called on enter when in text box
        void on_entry_activated() {
            text_filter.finish();
            int position = path.get_indices()[0];
            if (position < text_filter.visible_count)
                print(text_filter.get_visible_line(position));
        }

        // Filtering for new text completed: give the view the new rows in one go
        private void on_filter_reset() {
            item_view.set_model(null);
            model.sync();
            item_view.set_model(model);
            select_first();
            resolve_pending_enter();
        }

        // Lines read later match the text: the view gets them from idle, a slice at a time
        private void on_filter_appended(int first, int count) {
            resolve_pending_enter();
        }

        // Enter was pressed with no match while reading: print the first match once there is one, or the text once input ends
        private void resolve_pending_enter() {
            if (!enter_pending) return;

            if (text_filter.visible_count > 0) {
                enter_pending = false;
                print(text_filter.get_visible_line(0));
            } else if (reader.done && !text_filter.busy) {
                enter_pending = false;
                print(entry.text);
            }
        }

        private void select_first() {
            if (model.row_count > 0)
                item_view.set_cursor(new Gtk.TreePath.first(), null, false);
        }

        private Gdk.Pixbuf ? load_item_icon(int icon_size) {
            if (!this.render_icon_flag) return null;

            Gdk.Pixbuf ? pixbuf = null;
            var icon_theme = Gtk.IconTheme.get_default();

            if (icon != null && icon.length > 0)
                pixbuf = Ilia.load_icon_from_name(icon_theme, icon, icon_size);

            if (pixbuf == null)
                pixbuf = Ilia.load_icon_from_name(icon_theme, "applications-other", icon_size);

            return pixbuf;
        }

        // Automatically set the first item in the list as selected.
        private void set_selection() {
            Gtk.TreeSelection selection = item_view.get_selection();

            if (selection.count_selected_rows() == 0) {  // initial state, nothing explicitly selected by user
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

        // launch a desktop app
        public void print_selection(Gtk.TreeIter selection) {
            string cmd_path;
            model.@get(selection, name_column_index, out cmd_path);

            if (cmd_path != null) print(cmd_path);
        }

        private void stop_work() {
            work.stop();
            enter_pending = false;
        }

        private void print(string selection) {
            stop_work();
            stdout.printf("%s\n", selection);

            session_controller.quit();
        }
    }
}