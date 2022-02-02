using Gtk;

namespace Ilia {
    // A DialogPage represents a filtered, sorted view for the global search entry upon some domain.
    interface DialogPage : GLib.Object {
        // Initialize the page. Create widgets, load model data, etc.
        public async abstract void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error;

        public abstract Gtk.Widget get_root ();

        // Set focus on page's primary widget, pass key(s) that caused event
        public abstract void grab_focus (Gdk.EventKey event_key);

        // Cause the top item to be selected in the view
        public abstract void set_selection ();

        // Occurs when entry text contents have changed
        public abstract void on_entry_changed ();

        // Occurs when 'enter' is pressed on the selected item
        public abstract void on_entry_activated ();

        // The name of the page
        public abstract string get_name ();

        // Name of icon to load that represents the page
        public abstract string get_icon_name ();

        // Pass key event to a page.  Page returns true if key was handled.
        public abstract bool key_event(Gdk.EventKey event_key);
    }
}