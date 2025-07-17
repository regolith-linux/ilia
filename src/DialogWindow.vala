using Gtk;

namespace Ilia {
    public const int KEY_CODE_ESCAPE = 65307;
    public const int KEY_CODE_LEFT_ALT = 65513;
    public const int KEY_CODE_RIGHT_ALT = 65514;
    public const int KEY_CODE_SUPER = 65515;
    public const int KEY_CODE_UP = 65362;
    public const int KEY_CODE_DOWN = 65364;
    public const int KEY_CODE_ENTER = 65293;
    public const int KEY_CODE_PGDOWN = 65366;
    public const int KEY_CODE_PGUP = 65365;
    public const int KEY_CODE_RIGHT = 65363;
    public const int KEY_CODE_LEFT = 65361;
    public const int KEY_CODE_PLUS = 43;
    public const int KEY_CODE_MINUS = 45;
    public const int KEY_CODE_QUESTION = 63;

    public const int KEY_CODE_PRINTSRC = 65377;
    public const int KEY_CODE_BRIGHT_UP = 269025026;
    public const int KEY_CODE_BRIGHT_DOWN = 269025027;
    public const int KEY_CODE_MIC_MUTE = 269025202;
    public const int KEY_CODE_VOLUME_UP = 269025043;
    public const int KEY_CODE_VOLUME_DOWN = 269025041;
    public const int KEY_CODE_VOLUME_MUTE = 269025042;

    // Primary UI
    public class DialogWindow : Window, SessionContoller {
        const int MIN_WINDOW_WIDTH = 160;
        const int MIN_WINDOW_HEIGHT = 100;
        const int SCROLL_STEP = 20; // pixels to scroll at a time

        // Reference to all active dialog pages
        private DialogPage[] dialog_pages;
        // The total number of pages (including help)
        private int total_pages = -1;
        // Specifies the array index for dialog_pages of active page
        private uint active_page = 0;
        // Mode switcher
        private Gtk.Notebook notebook;
        // Filtering text box
        private Gtk.Entry entry;
        // Settings backend
        private GLib.Settings settings;

        private Gtk.Grid grid;
        // Controls access to keyboard and mouse
        protected Gdk.Seat seat;

        private Gtk.TreeView keybinding_view;
        private ScrolledWindow help_scrolled_window;
        private bool is_on_help_page = false;

        private string wm_name;
        private bool is_wayland;

        public DialogWindow (HashTable<string, string ?> arg_map, bool is_wayland_session, string wm_name) {
            Object(type: Gtk.WindowType.POPUP); // Window is unmanaged
            window_position = WindowPosition.CENTER_ALWAYS;

            this.wm_name = wm_name;
            this.is_wayland = is_wayland_session;

            settings = new GLib.Settings("org.regolith-linux.ilia");

            entry = new Gtk.Entry ();
            entry.get_style_context ().add_class("filter_entry");
            entry.hexpand = true;
            entry.set_icon_from_icon_name(Gtk.EntryIconPosition.PRIMARY, "system-search-symbolic");
            entry.button_press_event.connect((event) => {
                // Disable context menu as causes de-focus event to exit execution
                return event.button == 3; // squelch right button click event
            });

            entry.changed.connect(on_entry_changed);
            
            // Create a box for the entry and header
            var entry_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            entry_box.pack_start(entry, true, true, 0);

            notebook = new Notebook ();
            notebook.get_style_context ().add_class("notebook");
            notebook.set_tab_pos(PositionType.BOTTOM);

            var focus_page = arg_map.get("-p") ?? "Apps";
            bool all_page_mode = arg_map.contains("-a");

            init_pages(arg_map, focus_page, all_page_mode);

            grid = new Gtk.Grid ();
            grid.get_style_context ().add_class("root_box");
            grid.attach(entry_box, 0, 0, 1, 1);
            grid.attach(notebook, 0, 1, 1, 1);
            add(grid);

            if (is_wayland_session)
                set_size_request(settings.get_int("window-width"), settings.get_int("window-height"));
            else
                set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));


            // Exit if focus leaves us
            focus_out_event.connect(() => {
                quit ();
                return false;
            });

            // Route keys based on function
            key_press_event.connect((key) => {
                if ((key.state & Gdk.ModifierType.MOD1_MASK) == Gdk.ModifierType.MOD1_MASK) { // ALT
                    // Enable page nav keybindings in all page mode.
                    for (int i = 0; i < total_pages; ++i) {
                        if (dialog_pages[i].get_keybinding () == key.keyval || (dialog_pages[i].get_keybinding () - 32) == key.keyval) {
                            // Allow both upper/lower case match
                            notebook.set_current_page(i);
                            return true;
                        }
                    }
                    if (key.keyval == KEY_CODE_PLUS || key.keyval == '+') { // Expand dialog
                        change_size(128);
                        return true;
                    }
                    if (key.keyval == KEY_CODE_MINUS || key.keyval == '-') { // Contract dialog
                        change_size(-128);
                        return true;
                    }
                    // Pass Alt+D key event to active page for handling desktop app actions
                    if (key.keyval == 'd' || key.keyval == 'D') {
                        bool key_handled = dialog_pages[active_page].key_event(key);
                        return key_handled;
                    }
                } else if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) {
                    // movement with vim commands and editing with Ctrl key
                    if (key.keyval == 'h') { // Left - vim style
                        int pos = entry.get_position();
                        if (pos > 0)
                            entry.set_position(pos - 1);
                        return true;
                    }
                    if (key.keyval == 'l') { // Right - vim style
                        int pos = entry.get_position();
                        if (pos < entry.text.length)
                            entry.set_position(pos + 1);
                        return true;
                    }
                    if (key.keyval == 'j' || key.keyval == 'n') { // Down - vim/emacs style
                        if (is_on_help_page && help_scrolled_window != null) {
                            scroll_help_window(true);
                            return true;
                        }
                        bool key_handled = dialog_pages[active_page].key_event(key);
                        return key_handled;
                    }
                    if (key.keyval == 'k' || key.keyval == 'p') { // Up - vim/emacs style
                        if (is_on_help_page && help_scrolled_window != null) {
                            scroll_help_window(false);
                            return true;
                        }
                        bool key_handled = dialog_pages[active_page].key_event(key);
                        return key_handled;
                    }
                    if (key.keyval == '0') { // Beginning of line - vim style
                        entry.set_position(0);
                        return true;
                    }
                    if (key.keyval == '4' && (key.state & Gdk.ModifierType.SHIFT_MASK) != 0) { // End of line (Ctrl+$) - vim style
                        entry.set_position(entry.text.length);
                        return true;
                    }
                    if (key.keyval == 'a') { // Select all - like Ctrl+A
                        entry.select_region(0, entry.text.length);
                        return true;
                    }
                    if (key.keyval == 'w') { // Forward one word - vim style
                        move_forward_word();
                        return true;
                    }
                    if (key.keyval == 'b') { // Back one word - vim style
                        move_backward_word();
                        return true;
                    }
                    if (key.keyval == 'c') { // Copy - Ctrl+C
                        clipboard_copy();
                        return true;
                    }
                    if (key.keyval == 'v') { // Paste - Ctrl+V
                        clipboard_paste();
                        return true;
                    }
                    if (key.keyval == 'x') { // Cut - Ctrl+X
                        clipboard_cut();
                        return true;
                    }
                }

                bool key_handled = false;
                switch (key.keyval) {
                        case KEY_CODE_ESCAPE:
                        case KEY_CODE_SUPER: // Explicit exit
                            quit ();
                            break;
                        case KEY_CODE_BRIGHT_UP:
                        case KEY_CODE_BRIGHT_DOWN:
                        case KEY_CODE_MIC_MUTE:
                        case KEY_CODE_VOLUME_UP:
                        case KEY_CODE_VOLUME_DOWN:
                        case KEY_CODE_VOLUME_MUTE:
                        case KEY_CODE_PRINTSRC: // Implicit exit
                            quit ();
                            break;
                        case KEY_CODE_UP:
                            if (is_on_help_page && help_scrolled_window != null) {
                                scroll_help_window(false);
                                return true;
                            }
                            dialog_pages[active_page].show ();
                            break;
                        case KEY_CODE_DOWN:
                            if (is_on_help_page && help_scrolled_window != null) {
                                scroll_help_window(true);
                                return true;
                            }
                            dialog_pages[active_page].show ();
                            break;
                        case KEY_CODE_ENTER:
                            dialog_pages[active_page].show ();
                            break;
                        case KEY_CODE_PGDOWN:
                            if (is_on_help_page && help_scrolled_window != null) {
                                var adj = help_scrolled_window.get_vadjustment();
                                double page_size = adj.get_page_size();
                                double new_value = double.min(
                                    adj.get_value() + page_size,
                                    adj.get_upper() - page_size
                                );
                                adj.set_value(new_value);
                                return true;
                            }
                            dialog_pages[active_page].show ();
                            break;
                        case KEY_CODE_PGUP:
                            if (is_on_help_page && help_scrolled_window != null) {
                                var adj = help_scrolled_window.get_vadjustment();
                                double page_size = adj.get_page_size();
                                double new_value = double.max(
                                    adj.get_value() - page_size,
                                    adj.get_lower()
                                );
                                adj.set_value(new_value);
                                return true;
                            }
                            dialog_pages[active_page].show ();
                            break;
                        case KEY_CODE_RIGHT:
                        case KEY_CODE_LEFT: // Switch pages
                            notebook.grab_focus ();
                            break;
                        default:            // Pass key event to active page for handling
                            // stdout.printf ("Keycode: %u\n", key.keyval);
                            key_handled = dialog_pages[active_page].key_event(key);
                            if (!key_handled)
                                entry.grab_focus_without_selecting (); // causes entry to consume all unhandled key events
                            break;
                }

                return key_handled;
            });

            entry.activate.connect(on_entry_activated);

            dialog_pages[active_page].show (); // Get page ready to use
        }

        public override void show_all() {
            base.show_all ();
            notebook.set_current_page((int) active_page);
            notebook.switch_page.connect(on_page_switch);
        }

        public void set_seat(Gdk.Seat seat) {
            this.seat = seat;
        }

        private void init_pages(HashTable<string, string ?> arg_map, string focus_page, bool all_page_mode) {
            if (all_page_mode) {
                total_pages = create_all_pages(arg_map, focus_page, ref active_page);
            } else {
                total_pages = 1;
                active_page = 0;
                create_page(focus_page, arg_map);
            }

            // Exit if unable to load active page
            if (dialog_pages[0] == null) {
                stderr.printf("No page loaded, exiting\n");
                Process.exit(1);
            }

            // This allows for multiple page loads.  Until startup performance is addressed, only load one page.
            for (int i = 0; i < total_pages; ++i) {
                Gtk.Box box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
                var label = new Label(null);
                label.set_markup(dialog_pages[i].get_name ());
                var image = new Image.from_icon_name(dialog_pages[i].get_icon_name (), Gtk.IconSize.BUTTON);
                var button = new Button ();
                button.set_can_focus(false);
                button.relief = ReliefStyle.NONE;
                button.add(image);
                int page = i;
                button.clicked.connect(() => {
                    notebook.set_current_page(page);
                });

                box.pack_start(button, false, false, 0);
                box.pack_start(label, false, false, 5);
                box.show_all ();
                notebook.append_page(dialog_pages[i].get_root (), box);
            }

            // FIXME - rework help UI to be consistent for both single and all page modes
            if (!all_page_mode) {
                // Create help page
                var help_label = new Label("Help");
                var help_widget = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);

                var page_help_label = new Label(dialog_pages[0].get_help ());
                page_help_label.set_line_wrap(true);
                help_widget.pack_start(page_help_label, false, false, 5);

                var keybindings_title = new Label("Keybindings");
                keybindings_title.get_style_context ().add_class("help_heading");
                help_widget.pack_start(keybindings_title, false, false, 5);

                keybinding_view = new TreeView ();
                setup_help_treeview(keybinding_view, dialog_pages[0].get_keybindings ());
                help_widget.pack_start(keybinding_view, false, false, 5);
                
                //making help dialogWindow scrollable
                help_scrolled_window = new ScrolledWindow(null, null);
                help_scrolled_window.set_policy(PolicyType.AUTOMATIC, PolicyType.AUTOMATIC);
                help_scrolled_window.add(help_widget);
                
                notebook.append_page(help_scrolled_window, help_label);
                keybinding_view.realize.connect(() => {
                    keybinding_view.columns_autosize ();
                });
            }
        }

        private void create_page(string focus_page, HashTable<string, string ?> arg_map) {
            dialog_pages = new DialogPage[1];

            switch (focus_page.down ()) {
                case "apps":
                    dialog_pages[0] = new DesktopAppPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "terminal":
                    dialog_pages[0] = new CommandPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "notifications":
                    dialog_pages[0] = new RoficationPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "keybindings":
                    dialog_pages[0] = new KeybingingsPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "textlist":
                    dialog_pages[0] = new TextListPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "windows":
                    dialog_pages[0] = new WindowPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "tracker":
                    dialog_pages[0] = new TrackerPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                case "clipboard":
                    dialog_pages[0] = new ClipboardPage ();
                    dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
                    break;
                default:
                    stderr.printf("Unknown page type: %s\n", focus_page);
                    break;
            }
        }

        /**
         * Creates pages for all generally usable pages
         */
        private int create_all_pages(HashTable<string, string ?> arg_map, string focus_page, ref uint start_page) {
            int page_count = 7; // increased for clipboard page
            dialog_pages = new DialogPage[page_count];

            dialog_pages[0] = new DesktopAppPage ();
            dialog_pages[0].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages[1] = new CommandPage ();
            dialog_pages[1].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages[2] = new RoficationPage ();
            dialog_pages[2].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages[3] = new KeybingingsPage ();
            dialog_pages[3].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages[4] = new WindowPage ();
            dialog_pages[4].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages[5] = new TrackerPage ();
            dialog_pages[5].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages[6] = new ClipboardPage ();
            dialog_pages[6].initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            // last page, help, will be initialized later in init

            switch (focus_page.down ()) {
                case "apps":
                    start_page = 0;
                    break;
                case "terminal":
                    start_page = 1;
                    break;
                case "notifications":
                    start_page = 2;
                    break;
                case "keybindings":
                    start_page = 3;
                    break;
                case "windows":
                    start_page = 4;
                    break;
                case "tracker":
                    start_page = 5;
                    break;
                case "clipboard":
                    start_page = 6;
                    break;
                default:
                    stderr.printf("Unknown page type: %s\n", focus_page);
                    start_page = 0;
                    break;
            }

            return page_count;
        }

        private void setup_help_treeview(TreeView view, HashTable<string, string> ? keybindings) {
            var listmodel = new Gtk.ListStore(2, typeof (string), typeof (string));
            view.set_model(listmodel);
        
            view.headers_visible = false;
            view.fixed_height_mode = true;
            view.enable_search = false;
        
            view.insert_column_with_attributes(-1, "Key", new CellRendererText (), "text", 0);
            view.insert_column_with_attributes(-1, "Function", new CellRendererText (), "text", 1);
        
            TreeIter iter;

            if (keybindings != null)
                keybindings.foreach((key, val) => {
                    TreeIter iter2;

                    listmodel.append(out iter2);
                    listmodel.set(iter2, 0, key, 1, val);
                });
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "↑ / ↓", 1, "Navigate items");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "← / →", 1, "Switch tabs");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Enter", 1, "Select item");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "PgUp / PgDown", 1, "Page navigation");
            
            // Window control
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Esc", 1, "Exit");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Alt + -", 1, "Decrease dialog size");
        
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Alt + +", 1, "Increase dialog size");
            
            // Combined Vim/Emacs navigation
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + h", 1, "Move cursor left (vim)");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + l", 1, "Move cursor right (vim)");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + j / Ctrl + n", 1, "Move down (vim/emacs)");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + k / Ctrl + p", 1, "Move up (vim/emacs)");

            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + 0", 1, "Beginning of line (vim)");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + Shift + 4", 1, "End of line (vim)");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + w", 1, "Forward one word (vim)");
            
            listmodel.append(out iter);
            listmodel.set(iter, 0, "Ctrl + b", 1, "Backward one word (vim)");
        
        }

        // Resize the dialog, bigger or smaller
        void change_size(int delta) {
            int width, height;
            get_size(out width, out height);

            width += delta;
            height += delta;

            // Ignore changes past min bounds
            if (width < MIN_WINDOW_WIDTH || height < MIN_WINDOW_HEIGHT)return;

            var monitor = this.get_screen ().get_display ().get_monitor(0);  // Assume first monitor
            if (monitor != null) {
                var geometry = monitor.get_geometry ();

                if (width >= geometry.width || height >= geometry.height)return;
            }

            // Handle resize differently based on wm
            if (is_wayland) {
                set_size_request(width, height);
            } else {
                resize(width, height);
            }

            settings.set_int("window-width", width);
            settings.set_int("window-height", height);
            
            // ui refresh
            queue_resize();
            
            // ui adjustment
            if (notebook != null) {
                notebook.queue_resize();
            }
            
            // ui adjustment
            queue_draw();
        }

        void on_page_switch(Widget ? page, uint page_num) {
            if (page_num == total_pages) { // On help page
                entry.set_sensitive(false);
                is_on_help_page = true;
            } else if (dialog_pages[page_num] != null) {
                active_page = page_num;
                is_on_help_page = false;
                entry.secondary_icon_name = dialog_pages[active_page].get_icon_name ();
                entry.set_sensitive(true);
            }
            dialog_pages[active_page].show ();
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            dialog_pages[active_page].on_entry_changed ();
        }

        void on_entry_activated() {
            dialog_pages[active_page].on_entry_activated ();
        }

        void clipboard_copy() {
            var display = this.get_screen ().get_display ();
            var clipboard = Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);

            int start, end;
            if (entry.get_selection_bounds(out start, out end)) {
                string selected_text = entry.get_text().substring(start, end - start);
                clipboard.set_text(selected_text, selected_text.length);
            } else {
                clipboard.set_text(entry.get_text(), entry.get_text().length);
            }
            clipboard.store();
        }

        void clipboard_cut() {
            var display = this.get_screen().get_display();
            var clipboard = Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);
            
            int start, end;
            if (entry.get_selection_bounds(out start, out end)) {
                string selected_text = entry.get_text().substring(start, end - start);
                clipboard.set_text(selected_text, selected_text.length);
                clipboard.store();
                
                // Delete selected text
                entry.get_buffer().delete_text(start, end - start);
            }
        }

        void clipboard_paste() {
            var display = this.get_screen ().get_display ();
            var clipboard = Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);

            string text = clipboard.wait_for_text ();

            if (text != null) {
                int start, end;
                
                if (entry.get_selection_bounds(out start, out end)) {
                    entry.get_buffer().delete_text(start, end - start);
                    entry.get_buffer().insert_text(start, text.data);
                    entry.set_position(start + text.length); // if there's a selection, paste after it
                } else {
                    int pos = entry.cursor_position;
                    entry.get_buffer().insert_text(pos, text.data);
                    entry.set_position(pos + text.length); // if there's no selection, paste at cursor
                }
            }
        }
        
        void move_forward_word() {
            string text = entry.get_text();
            int pos = entry.get_position();
            bool found_word_break = false;
            
            for (int i = pos; i < text.length; i++) {
                unichar c = text.get_char(text.index_of_nth_char(i));
                if (c.isspace() || c.ispunct()) {
                    found_word_break = true;
                } else if (found_word_break) {
                    entry.set_position(text.index_of_nth_char(i));
                    return;
                }
            }
            
            entry.set_position(text.length);
        }
        
        void move_backward_word() {
            string text = entry.get_text();
            int pos = entry.get_position();
            bool found_word = false;
            
            for (int i = pos - 1; i >= 0; i--) {
                unichar c = text.get_char(text.index_of_nth_char(i));
                if (c.isspace() || c.ispunct()) {
                    found_word = true;
                    break;
                }
                pos = text.index_of_nth_char(i);
            }
        
            found_word = false;
            for (int i = pos - 1; i >= 0; i--) {
                unichar c = text.get_char(text.index_of_nth_char(i));
                if (!(c.isspace() || c.ispunct())) {
                    found_word = true;
                } else if (found_word) {
                    entry.set_position(text.index_of_nth_char(i+1));
                    return;
                }
            }
            entry.set_position(0);
        }

        private void scroll_help_window(bool scroll_down) {
            if (help_scrolled_window == null) {
                return;
            }
            
            var adjustment = scroll_down ? 
                help_scrolled_window.get_vadjustment() : 
                help_scrolled_window.get_vadjustment();
                
            double new_value;
            if (scroll_down) {
                new_value = double.min(
                    adjustment.get_value() + SCROLL_STEP,
                    adjustment.get_upper() - adjustment.get_page_size()
                );
            } else {
                new_value = double.max(
                    adjustment.get_value() - SCROLL_STEP,
                    adjustment.get_lower()
                );
            }
            
            adjustment.set_value(new_value);
        }

        public void quit() {
            if (seat != null)seat.ungrab ();
            hide ();
            close ();
        }
        
        public string get_wm_name() {
            return this.wm_name;
        }
    }
}
