namespace Ilia {
    /**
     * What the pages defined in files have in common: name, icon and key come from the file
     */
    abstract class PageFilePage : GLib.Object, DialogPage {
        protected PageFile file;
        // The letter that selects the page with Alt, or 0
        private char keybinding;

        protected PageFilePage (PageFile file, char keybinding) {
            this.file = file;
            this.keybinding = keybinding;
        }

        // The name is plain text: escape it for the tab label, and underline the page's letter as the built-in pages do
        public string get_name() {
            unowned string name = file.name;
            int index = keybinding != 0 ? name.ascii_down().index_of_char(keybinding) : -1;
            if (index < 0)
                return Markup.escape_text(name);

            return Markup.escape_text(name.substring(0, index))
                   + "<u>" + Markup.escape_text(name.substring(index, 1)) + "</u>"
                   + Markup.escape_text(name.substring(index + 1));
        }

        public string get_icon_name() {
            return file.icon;
        }

        public char get_keybinding() {
            return keybinding;
        }

        public abstract async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error;

        public abstract Gtk.Widget get_root();

        public abstract void on_entry_changed();

        public abstract void on_entry_activated();

        public abstract string get_help();

        public abstract HashTable<string, string> ? get_keybindings();

        public abstract bool key_event(Gdk.EventKey event_key);

        public abstract void show();
    }
}
