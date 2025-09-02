using Gtk;

namespace Ilia {
    class HelpPage : DialogPage, GLib.Object {
        private const int KEYBINDING_VIEW_COLUMNS = 2;
        private const int KEYBINDING_VIEW_COLUMN_KEY = 0;
        private const int KEYBINDING_VIEW_COLUMN_FUNCTION = 1;

        // The widget to display list of keybindings
        private Gtk.TreeView keybinding_view;
        // Model for keybindings
        private Gtk.ListStore model;

        private Gtk.Entry entry;
        private SessionContoller session_controller;
        private Gtk.Widget root_widget;
        private Gtk.TreePath path;

        // Store the active page to get its help and keybindings
        private DialogPage active_page;

        public string get_name() {
            return "Help";
        }

        public string get_icon_name() {
            return "";
        }

        public string get_help() {
            return "This is the help page showing keybindings and usage information.";
        }

        public char get_keybinding() {
            return 'h';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);
            keybindings.set("↑ / ↓", "Navigate keybindings");
            keybindings.set("Ctrl+j / Ctrl+k", "Navigate keybindings (vim style)");
            keybindings.set("Ctrl+n / Ctrl+p", "Navigate keybindings (emacs style)");
            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore(KEYBINDING_VIEW_COLUMNS, typeof(string), typeof(string));
            create_keybinding_view();

            var help_widget = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);

            // Add page help text (will be set later when we know the active page)
            var page_help_label = new Label("");
            page_help_label.set_line_wrap(true);
            page_help_label.set_markup("<b>Help</b>\n\nUse the arrow keys or vim/emacs navigation to browse keybindings.");
            help_widget.pack_start(page_help_label, false, false, 5);

            var keybindings_title = new Label("Keybindings");
            keybindings_title.get_style_context().add_class("help_heading");
            help_widget.pack_start(keybindings_title, false, false, 5);

            // Add TreeView directly - let it handle its own scrolling
            help_widget.pack_start(keybinding_view, true, true, 5);

            root_widget = help_widget;
        }

        public void set_active_page(DialogPage page) {
            this.active_page = page;
            update_help_content();
        }

        private void update_help_content() {
            if (active_page == null) return;

            model.clear();

            // Add page-specific keybindings first
            var page_keybindings = active_page.get_keybindings();
            if (page_keybindings != null) {
                page_keybindings.foreach((key, val) => {
                    TreeIter iter;
                    model.append(out iter);
                    model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, key, KEYBINDING_VIEW_COLUMN_FUNCTION, val);
                });
            }

            // Add global keybindings
            TreeIter iter;

            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "↑ / ↓", KEYBINDING_VIEW_COLUMN_FUNCTION, "Navigate items");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "← / →", KEYBINDING_VIEW_COLUMN_FUNCTION, "Switch tabs");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Enter", KEYBINDING_VIEW_COLUMN_FUNCTION, "Select item");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "PgUp / PgDown", KEYBINDING_VIEW_COLUMN_FUNCTION, "Page navigation");
            
            // Window control
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Esc", KEYBINDING_VIEW_COLUMN_FUNCTION, "Exit");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Alt + -", KEYBINDING_VIEW_COLUMN_FUNCTION, "Decrease dialog size");
        
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Alt + +", KEYBINDING_VIEW_COLUMN_FUNCTION, "Increase dialog size");
            
            // Combined Vim/Emacs navigation
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + h", KEYBINDING_VIEW_COLUMN_FUNCTION, "Move cursor left (vim)");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + l", KEYBINDING_VIEW_COLUMN_FUNCTION, "Move cursor right (vim)");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + j / Ctrl + n", KEYBINDING_VIEW_COLUMN_FUNCTION, "Move down (vim/emacs)");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + k / Ctrl + p", KEYBINDING_VIEW_COLUMN_FUNCTION, "Move up (vim/emacs)");

            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + 0", KEYBINDING_VIEW_COLUMN_FUNCTION, "Beginning of line (vim)");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + Shift + 4", KEYBINDING_VIEW_COLUMN_FUNCTION, "End of line (vim)");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + w", KEYBINDING_VIEW_COLUMN_FUNCTION, "Forward one word (vim)");
            
            model.append(out iter);
            model.set(iter, KEYBINDING_VIEW_COLUMN_KEY, "Ctrl + b", KEYBINDING_VIEW_COLUMN_FUNCTION, "Backward one word (vim)");

            set_selection();
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        public bool key_event(Gdk.EventKey key) {
            // Handle vim/emacs navigation for the TreeView
            return handle_emacs_vim_nav(keybinding_view, path, key);
        }

        // Initialize the view displaying keybindings
        private void create_keybinding_view() {
            keybinding_view = new Gtk.TreeView.with_model(model);
            
            // Do not show column headers
            keybinding_view.headers_visible = false;
            
            // Optimization
            keybinding_view.fixed_height_mode = true;
            
            // Disable Gtk search
            keybinding_view.enable_search = false;
            
            // Create columns
            keybinding_view.insert_column_with_attributes(-1, "Key", new CellRendererText(), "text", KEYBINDING_VIEW_COLUMN_KEY);
            keybinding_view.insert_column_with_attributes(-1, "Function", new CellRendererText(), "text", KEYBINDING_VIEW_COLUMN_FUNCTION);
            
            // Auto-size columns when realized
            keybinding_view.realize.connect(() => {
                keybinding_view.columns_autosize();
            });
        }

        // Automatically set the first item in the list as selected.
        private void set_selection() {
            Gtk.TreeSelection selection = keybinding_view.get_selection();

            if (selection.count_selected_rows() == 0) {
                selection.set_mode(SelectionMode.SINGLE);
                if (path == null)
                    path = new Gtk.TreePath.first();
                selection.select_path(path);
            } else {
                var path_list = selection.get_selected_rows(null);
                if (path_list != null) {
                    unowned var element = path_list.first();
                    keybinding_view.scroll_to_cell(element.data, null, false, 0f, 0f);
                }
            }
        }

        public void show() {
            keybinding_view.grab_focus();
        }

        // filter selection based on contents of Entry - not used for help page
        public void on_entry_changed() {
            // Help page doesn't filter content
        }

        // called on enter when in text box - not used for help page
        public void on_entry_activated() {
            // Help page doesn't have actions
        }
    }
}