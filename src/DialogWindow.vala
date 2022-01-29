using Gtk;

namespace Ilia {
    // Primary UI
    public class DialogWindow : Window, SessionContoller {
        const int KEY_CODE_ESCAPE = 65307;
        const int KEY_CODE_UP = 65364;
        const int KEY_CODE_DOWN = 65362;
        public const int KEY_CODE_ENTER = 65293;
        const int KEY_CODE_PGDOWN = 65366;
        const int KEY_CODE_PGUP = 65365;
        const int KEY_CODE_RIGHT = 65363;
        const int KEY_CODE_LEFT = 65361;
        const int KEY_CODE_PLUS = 43;
        const int KEY_CODE_MINUS = 45;

        const int MIN_WINDOW_WIDTH = 160;
        const int MIN_WINDOW_HEIGHT = 100;

        private const int TOTAL_PAGES = 2;
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

        protected Gdk.Seat seat;

        public DialogWindow (string focus_page) {
            Object(type: Gtk.WindowType.POPUP); // Window is unmanaged
            window_position = WindowPosition.CENTER_ALWAYS;

            settings = new GLib.Settings ("org.regolith-linux.ilia");

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
                    stderr.printf ("Unknown page type %s, aborting.\n", focus_page);
                    break;
            }

            // Exit if unable to load active page
            if (dialog_pages[0] == null) Process.exit (1);

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