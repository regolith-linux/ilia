namespace Ilia {
    /**
     * Implement prev/next item for emacs and vim bindings
     *
     * returns true if key entry was handled
     */
     public static bool handle_emacs_vim_nav(Gtk.TreeView item_view, Gtk.TreePath path, Gdk.EventKey key) {
        if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) { //CTRL
            bool is_last = selection_is_last (item_view.get_selection ());

            if (key.keyval == 'p' || key.keyval == 'k') {
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

    public static bool selection_is_last (Gtk.TreeSelection selection) {
        Gtk.TreeModel model;
        Gtk.TreeIter iter;
        if (selection.get_selected(out model, out iter)) {
            return !model.iter_next(ref iter);
        }
        return false;
    }

    /*
     * Get the location for swaymsg or i3-msg as per the current session type
     */
    string? get_wm_cli(string wm_name) {
        if (wm_name == "i3") {
            return "/usr/bin/i3-msg ";
        } else if (wm_name == "sway") {
            return "/usr/bin/swaymsg ";
        }
        return null;
    }
}