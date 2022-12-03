using Gtk;

namespace Ilia {
    /**
     * A DialogPage represents a filtered, sorted view for the global search entry upon some domain.
     */
    interface DialogPage : GLib.Object {
        /**
         * Initialize the page. Create widgets, load model data, etc.
         */
        public async abstract void initialize (GLib.Settings settings, HashTable<string, string ? > arg_map, Gtk.Entry entry, SessionContoller sessionController) throws GLib.Error;

        /**
         * Return the root widget of the page
         */
        public abstract Gtk.Widget get_root ();

        /**
         * Event is called on page when contents of Entry has changed
         */
        public abstract void on_entry_changed ();

        /**
         * Called on page when the Entry widget is selected
         */
        public abstract void on_entry_activated ();

        /**
         * Name of page
         */
        public abstract string get_name ();

        /**
         * Name of icon to render with page title
         */
        public abstract string get_icon_name ();

        /**
         * Provides some details for how the page is used
         */
        public abstract string get_help ();

        /**
         * Provides all keybindings tha the page implements
         */
        public abstract HashTable<string, string>? get_keybindings();

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
        public abstract void show ();
    }

    /**
     * Implement prev/next item for emacs and vim bindings
     *
     * returns true if key entry was handled
     */
    public static bool handle_emacs_vim_nav(Gtk.TreeView item_view, Gtk.TreePath path, Gdk.EventKey key) {
        if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) { //CTRL
            bool is_last = selection_is_last (item_view.get_selection ());

            if (key.keyval == 'p') {
                path.prev ();
                item_view.get_selection ().select_path (path);
                item_view.set_cursor (path, null, false);
            } else if ((key.keyval == 'n' || key.keyval == 'j') && !is_last) {
                path.next ();
                item_view.get_selection ().select_path (path);
                item_view.set_cursor (path, null, false);
            }

            return true;
        }

        return false;
    }

    public static bool selection_is_last (TreeSelection selection) {
        TreeModel model;
        TreeIter iter;
        if (selection.get_selected(out model, out iter)) {
            return !model.iter_next(ref iter);
        }
        return false;
    }
}