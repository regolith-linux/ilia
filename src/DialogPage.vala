using Gtk;

namespace Ilia {
    // A DialogPage represents a filtered, sorted view for the global search entry upon some domain.
    interface DialogPage {
        // Initialize the page. Create widgets, load model data, etc.
        public abstract Gtk.Widget initialize (GLib.Settings settings, Gtk.Entry entry);

        // Set focus on page's primary widget
        public abstract void grab_focus ();

        // Cause the top item to be selected in the view
        public abstract void set_selection ();

        public abstract void on_entry_changed ();

        public abstract void on_entry_activated ();
    }
}