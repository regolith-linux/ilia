namespace Ilia {
    /**
     * Implement prev/next item for emacs and vim bindings
     *
     * returns true if key entry was handled
     */
    public static bool handle_emacs_vim_nav(Gtk.TreeView item_view, Gtk.TreePath path, Gdk.EventKey key) {
        if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) { // CTRL
            bool is_last = selection_is_last(item_view.get_selection ());

            if (key.keyval == 'p' || key.keyval == 'k') {
                path.prev ();
                item_view.get_selection ().select_path(path);
                item_view.set_cursor(path, null, false);
                return true;
            } else if ((key.keyval == 'n' || key.keyval == 'j') && !is_last) {
                path.next ();
                item_view.get_selection ().select_path(path);
                item_view.set_cursor(path, null, false);
                return true;
            }
        }

        return false;
    }

    public static bool selection_is_last(Gtk.TreeSelection selection) {
        Gtk.TreeModel model;
        Gtk.TreeIter iter;
        if (selection.get_selected(out model, out iter))
            return !model.iter_next(ref iter);
        return false;
    }

    /*
     * Get the location for swaymsg or i3-msg as per the current session type
     */
    public static string ? get_wm_cli(string wm_name) {
        if (wm_name == "i3")
            return "/usr/bin/i3-msg ";
        else if (wm_name == "sway")
            return "/usr/bin/swaymsg ";
        return null;
    }

    /* Get AppInfo object used to run a command */
    public static AppInfo get_runner_app_info(AppInfo app_info) throws GLib.Error {
        string systemd_run_path = GLib.Environment.find_program_in_path("systemd-run");
        if (systemd_run_path == null)
            return app_info;
        string app_id = app_info.get_id ();
        stdout.printf("KG2: \nbefore: '%s'\nafter : '%s'\n", app_id, systemd_escape(app_id));
        stdout.flush();
        string exec = app_info.get_commandline ();
        string random_suffix = Uuid.string_random ().slice(0, 8);
        string unit_name = "run_ilia_" + systemd_escape(app_id) + "_" + random_suffix + ".scope";
        string systemd_launch = "systemd-run --user --scope --unit \"" + unit_name + "\" " + exec;
        return AppInfo.create_from_commandline(systemd_launch, app_id, AppInfoCreateFlags.NONE);
    }

    /*
     * The escaping algorithm operates as follows: 
     * given a string, any "/" character is replaced by "-", and all other characters which 
     * are not ASCII alphanumerics, ":", "_" or "." are replaced by C-style "\x2d" escapes. 
     * In addition, "." is replaced with such a C-style escape when it would appear 
     * as the first character in the escaped string.
     * 
     * When the input qualifies as absolute file system path, this algorithm is extended 
     * slightly: the path to the root directory "/" 
     * is encoded as single dash "-". 
     * In addition, any leading, trailing or duplicate "/" characters are removed from the string before 
     * transformation. Example: /foo//bar/baz/ becomes "foo-bar-baz".
     * - systemd.unit.5.en
     */
    public static string systemd_escape(string unescaped) {
        var escaped = new StringBuilder();
        
        if (unescaped.data[0] == '.') {
            escaped.append("\\x2e");
        } else {
            escaped.append_c(unescaped.@get(0));
        }

        for (int i = 1; i < unescaped.length; ++i) {
            uint8 c = unescaped.data[i];
       
            if (
                (c > 31 && c < 46) || 
                (c > 58 && c < 65) || 
                (c > 90 && c < 97 && c != 95) || 
                (c > 122)) {    // escape
                escaped.append_printf("\\x%llx", c);
            } else {                                                        // copy
                escaped.append_c(unescaped.@get(i));
            }
        }

        return escaped.str.replace("/", "-");
    }
}
