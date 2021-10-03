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

        private const int TOTAL_PAGES = 2;

        private DialogPage[] dialog_pages;

        private uint active_page = 0;

        // Mode switcher
        private Gtk.Notebook notebook;

        private Gtk.Stack stack;

        private Gtk.Entry entry;

        private GLib.Settings settings;

        private Gtk.Grid grid;

        private Gtk.Spinner spinner;

        public DialogWindow () {
            settings = new GLib.Settings ("org.regolith-linux.ilia");

            stack = new Stack();
            stack.set_vexpand(true);
            stack.set_hexpand(true);
            add (stack);

            entry = new Gtk.Entry ();
            entry.hexpand = true;
            entry.height_request = 36;

            entry.changed.connect (on_entry_changed);      

            notebook = new Notebook ();
            notebook.set_show_border (true);
            notebook.set_tab_pos (PositionType.BOTTOM);
            notebook.switch_page.connect (on_page_switch);

            dialog_pages = new DialogPage[TOTAL_PAGES];

            var desktopAppPage = new DesktopAppPage();
            desktopAppPage.initialize.begin (settings, entry, this);
            dialog_pages[0] = desktopAppPage;

            // TODO offload initialization of non-primary pages to background
            var commandPage = new CommandPage();
            commandPage.initialize.begin (settings, entry, this);
            dialog_pages[1] = commandPage;

            for (int i = 0; i < TOTAL_PAGES; ++i) {
                if (dialog_pages[i] != null) {
                    Gtk.Box box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                    var label = new Label (dialog_pages[i].get_name ());
                    var image = new Image.from_icon_name(dialog_pages[i].get_icon_name (), Gtk.IconSize.BUTTON);
                    var button = new Button();
                    button.set_can_focus(false);
                    button.relief = ReliefStyle.NONE;
                    button.add(image);
                    box.pack_start(button, false, false, 0);
                    box.pack_start(label, false, false, 5);
                    box.show_all();
                    notebook.append_page (dialog_pages[i].get_root (), box);
                } 
            }
            
            on_page_switch(dialog_pages[active_page].get_root(), active_page);
            
            grid = new Gtk.Grid ();
            grid.attach (entry, 0, 0, 1, 1);
            grid.attach (notebook, 0, 1, 1, 1);
            stack.add_named(grid, "primary");

            spinner = new Spinner();
            stack.add_named(spinner, "spinner");

            set_decorated (false);
            set_resizable (false);
            set_keep_above (true);
            set_property ("skip-taskbar-hint", true);

            set_default_size (settings.get_int ("window-width"), settings.get_int ("window-height"));
            stick ();

            // Exit if focus leaves us
            focus_out_event.connect (() => {
                action_quit ();
                return false;
            });

            // Route keys based on function
            key_press_event.connect ((key) => {
                switch (key.keyval) {
                    case KEY_CODE_ESCAPE:
                        action_quit ();
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
                    default:
                        // stdout.printf ("Keycode: %u\n", key.keyval);
                        entry.grab_focus_without_selecting ();
                        break;
                }

                return false;
            });

            entry.activate.connect (on_entry_activated);
            entry.grab_focus ();
        }

        void on_page_switch(Widget page, uint page_num) {
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

        // exit
        public void action_quit () {
            hide ();
            close ();
        }

        public void launched () {
            stack.set_visible_child_name ("spinner");
            spinner.start ();
        }
    }
}