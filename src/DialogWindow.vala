using Gtk;

namespace Ilia {
    // Primary UI
    public class DialogWindow : Window, SessionContoller {
        // Model constants
        private const int KEY_CODE_ESCAPE = 65307;
        private const int KEY_CODE_UP = 65364;
        private const int KEY_CODE_DOWN = 65362;
        private const int KEY_CODE_ENTER = 65293;
        private const int KEY_CODE_PGDOWN = 65366;
        private const int KEY_CODE_PGUP = 65365;
        private const int KEY_CODE_RIGHT = 65363;
        private const int KEY_CODE_LEFT = 65361;

        private DesktopAppPage desktopAppPage;

        // Mode switcher
        private Gtk.Notebook notebook;

        private Gtk.Entry entry;

        private GLib.Settings settings;

        public DialogWindow () {
            settings = new GLib.Settings ("org.regolith-linux.ilia");

            entry = new Gtk.Entry ();
            entry.hexpand = true;
            entry.height_request = 36;
            entry.set_placeholder_text ("Launch App");
            entry.primary_icon_name = "system-run";
            entry.secondary_icon_name = "edit-clear";
            entry.secondary_icon_activatable = true;
            entry.icon_press.connect ((position, event) => {
                if (position == Gtk.EntryIconPosition.SECONDARY) {
                    entry.text = "";
                }
            });
            entry.changed.connect (on_entry_changed);      
            

            desktopAppPage = new DesktopAppPage();
            var widget = desktopAppPage.initialize (settings, entry, this);

            entry.activate.connect (on_entry_activated);

            notebook = new Notebook ();
            notebook.set_show_border (true);
            notebook.set_tab_pos (PositionType.BOTTOM);
            var label = new Label (null);
            label.set_label ("Apps");
            notebook.append_page (widget, label);

            add_tab ("Commands", create_command_widget ());
            add_fake_tab ("Workspaces");
            add_fake_tab ("Keybindings");
            add_fake_tab ("Settings");

            var grid = new Gtk.Grid ();
            grid.attach (entry, 0, 0, 1, 1);
            grid.attach (notebook, 0, 1, 1, 1);
            add (grid);

            style_window (this, settings);

            // Exit if focus leaves us
            focus_out_event.connect (() => {
                stdout.printf("exit from lost focus\n");
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
                        desktopAppPage.grab_focus ();
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

            entry.grab_focus ();
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            desktopAppPage.on_entry_changed ();
        }

        void on_entry_activated () {
            desktopAppPage.on_entry_activated ();
        }

        // configure style of window
        private void style_window (DialogWindow window, GLib.Settings settings) {
            window.set_decorated (false);
            window.set_resizable (false);
            window.set_keep_above (true);
            window.set_property ("skip-taskbar-hint", true);

            window.set_default_size (settings.get_int ("window-width"), settings.get_int ("window-height"));
            window.stick ();
        }

        // exit
        public void action_quit () {
            hide ();
            close ();
        }

        public void hide_dialog () {
            hide ();
        }

        public void exit_app () {
            // close ();
        }

        private void add_fake_tab (string label) {
            var label2 = new Label (null);
            label2.set_label (label);
            var button2 = new Button.with_label ("Some Content");
            notebook.append_page (button2, label2);
        }

        private void add_tab (string label, Widget child) {
            var label2 = new Label (null);
            label2.set_label (label);
            notebook.append_page (child, label2);
        }

        // here is where we're at adapting the existing desktop app UI for commands
        private Widget create_command_widget () {
            var command_model = new Gtk.ListStore (2, typeof (string), typeof (string));
            // model.set_sort_column_id (1, SortType.ASCENDING);
            // model.set_sort_func (1, app_sort_func);

            // load_apps.begin ();

            //var command_filter = new Gtk.TreeModelFilter (model, null);
            //filter.set_visible_func (filter_func);

            var command_item_view = new Gtk.TreeView.with_model (command_model);

            // Do not show column headers
            command_item_view.headers_visible = false;

            // Optimization
            command_item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            command_item_view.enable_search = false;

            // Launch app on one click
            command_item_view.set_activate_on_single_click (true);

            // Launch app on row selection
             // command_item_view.row_activated.connect (on_row_activated);


            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (command_item_view);
            scrolled.expand = true;

            return scrolled;
            // return new Button.with_label ("Some Content");
        }
    }
}