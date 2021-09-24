using Gtk;

namespace Ilia {

    Gtk.TreeView view;
    Gtk.ListStore list_store;
    Gtk.TreeIter iter;
    Gtk.TreeModelFilter filter;
    Gtk.IconTheme icon_theme;

    public class DialogWindow : Window {

        private int width = 490;
        private int height = 460;

        Gtk.Entry entry;

        public DialogWindow () {
            entry = new Gtk.Entry ();
            entry.hexpand = true;
            entry.height_request = 36;
            entry.set_placeholder_text ("Search");
            entry.primary_icon_name = "edit-find";
            entry.secondary_icon_name = "edit-clear";
            entry.secondary_icon_activatable = true;
            entry.icon_press.connect ((position, event) => {
                if (position == Gtk.EntryIconPosition.SECONDARY) {
                    entry.text = "";
                }
            });
            entry.changed.connect (on_entry_changed);
            entry.activate.connect (on_entry_activated);

            icon_theme = Gtk.IconTheme.get_default ();

            list_store = new Gtk.ListStore (4, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (string));
            load_apps ();

            filter = new Gtk.TreeModelFilter (list_store, null);
            filter.set_visible_func (filter_func);
            view = new Gtk.TreeView.with_model (filter);

            view.insert_column_with_attributes (-1, "Icon", new CellRendererPixbuf (), "pixbuf", 0);
            view.insert_column_with_attributes (-1, "Application", new CellRendererText (), "text", 1);
            view.set_activate_on_single_click (true);
            view.row_activated.connect (on_row_activated);

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (view);
            scrolled.expand = true;
            var grid = new Gtk.Grid ();
            grid.attach (entry, 0, 0, 1, 1);
            grid.attach (scrolled, 0, 1, 1, 1);

            add (grid);
            set_decorated (false);
            set_resizable (false);
            set_keep_above (true);
            set_property ("skip-taskbar-hint", true);
            set_default_size (width, height);
            stick ();
            focus_out_event.connect (() => {
                action_quit ();
                return false;
            });

            this.key_press_event.connect ((key) => {
                if (key.keyval == 65307) action_quit ();

                return false;
            });

            entry.grab_focus ();
        }

        void on_entry_changed () {
            filter.refilter ();
        }

        void on_entry_activated () {
            filter.get_iter_first (out iter);
            GLib.Value val;
            filter.get_value (iter, 3, out val);
            // var model = new Dlauncher.Model();
            // model.spawn_command((string)val);
            action_quit ();
        }

        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            GLib.Value exec;

            filter.get_iter (out iter, path);
            filter.get_value (iter, 3, out exec);
            spawn_command ((string) exec);
        }

        public void action_quit () {
            hide ();
            close ();
        }

        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string search = entry.get_text ().down ();
            if (search != "") {
                GLib.Value val;
                string strval;
                list_store.get_value (iter, 2, out val);
                strval = val.get_string ();
                if (strval.contains (search) == false) {
                    list_store.get_value (iter, 3, out val);
                    strval = val.get_string ();
                }
                return strval.contains (search);
            } else {
                return true;
            }
        }

        private async void load_apps () {
            var system_app_dir = File.new_for_path ("/usr/share/applications");
            if (system_app_dir.query_exists ()) yield load_apps_from_dir (system_app_dir);

            /*  var home_dir = File.new_for_path (Environment.get_home_dir ());
               var user_app_dir = home_dir.get_child(".applications");
               if (user_app_dir.query_exists()) yield load_apps_from_dir(user_app_dir);  */
        }

        private async void load_apps_from_dir (File app_dir) {
            try {
                var enumerator = yield app_dir.enumerate_children_async (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT);

                while (true) {
                    var app_files = yield enumerator.next_files_async (10, Priority.DEFAULT);

                    if (app_files == null) {
                        break;
                    }

                    foreach (var info in app_files) {
                        string file_path = app_dir.get_child (info.get_name ()).get_path ();
                        read_desktop_file (file_path);
                    }
                }
            } catch (Error err) {
                stderr.printf ("Error: list_files failed: %s\n", err.message);
            }
        }

        private void read_desktop_file (string desktopPath) {
            DesktopAppInfo app_info = new DesktopAppInfo.from_filename (desktopPath);
            if (app_info != null) {
                list_store.append (out iter);

                var icon = app_info.get_icon ();
                string icon_name = null;
                if (icon != null) icon_name = icon.to_string ();
                list_store.set (iter, 0, load_icon (icon_name, 32), 1, app_info.get_name (), 2, "comment", 3, "/usr/bin/gnome-terminal");
            }
        }

        private Gdk.Pixbuf ? load_icon (string ? icon_name, int size) {
            Gtk.IconInfo icon_info;

            try {
                if (icon_name == null) {
                    icon_info = icon_theme.lookup_icon ("application-x-executable", size, Gtk.IconLookupFlags.FORCE_SIZE);
                    return icon_info.load_icon ();
                }

                icon_info = icon_theme.lookup_icon (icon_name, size, Gtk.IconLookupFlags.FORCE_SIZE); // from icon theme
                if (icon_info != null) {
                    return icon_info.load_icon ();
                }

                if (GLib.File.new_for_path (icon_name).query_exists ()) {
                    try {
                        return new Gdk.Pixbuf.from_file_at_size (icon_name, size, size);
                    } catch (Error e) {
                        stderr.printf ("%s\n", e.message);
                    }
                }

                try {
                    icon_info = icon_theme.lookup_icon ("application-x-executable", size, Gtk.IconLookupFlags.FORCE_SIZE);
                    return icon_info.load_icon ();
                } catch (Error e) {
                    stderr.printf ("%s\n", e.message);
                }
            } catch (Error e) {
                stderr.printf ("%s\n", e.message);
            }

            return null;
        }

        private void spawn_command (string item) {
            try {
                Process.spawn_command_line_async (item);
            } catch (GLib.Error e) {
                stderr.printf ("%s\n", e.message);
            }
        }
    }
}