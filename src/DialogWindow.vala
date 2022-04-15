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

        private const int TOTAL_PAGES = 1;
        // Reference to all active dialog pages
        private DialogPage[] dialog_pages;
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
        // Flag to track state of help visibility
        private bool _show_help;
        // Child of root_widget that displays help content
        private Gtk.Box help_widget = null;
        // root container
        private Gtk.Box root_box;

        public DialogWindow (string focus_page) {
            Object(type: Gtk.WindowType.POPUP); // Window is unmanaged
            window_position = WindowPosition.CENTER_ALWAYS;

            settings = new GLib.Settings ("org.regolith-linux.ilia");

            root_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
            add (root_box);        

            entry = new Gtk.Entry ();
            entry.hexpand = true;
            entry.height_request = 36;

            entry.changed.connect (on_entry_changed);

            notebook = new Notebook ();
            notebook.set_show_border (true);
            notebook.set_tab_pos (PositionType.BOTTOM);
            notebook.switch_page.connect (on_page_switch);

            init_pages (focus_page);

            grid = new Gtk.Grid ();
            grid.attach (entry, 0, 0, 1, 1);
            grid.attach (notebook, 0, 1, 1, 1);
            root_box.pack_start (grid, true, true, 0);

            set_default_size (settings.get_int ("window-width"), settings.get_int ("window-height"));

            _show_help = settings.get_boolean ("show-help");
            update_help ();

            // Exit if focus leaves us
            focus_out_event.connect (() => {
                quit ();
                return false;
            });

            // Route keys based on function
            key_press_event.connect ((key) => {
                bool key_handled = false;

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
                    case KEY_CODE_QUESTION:
                        toggle_help ();
                        update_help ();
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

        private void init_pages (string focus_page) {
            active_page = 0;
            dialog_pages = new DialogPage[TOTAL_PAGES];

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

            // Exit if unable to load active page
            if (dialog_pages[0] == null) {
                stderr.printf ("No page loaded, exiting\n");
                Process.exit (1);
            }

            // This allows for multiple page loads.  Until startup performance is addressed, only load one page.
            for (int i = 0; i < TOTAL_PAGES; ++i) {
                if (dialog_pages[i] != null) {
                    Gtk.Box box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                    var label = new Label (dialog_pages[i].get_name ());
                    var image = new Image.from_icon_name (dialog_pages[i].get_icon_name (), Gtk.IconSize.BUTTON);
                    var button = new Button ();
                    button.set_can_focus (false);
                    button.relief = ReliefStyle.NONE;
                    button.add (image);
                    box.pack_start (button, false, false, 0);
                    box.pack_start (label, false, false, 5);
                    box.show_all ();
                    notebook.append_page (dialog_pages[i].get_root (), box);
                }
            }

            on_page_switch (dialog_pages[active_page].get_root (), active_page);
        }

        void toggle_help() {
            _show_help = !_show_help;
            settings.set_boolean("show-help", _show_help);
        }

        void update_help() {
            if (_show_help) {
                if (help_widget != null) return;

                help_widget = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
                // help_widget.set_margin_right(10);
                root_box.add(help_widget) ;

                var l1 = new Label("Help");
                help_widget.pack_start(l1, false, false, 5);
                l1.show_all ();

                var keybinding_view = new TreeView ();
                setup_treeview (keybinding_view);
                help_widget.pack_start(keybinding_view, false, false, 5);
                keybinding_view.show_all ();

                /*
                help_widget = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
                help_widget.set_margin_right(10);
                root_box.add(help_widget) ;

                // help_widget = new Label("Help\n?: Toggle Help\n+: Increase Size\n-: Decrease Size");
                var l1 = new Label("Help");
                help_widget.pack_start(l1, false, false, 5);
                l1.show_all ();
                var l2 = new Label("?: Toggle Help");
                help_widget.pack_start(l2, false, false, 0);
                l2.show_all ();
                var l3 = new Label("+: Increase Size");
                help_widget.pack_start(l3, false, false, 0);
                l3.show_all ();
                var l4 = new Label("-: Decrease Size");
                help_widget.pack_start(l4, false, false, 0);
                l4.show_all ();
                 */

                help_widget.show_all();
            } else {
                if (help_widget == null) return;
                help_widget.destroy ();
                help_widget = null;
            }
        }
         
        private void setup_treeview (TreeView view) {

            /*
             * Use ListStore to hold accountname, accounttype, balance and
             * color attribute. For more info on how TreeView works take a
             * look at the GTK+ API.
             */
    
            var listmodel = new Gtk.ListStore (2, typeof (string), typeof (string));
            view.set_model (listmodel);

            view.headers_visible = false;
            view.fixed_height_mode = true;
            view.enable_search = false;
    
            view.insert_column_with_attributes (-1, "Key", new CellRendererText (), "text", 0);
            view.insert_column_with_attributes (-1, "Function", new CellRendererText (), "text", 1);
    
            TreeIter iter;
            listmodel.append (out iter);
            listmodel.set (iter, 0, "-", 1, "Decrease Size");
    
            listmodel.append (out iter);
            listmodel.set (iter, 0, "+", 1, "Increase Size");

            listmodel.append (out iter);
            listmodel.set (iter, 0, "?", 1, "Toggle Help");
        }

         /*
        void update_help() {
            if (_show_help) {
                if (help_widget != null) return;
                help_widget = new Label("Help\n?: Toggle Help\n+: Increase Size\n-: Decrease Size");
                root_box.pack_end(help_widget, false, false, 0);
                help_widget.show_all();
            } else {
                if (help_widget == null) return;
                help_widget.destroy ();
                help_widget = null;
            }
        }
         */

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

        void on_page_switch (Widget page, uint page_num) {
            active_page = page_num;

            entry.set_placeholder_text ("Launch " + dialog_pages[active_page].get_name ());
            entry.secondary_icon_name = dialog_pages[active_page].get_icon_name ();
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