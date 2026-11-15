/**
 * Ilia module contracts
 */
namespace Ilia {
    /**
     * Represents actions and state that DialogPage types may access from the active session.
     */
    public interface SessionContoller : GLib.Object {

        // Exit the app
        public abstract void quit();

        // While shared, ilia lets go of the keyboard and pointer so another window can take them, as the
        // authorisation prompt of a package change must; unshared, ilia takes them back
        public abstract void share_input(bool shared);
    }

    /**
     * A DialogPage represents a filtered, sorted view for the global search entry upon some domain.
     */
    interface DialogPage : GLib.Object {
        /**
         * Initialize the page. Create widgets, load model data, etc.
         */
        public async abstract void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error;

        /**
         * Return the root widget of the page
         */
        public abstract Gtk.Widget get_root();

        /**
         * Event is called on page when contents of Entry has changed
         */
        public abstract void on_entry_changed();

        /**
         * Called on page when the Entry widget is selected
         */
        public abstract void on_entry_activated();

        /**
         * Name of page
         */
        public abstract string get_name();

        /**
         * Name of icon to render with page title
         */
        public abstract string get_icon_name();

        /**
         * Provides some details for how the page is used
         */
        public abstract string get_help();

        /**
         * Provides all keybindings tha the page implements
         */
        public abstract HashTable<string, string> ? get_keybindings();

        /**
         * Pass key event to a page.  Page returns true if key was handled.
         */
        public abstract bool key_event(Gdk.EventKey event_key);

        /**
         * Page returns character that should cause the page to be selected if pressed
         */
        public abstract char get_keybinding();

        /**
         * Called after initialize completes. Used for final UI state setup post model load.
         */
        public abstract void show();

        /**
         * Called on Escape. Page returns true if it handled the key, and the dialog stays open; false to exit.
         */
        public virtual bool cancel() {
            return false;
        }

        /**
         * Page returns true while it needs the dialog to stay open when the focus leaves it, as when it
         * waits for a change that may ask for authorisation in a window of its own.
         */
        public virtual bool keeps_open() {
            return false;
        }
    }
}
