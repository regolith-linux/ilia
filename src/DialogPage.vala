using Gtk;

namespace Ilia {
    // A DialogPage represents a filtered, sorted view for the global search entry upon some domain.
    interface DialogPage : GLib.Object {
        // Initialize the page. Create widgets, load model data, etc.
        public async abstract void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController);

        public abstract Gtk.Widget get_root ();

        // Set focus on page's primary widget
        public abstract void grab_focus (uint keycode);

        // Cause the top item to be selected in the view
        public abstract void set_selection ();

        public abstract void on_entry_changed ();

        public abstract void on_entry_activated ();

        public abstract string get_name ();

        public abstract string get_icon_name ();
    }
}