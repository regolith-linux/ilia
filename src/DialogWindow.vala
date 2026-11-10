using Gtk;

namespace Ilia {
    public const int KEY_CODE_ESCAPE = 65307;
    public const int KEY_CODE_LEFT_ALT = 65513;
    public const int KEY_CODE_RIGHT_ALT = 65514;
    public const int KEY_CODE_SUPER = 65515;
    public const int KEY_CODE_SUPER_R = 65516;
    public const int KEY_CODE_UP = 65364;
    public const int KEY_CODE_DOWN = 65362;
    public const int KEY_CODE_ENTER = 65293;
    public const int KEY_CODE_KP_ENTER = 65421;
    public const int KEY_CODE_PGDOWN = 65366;
    public const int KEY_CODE_PGUP = 65365;
    public const int KEY_CODE_HOME = 65360;
    public const int KEY_CODE_END = 65367;
    public const int KEY_CODE_KP_HOME = 65429;
    public const int KEY_CODE_KP_END = 65436;
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

        // The last page: describes the page shown before it
        private HelpPage help_page;

        private string wm_name;
        private bool is_wayland;

        // The desktop's layout-switch shortcuts; on X11 ilia switches the layout itself, as its keyboard grab keeps them from the desktop
        private InputSourceSwitcher ? layout_switcher = null;
        // Super was pressed as part of a layout-switch shortcut; exit if it is released on its own
        private bool exit_on_super_release = false;
        // On X11, hands the keys ilia does not use to i3's bindings or to the desktop, as its keyboard grab keeps them from both
        private X11KeyForwarder ? key_forwarder = null;
        // On sway, which runs its bindings while ilia is open: ilia closes when one runs
        private SwayBindingWatcher ? binding_watcher = null;

        public DialogWindow (HashTable<string, string ?> arg_map, bool is_wayland_session, string wm_name) {
            Object(type: Gtk.WindowType.POPUP); // Window is unmanaged
            window_position = WindowPosition.CENTER_ALWAYS;

            this.wm_name = wm_name;
            this.is_wayland = is_wayland_session;

            settings = new GLib.Settings("org.regolith-linux.ilia");

            entry = new Gtk.Entry();
            entry.get_style_context().add_class("filter_entry");
            entry.hexpand = true;
            entry.button_press_event.connect((event) => {
                // Disable context menu as causes de-focus event to exit execution
                return event.button == 3; // squelch right button click event
            });

            entry.changed.connect(on_entry_changed);

            notebook = new Notebook();
            notebook.get_style_context().add_class("notebook");
            notebook.set_tab_pos(PositionType.BOTTOM);

            var focus_page = arg_map.get("-p") ?? "Apps";
            bool all_page_mode = arg_map.contains("-a");

            init_pages(arg_map, focus_page, all_page_mode);

            grid = new Gtk.Grid();
            grid.get_style_context().add_class("root_box");
            grid.attach(entry, 0, 0, 1, 1);
            grid.attach(notebook, 0, 1, 1, 1);
            add(grid);

            if (is_wayland_session)
                set_size_request(settings.get_int("window-width"), settings.get_int("window-height"));
            else
                set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));


            // Exit if focus leaves us
            focus_out_event.connect(() => {
                // Removing the seat's last keyboard (one wtype run, a virtual or Bluetooth keyboard going away) also
                // takes keyboard focus on Wayland, though it went nowhere; the next keyboard to appear focuses ilia again
                if (is_wayland && !seat_has_keyboard())
                    return false;
                quit();
                return false;
            });

            layout_switcher = InputSourceSwitcher.from_settings(Gdk.Keymap.get_for_display(get_display()));

            if (!is_wayland && wm_name != "sway") {
                key_forwarder = new X11KeyForwarder(get_display(), wm_name == "i3");
                key_forwarder.release_input.connect(release_input);
                key_forwarder.finished.connect(() => close());
            } else if (wm_name == "sway") {
                try {
                    binding_watcher = new SwayBindingWatcher();
                    // sway has already acted; just get out of the way of the result
                    binding_watcher.binding_run.connect(() => quit());
                } catch (GLib.Error e) {
                    stderr.printf("Unable to follow the bindings of sway: %s\n", e.message);
                }
            }

            // Route keys based on function
            key_press_event.connect((key) => {
                if (layout_switcher != null && !is_wayland) {
                    int direction = layout_switcher.match(key.keyval, keyval_in_first_layout(key), key.state);
                    if (direction != 0) {
                        exit_on_super_release = false;
                        layout_switcher.switch_source.begin(direction);
                        return true;
                    }
                    if (exit_on_super_release && key.is_modifier == 0) { // Super did not start a layout switch after all
                        exit_on_super_release = false;
                        // The key goes on to i3, as if Super had closed ilia when it was pressed
                        if (key_forwarder == null || !key_forwarder.key_pressed(key))
                            quit();
                        return true;
                    }
                }

                if (key_forwarder != null && !is_own_key(key) && key_forwarder.key_pressed(key))
                    return true;

                if ((key.state & Gdk.ModifierType.MOD1_MASK) == Gdk.ModifierType.MOD1_MASK) { // ALT
                    // Enable page nav keybindings in all page mode.
                    int page = page_of_letter(key.keyval);
                    if (page >= 0) {
                        notebook.set_current_page(page);
                        return true;
                    }
                    if (key.keyval == '+') { // Expand dialog
                        change_size(128);
                        return true;
                    }
                    if (key.keyval == '-') { // Contract dialog
                        change_size(-128);
                        return true;
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
                        if (pos < entry.text.char_count())
                            entry.set_position(pos + 1);
                        return true;
                    }
                    if (key.keyval == 'j' || key.keyval == 'n') { // Down - vim/emacs style
                        bool key_handled = dialog_pages[active_page].key_event(key);
                        return key_handled;
                    }
                    if (key.keyval == 'k' || key.keyval == 'p') { // Up - vim/emacs style
                        bool key_handled = dialog_pages[active_page].key_event(key);
                        return key_handled;
                    }
                    if (key.keyval == '0') { // Beginning of line - vim style
                        entry.set_position(0);
                        return true;
                    }
                    if (key.keyval == Gdk.Key.dollar) { // End of line (Ctrl+$) - vim style
                        entry.set_position(-1);
                        return true;
                    }
                    if (key.keyval == 'a') { // Select all - like Ctrl+A
                        entry.select_region(0, -1);
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
                        case KEY_CODE_ESCAPE: // Explicit exit
                            quit();
                            break;
                        case KEY_CODE_SUPER:
                        case KEY_CODE_SUPER_R: // Explicit exit, unless Super is pressed to complete a held layout-switch shortcut
                            if (layout_switcher != null && layout_switcher.super_starts_shortcut(key.state)) {
                                // On Wayland the compositor takes the rest of the shortcut, so ilia never sees it
                                exit_on_super_release = !is_wayland;
                                break;
                            }
                            quit();
                            break;
                        case KEY_CODE_BRIGHT_UP:
                        case KEY_CODE_BRIGHT_DOWN:
                        case KEY_CODE_MIC_MUTE:
                        case KEY_CODE_VOLUME_UP:
                        case KEY_CODE_VOLUME_DOWN:
                        case KEY_CODE_VOLUME_MUTE:
                        case KEY_CODE_PRINTSRC: // Implicit exit
                            quit();
                            break;
                        case KEY_CODE_UP:
                        case KEY_CODE_DOWN:
                        case KEY_CODE_PGDOWN:
                        case KEY_CODE_HOME:
                        case KEY_CODE_END:
                        case KEY_CODE_KP_HOME:
                        case KEY_CODE_KP_END:
                        case KEY_CODE_PGUP: // Let UI handle these nav keys
                            dialog_pages[active_page].show();
                            break;
                        case KEY_CODE_ENTER:
                        case KEY_CODE_KP_ENTER: // Let the page accept typed text that matches no item, else activate the selected item
                            key_handled = dialog_pages[active_page].key_event(key);
                            if (!key_handled)
                                dialog_pages[active_page].show();
                            break;
                        case KEY_CODE_RIGHT:
                        case KEY_CODE_LEFT: // Switch pages
                            notebook.grab_focus();
                            break;
                        default:            // Pass key event to active page for handling
                            key_handled = dialog_pages[active_page].key_event(key);
                            if (!key_handled)
                                entry.grab_focus_without_selecting();  // causes entry to consume all unhandled key events
                            break;
                }

                return key_handled;
            });

            key_release_event.connect((key) => {
                if (key_forwarder != null && key_forwarder.key_released(key))
                    return true;
                if (exit_on_super_release && is_super_key(key.keyval))
                    quit();
                return false;
            });

            entry.activate.connect(on_entry_activated);

            dialog_pages[active_page].show();  // Get page ready to use
        }

        public override void show_all() {
            base.show_all();
            notebook.set_current_page((int) active_page);
            notebook.switch_page.connect(on_page_switch);
        }

        /**
         * True for the keys that ilia uses itself, which never go to the window manager:
         * Escape, Enter (without Super), list and page navigation, Backspace and Delete with any
         * modifiers; ilia's Control and Alt combinations; Super; and keys that type a character.
         */
        private bool is_own_key(Gdk.EventKey key) {
            bool control = (key.state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool alt = (key.state & Gdk.ModifierType.MOD1_MASK) != 0;
            bool super = (key.state & Gdk.ModifierType.SUPER_MASK) != 0;

            switch (key.keyval) {
                case KEY_CODE_ESCAPE:
                case KEY_CODE_SUPER:
                case KEY_CODE_SUPER_R:
                case KEY_CODE_UP:
                case KEY_CODE_DOWN:
                case KEY_CODE_PGUP:
                case KEY_CODE_PGDOWN:
                case KEY_CODE_HOME:
                case KEY_CODE_END:
                case KEY_CODE_KP_HOME:
                case KEY_CODE_KP_END:
                case KEY_CODE_LEFT:
                case KEY_CODE_RIGHT:
                case Gdk.Key.BackSpace:
                case Gdk.Key.Delete:
                    return true;
                case KEY_CODE_ENTER:
                case KEY_CODE_KP_ENTER:
                    return !super;
                default:
                    break;
            }

            if (control && !alt && !super) {
                switch (key.keyval) {
                    case 'h': case 'l': case 'j': case 'k': case 'n': case 'p': case '0':
                    case 'a': case 'w': case 'b': case 'c': case 'v': case 'x':
                    case Gdk.Key.dollar:
                        return true;
                    default:
                        return false;
                }
            }

            if (alt && !control && !super) {
                if (key.keyval == KEY_CODE_PLUS || key.keyval == KEY_CODE_MINUS)
                    return true;
                return page_of_letter(key.keyval) >= 0;
            }

            if (!control && !alt && !super) {
                unichar typed = Gdk.keyval_to_unicode(key.keyval);
                return typed != 0 && !typed.iscntrl();
            }

            return false;
        }

        // The page that Alt and the key selects, upper or lower case, or -1
        private int page_of_letter(uint keyval) {
            uint lower = Gdk.keyval_to_lower(keyval);
            for (int i = 0; i < total_pages; ++i) {
                char page_key = dialog_pages[i].get_keybinding();
                if (page_key != 0 && lower == page_key)
                    return i;
            }
            return -1;
        }

        // The key of a key event as it is in the first layout
        private uint keyval_in_first_layout(Gdk.EventKey key) {
            uint keyval;
            int effective_group, level;
            Gdk.ModifierType consumed;

            var keymap = Gdk.Keymap.get_for_display(get_display());
            if (keymap.translate_keyboard_state(key.hardware_keycode, key.state, 0, out keyval, out effective_group, out level, out consumed))
                return keyval;
            return key.keyval;
        }

        private bool seat_has_keyboard() {
            var default_seat = get_display().get_default_seat();
            return default_seat != null && default_seat.get_slaves(Gdk.SeatCapabilities.KEYBOARD).length() > 0;
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

            // The help page comes last, in both modes, and is a page like the others
            help_page = new HelpPage(dialog_pages);
            help_page.initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            dialog_pages += help_page;
            total_pages = dialog_pages.length;

            // This allows for multiple page loads.  Until startup performance is addressed, only load one page.
            for (int i = 0; i < total_pages; ++i) {
                Gtk.Box box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
                var label = new Label(null);
                label.set_markup(dialog_pages[i].get_name());
                var image = new Image.from_icon_name(dialog_pages[i].get_icon_name(), Gtk.IconSize.BUTTON);
                var button = new Button();
                button.set_can_focus(false);
                button.relief = ReliefStyle.NONE;
                button.add(image);
                int page = i;
                button.clicked.connect(() => {
                    notebook.set_current_page(page);
                });

                box.pack_start(button, false, false, 0);
                box.pack_start(label, false, false, 5);
                box.show_all();
                notebook.append_page(dialog_pages[i].get_root(), box);
            }
        }

        // The built-in pages that -a shows, in their order
        private const string[] ALL_PAGES_BUILTIN = { "apps", "terminal", "notifications", "keybindings", "windows", "tracker" };

        // The keybindings and windows pages need i3 or sway; the other built-in pages work under any window manager
        private bool is_builtin_page_shown(string page_id) {
            if (page_id == "keybindings" || page_id == "windows")
                return wm_name == "i3" || wm_name == "sway";
            return true;
        }

        private DialogPage ? new_builtin_page(string page_id) {
            switch (page_id) {
                case "apps":
                    return new DesktopAppPage();
                case "terminal":
                    return new CommandPage();
                case "notifications":
                    return new RoficationPage();
                case "keybindings":
                    return new KeybingingsPage();
                case "textlist":
                    return new TextListPage();
                case "windows":
                    return new WindowPage();
                case "tracker":
                    return new TrackerPage();
                default:
                    return null;
            }
        }

        // A page for a page file, using key as its letter (0 for none)
        private DialogPage new_file_page(PageFile file, char key) {
            if (file.source == PageSource.APPS)
                return new PageFileAppsPage(file, key);
            return new PageFileTextPage(file, key);
        }

        private DialogPage begin_page(DialogPage page, HashTable<string, string ?> arg_map) {
            page.initialize.begin(settings, arg_map, entry, this, this.wm_name, this.is_wayland);
            return page;
        }

        // The page exists, but not under this window manager: no window is shown
        private void exit_page_not_available(string page_name) {
            stderr.printf("ilia: page '%s' is not available under the current window manager\n", page_name);
            Process.exit(1);
        }

        private void create_page(string focus_page, HashTable<string, string ?> arg_map) {
            dialog_pages = new DialogPage[1];
            string page_id = focus_page.down();

            if (PageFile.is_builtin_page(page_id)) {
                if (!is_builtin_page_shown(page_id))
                    exit_page_not_available(focus_page);
                // The page files are read, and problems with them reported, whichever page is opened
                PageFile.load_all();
                // Null if this build leaves the page out
                var page = new_builtin_page(page_id);
                if (page != null)
                    dialog_pages[0] = begin_page(page, arg_map);
            } else if (PageFile.is_valid_id(focus_page)) {
                foreach (var file in PageFile.load_all()) {
                    if (file.id.ascii_down() != focus_page.ascii_down())
                        continue;
                    if (!file.is_shown_under(wm_name))
                        exit_page_not_available(focus_page);
                    dialog_pages[0] = begin_page(new_file_page(file, file.key), arg_map);
                    break;
                }
            }

            if (dialog_pages[0] == null)
                stderr.printf("Unknown page type: %s\n", focus_page);
        }

        /**
         * Creates pages for all generally usable pages: the built-in ones that work under the
         * window manager, then those from page files that are shown under it, by file name
         */
        private int create_all_pages(HashTable<string, string ?> arg_map, string focus_page, ref uint start_page) {
            DialogPage[] pages = {};
            string[] page_ids = {};
            // The letters of the pages so far: the first page to claim a letter keeps it
            string used_keys = "";

            foreach (unowned string page_id in ALL_PAGES_BUILTIN) {
                if (!is_builtin_page_shown(page_id))
                    continue;
                var page = begin_page(new_builtin_page(page_id), arg_map);
                pages += page;
                page_ids += page_id;
                used_keys += page.get_keybinding().to_string();
            }

            bool focus_exists = PageFile.is_builtin_page(focus_page);
            foreach (var file in PageFile.load_all()) {
                focus_exists = focus_exists || file.id.ascii_down() == focus_page.ascii_down();
                if (!file.is_shown_under(wm_name))
                    continue;

                char key = file.key;
                if (key != 0 && used_keys.index_of_char(key) >= 0) {
                    stderr.printf("ilia: page file '%s': the letter of Key '%c' is already used by another page, ignoring it\n", file.path, key);
                    key = 0;
                }
                if (key != 0)
                    used_keys += key.to_string();

                pages += begin_page(new_file_page(file, key), arg_map);
                page_ids += file.id.ascii_down();
            }
            // last page, help, will be initialized later in init
            dialog_pages = pages;

            // Start on the page asked for, if it is shown
            start_page = 0;
            for (int i = 0; i < page_ids.length; ++i) {
                if (page_ids[i] == focus_page.down())
                    start_page = i;
            }
            if (!focus_exists)
                stderr.printf("Unknown page type: %s\n", focus_page);

            return pages.length;
        }

        // Resize the dialog, bigger or smaller
        void change_size(int delta) {
            int width, height;
            get_size(out width, out height);

            width += delta;
            height += delta;

            // Ignore changes past min bounds
            if (width < MIN_WINDOW_WIDTH || height < MIN_WINDOW_HEIGHT) return;

            var monitor = this.get_screen().get_display().get_monitor(0);    // Assume first monitor
            if (monitor != null) {
                var geometry = monitor.get_geometry();

                if (width >= geometry.width || height >= geometry.height) return;
            }

            // On Wayland the window is sized by its size request, which is also its minimum size
            if (is_wayland)
                set_size_request(width, height);
            resize(width, height);

            settings.set_int("window-width", width);
            settings.set_int("window-height", height);
        }

        void on_page_switch(Widget ? page, uint page_num) {
            if (page_num >= total_pages || dialog_pages[page_num] == null)
                return;

            if (dialog_pages[page_num] == help_page) {
                // Describe the page the user comes from; there is nothing to filter
                if (active_page != page_num)
                    help_page.describe(dialog_pages[active_page]);
                active_page = page_num;
                entry.set_sensitive(false);
            } else {
                active_page = page_num;
                entry.set_sensitive(true);
                dialog_pages[active_page].on_entry_changed();
            }
            dialog_pages[active_page].show();
        }

        // filter selection based on contents of Entry
        void on_entry_changed() {
            dialog_pages[active_page].on_entry_changed();
        }

        void on_entry_activated() {
            dialog_pages[active_page].on_entry_activated();
        }

        void clipboard_copy() {
            var display = this.get_screen().get_display();
            var clipboard = Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);

            int start, end;
            if (entry.get_selection_bounds(out start, out end)) {
                string selected_text = substring_chars(entry.get_text(), start, end);
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
                string selected_text = substring_chars(entry.get_text(), start, end);
                clipboard.set_text(selected_text, selected_text.length);
                clipboard.store();

                // Delete selected text
                entry.get_buffer().delete_text(start, end - start);
            }
        }

        void clipboard_paste() {
            var display = this.get_screen().get_display();
            var clipboard = Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);

            // Don't wait for the text: wait_for_text() runs a nested main loop until the clipboard
            // owner answers, and an owner that hangs keeps ilia running for up to two minutes.
            clipboard.request_text((clipboard, text) => {
                if (text == null)
                    return;

                int start, end;

                if (entry.get_selection_bounds(out start, out end))
                    entry.get_buffer().delete_text(start, end - start);
                entry.insert_at_cursor(text);
            });
        }

        void move_forward_word() {
            entry.set_position(next_word_start(entry.get_text(), entry.get_position()));
        }

        void move_backward_word() {
            entry.set_position(previous_word_start(entry.get_text(), entry.get_position()));
        }

        // Give up the keyboard and pointer and hide, and wait until the X server has done so
        private void release_input() {
            if (seat != null) {
                seat.ungrab();
                seat = null;
            }
            hide();
            get_display().sync();
        }

        public void quit() {
            release_input();
            close();
        }
    }
}
