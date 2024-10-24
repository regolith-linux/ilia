namespace Ilia {
    public const int KEY_CODE_ESCAPE = 65307;
    public const int KEY_CODE_LEFT_ALT = 65513;
    public const int KEY_CODE_RIGHT_ALT = 65514;
    public const int KEY_CODE_SUPER = 65515;
    public const int KEY_CODE_UP = 65364;
    public const int KEY_CODE_DOWN = 65362;
    public const int KEY_CODE_ENTER = 65293;
    public const int KEY_CODE_PGDOWN = 65366;
    public const int KEY_CODE_PGUP = 65365;
    public const int KEY_CODE_RIGHT = 65363;
    public const int KEY_CODE_LEFT = 65361;
    public const int KEY_CODE_PLUS = 43;
    public const int KEY_CODE_MINUS = 45;
    public const int KEY_CODE_QUESTION = 63;

    public const int KEY_CODE_PRINTSRC = 65377;
    public const int KEY_CODE_BRIGHT_UP = 269025026;
    public const int KEY_CODE_BRIGHT_DOWN = 269025027;
    public const int KEY_CODE_MIC_MUTE = 269025202;
    public const int KEY_CODE_VOLUME_UP = 269025043;
    public const int KEY_CODE_VOLUME_DOWN = 269025041;
    public const int KEY_CODE_VOLUME_MUTE = 269025042;

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
            } else if ((key.keyval == 'n' || key.keyval == 'j') && !is_last) {
                path.next ();
                item_view.get_selection ().select_path(path);
                item_view.set_cursor(path, null, false);
            }

            return true;
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
    public AppInfo get_runner_app_info(AppInfo app_info) throws GLib.Error {
        string systemd_run_path = GLib.Environment.find_program_in_path("systemd-run");
        if (systemd_run_path == null)
            return app_info;
        string app_id = app_info.get_id ();
        string exec = app_info.get_commandline ();
        string random_suffix = Uuid.string_random ().slice(0, 8);
        string unit_name = "run_ilia_" + app_id + "_" + random_suffix + ".scope";
        string systemd_launch = "systemd-run --user --scope --unit " + unit_name + " " + exec;
        return AppInfo.create_from_commandline(systemd_launch, app_id, AppInfoCreateFlags.NONE);
    }
}