using Gtk;

namespace Ilia {
    // Primary UI
    public class DialogWindow : Window, SessionContoller {
        public const int KEY_CODE_ESCAPE = 65307;
        public const int KEY_CODE_LEFT_ALT = 65513;
        public const int KEY_CODE_RIGHT_ALT = 65514;
        public const int KEY_CODE_UP = 65364;
        public const int KEY_CODE_DOWN = 65362;
        public const int KEY_CODE_ENTER = 65293;
        public const int KEY_CODE_PGDOWN = 65366;
        public const int KEY_CODE_PGUP = 65365;
        public const int KEY_CODE_RIGHT = 65363;
        public const int KEY_CODE_LEFT = 65361;
        public const int KEY_CODE_PLUS = 43;
        public const int KEY_CODE_MINUS = 45;
        public const int KEY_CODE_QUESTION = 63;

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

        private Gtk.TreeView keybinding_view;

        public DialogWindow (string focus_page, bool all_page_mode) {
            Object(type: Gtk.WindowType.POPUP); // Window is unmanaged
            window_position = WindowPosition.CENTER_ALWAYS;

            settings = new GLib.Settings ("org.regolith-linux.ilia");

            entry = new Gtk.Entry ();
            entry.get_style_context ().add_class ("filter_entry");
            entry.hexpand = true;
            entry.height_request = 36;

            entry.changed.connect (on_entry_changed);

            notebook = new Notebook ();
            notebook.get_style_context ().add_class ("notebook");
            notebook.set_tab_pos (PositionType.BOTTOM);            

            init_pages (focus_page, all_page_mode);

            grid = new Gtk.Grid ();
            grid.get_style_context ().add_class ("root_box");
            grid.attach (entry, 0, 0, 1, 1);
            grid.attach (notebook, 0, 1, 1, 1);
            add (grid);

            set_default_size (settings.get_int ("window-width"), settings.get_int ("window-height"));

            // Exit if focus leaves us
            focus_out_event.connect (() => {
                quit ();
                return false;
            });

            // Route keys based on function
            key_press_event.connect ((key) => {
                bool key_handled = false;                

                // Enable page nav keybindings in all page mode.
                if (all_page_mode && (key.state & Gdk.ModifierType.MOD1_MASK) == Gdk.ModifierType.MOD1_MASK) { //CTRL
                    for (int i = 0; i < total_pages; ++i) {
                        if (dialog_pages[i].get_keybinding() == key.keyval || (dialog_pages[i].get_keybinding() - 32) == key.keyval) {
                            // Allow both upper/lower case match
                            notebook.set_current_page (i);
                            return true;
                        }
                    }                    
                }

                switch (key.keyval) {
                    case KEY_CODE_ESCAPE:
                        quit ();
                        break;
                    case KEY_CODE_UP:
                    case KEY_CODE_DOWN:
                    case KEY_CODE_ENTER:
                    case KEY_CODE_PGDOWN:
                    case KEY_CODE_PGUP:
                        dialog_pages[active_page].grab_focus (key.keyval);
                        break;
                    case KEY_CODE_RIGHT:
                    case KEY_CODE_LEFT:
                        notebook.grab_focus ();
                        break;
                    case KEY_CODE_PLUS:
                        change_size(128);
                        key_handled = true;
                        break;
                    case KEY_CODE_MINUS:
                        change_size(-128);
                        key_handled = true;
                        break;
                    default:
                        // stdout.printf ("Keycode: %u\n", key.keyval);
                        if (!dialog_pages[active_page].key_event (key)) {
                            entry.grab_focus_without_selecting ();
                        }
                        break;
                }

                return key_handled;
            });

            entry.activate.connect (on_entry_activated);
            entry.grab_focus ();            
        }

        public override void show_all() {
            base.show_all();
            notebook.set_current_page ((int) active_page);
            notebook.switch_page.connect (on_page_switch);
        }
        
        public void set_seat(Gdk.Seat seat) {
            this.seat = seat;
        }

        private void init_pages (string focus_page, bool all_page_mode) {            
            if (all_page_mode) {
                total_pages = create_all_pages(focus_page, ref active_page);
            } else {
                total_pages = 1;
                active_page = 0;
                create_page(focus_page);                
            }

            // Exit if unable to load active page
            if (dialog_pages[0] == null) {
                stderr.printf ("No page loaded, exiting\n");
                Process.exit (1);
            }

            // This allows for multiple page loads.  Until startup performance is addressed, only load one page.
            for (int i = 0; i < total_pages; ++i) {
                Gtk.Box box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                var label = new Label(null);
                label.set_markup (dialog_pages[i].get_name ());
                var image = new Image.from_icon_name (dialog_pages[i].get_icon_name (), Gtk.IconSize.BUTTON);
                var button = new Button ();
                button.set_can_focus (false);
                button.relief = ReliefStyle.NONE;
                button.add (image);
                int page = i;
                button.clicked.connect(() => {                    
                    notebook.set_current_page (page);
                });

                box.pack_start (button, false, false, 0);
                box.pack_start (label, false, false, 5);
                box.show_all ();
                notebook.append_page (dialog_pages[i].get_root (), box);
            }

            // FIXME - rework help UI to be consistent for both single and all page modes
            if (!all_page_mode) {
                // Create help page
                var help_label = new Label ("Help");
                var help_widget = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);

                var page_help_label = new Label(dialog_pages[0].get_help ());
                page_help_label.set_line_wrap (true);
                help_widget.pack_start(page_help_label, false, false, 5);

                var keybindings_title = new Label("Keybindings");
                keybindings_title.get_style_context ().add_class ("help_heading");
                help_widget.pack_start(keybindings_title, false, false, 5);

                keybinding_view = new TreeView ();
                setup_help_treeview (keybinding_view, dialog_pages[0].get_keybindings ());
                help_widget.pack_start(keybinding_view, false, false, 5);
                notebook.append_page (help_widget, help_label);
                keybinding_view.realize.connect (() => {
                    keybinding_view.columns_autosize ();
                });
            }
        }

        private void create_page(string focus_page) {            
            dialog_pages = new DialogPage[1];

            switch (focus_page.down ()) {
                case "apps":
                    dialog_pages[0] = new DesktopAppPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                case "terminal":
                    dialog_pages[0] = new CommandPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                case "notifications":
                    dialog_pages[0] = new RoficationPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                case "keybindings":
                    dialog_pages[0] = new KeybingingsPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                case "textlist":
                    dialog_pages[0] = new TextListPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                case "windows":
                    dialog_pages[0] = new WindowPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                case "tracker":
                    dialog_pages[0] = new TrackerPage ();
                    dialog_pages[0].initialize.begin (settings, entry, this);
                    break;
                default:
                    stderr.printf ("Unknown page type: %s\n", focus_page);
                    break;
            }
        }

        /**
         * Creates pages for all generally usable pages
         */
        private int create_all_pages(string focus_page, ref uint start_page) {
            int page_count = 6;
            dialog_pages = new DialogPage[page_count];

            dialog_pages[0] = new DesktopAppPage ();
            dialog_pages[0].initialize.begin (settings, entry, this);
            dialog_pages[1] = new CommandPage ();
            dialog_pages[1].initialize.begin (settings, entry, this);
            dialog_pages[2] = new RoficationPage ();
            dialog_pages[2].initialize.begin (settings, entry, this);
            dialog_pages[3] = new KeybingingsPage ();
            dialog_pages[3].initialize.begin (settings, entry, this);
            dialog_pages[4] = new WindowPage ();
            dialog_pages[4].initialize.begin (settings, entry, this);
            dialog_pages[5] = new TrackerPage ();
            dialog_pages[5].initialize.begin (settings, entry, this);
            // last page, help, will be initalized later in init

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
                default:
                    stderr.printf ("Unknown page type: %s\n", focus_page);
                    start_page = 0;
                    break;
            }

            return page_count;
        }

        private void setup_help_treeview (TreeView view, HashTable<string, string>? keybindings) {
            var listmodel = new Gtk.ListStore (2, typeof (string), typeof (string));
            view.set_model (listmodel);

            view.headers_visible = false;
            view.fixed_height_mode = true;
            view.enable_search = false;

            view.insert_column_with_attributes (-1, "Key", new CellRendererText (), "text", 0);
            view.insert_column_with_attributes (-1, "Function", new CellRendererText (), "text", 1);

            TreeIter iter;

            if (keybindings != null) {
                keybindings.foreach ((key, val) => {
                    TreeIter iter2;

                    listmodel.append (out iter2);
                    listmodel.set (iter2, 0, key, 1, val);
                });
            }

            listmodel.append (out iter);
            listmodel.set (iter, 0, "-", 1, "Decrease Dialog Size");

            listmodel.append (out iter);
            listmodel.set (iter, 0, "+", 1, "Increase Dialog Size");

            listmodel.append (out iter);
            listmodel.set (iter, 0, "↑ ↓", 1, "Change Selected Item");

            listmodel.append (out iter);
            listmodel.set (iter, 0, "Esc", 1, "Exit");
        }

        // Resize the dialog, bigger or smaller
        void change_size(int delta) {
            int width, height;
            get_size(out width, out height);

            width += delta;
            height += delta;

            // Ignore changes past min bounds
            if (width < MIN_WINDOW_WIDTH || height < MIN_WINDOW_HEIGHT) return;

            resize (width, height);

            settings.set_int("window-width", width);
            settings.set_int("window-height", height);
        }

        void on_page_switch (Widget? page, uint page_num) {
            if (page_num == total_pages) { // On help page
                entry.set_sensitive (false);
            } else if (dialog_pages[page_num] != null) {
                active_page = page_num;
                
                entry.secondary_icon_name = dialog_pages[active_page].get_icon_name ();
                entry.set_sensitive (true);
            }
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            dialog_pages[active_page].on_entry_changed ();
        }

        void on_entry_activated () {
            dialog_pages[active_page].on_entry_activated ();
        }

        public void quit() {
            if (seat != null) seat.ungrab ();
            hide ();
            close ();
        }
    }
}