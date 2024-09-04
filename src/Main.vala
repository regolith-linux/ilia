using Gtk;
using GtkLayerShell;

// Globals
bool IS_SESSION_WAYLAND;
string WM_NAME;
// Default style
char* default_css = """
                .root_box {
                    margin: 8px;
                }

                window {
                    border-style: dotted;
                    border-width: 1px;
                }

                .filter_entry {
                    border: none;
                    background: none;
                    min-height: 36px;
                    min-width: 320px;
                }

                .notebook {
                    border: none;
                }

                .keybindings {
                    font-family: monospace;
                }
            """;

/**
 * Application entry point
 */
public static int main (string[] args) {
    Gtk.Application app = new Ilia.Application ();

    // Get session type (wayland or x11) and set the flag
    string session_type = Environment.get_variable ("XDG_SESSION_TYPE");
    string gdk_backend = Environment.get_variable ("GDK_BACKEND");
    IS_SESSION_WAYLAND = session_type == "wayland" && gdk_backend != "x11";

    // Set window manager
    string sway_sock = Environment.get_variable ("SWAYSOCK");
    string i3_sock = Environment.get_variable ("I3SOCK");

    if (sway_sock != null) {
        WM_NAME = "sway";
    } else if (i3_sock != null) {
        WM_NAME = "i3";
    } else {
        WM_NAME = "Unknown";
    }

    app.run (args);
    return 0;
}


/*
   Get the location for swaymsg or i3-msg as per the current session type
 */
string? get_wm_cli() {
    if(WM_NAME == "i3") {
        return "/usr/bin/i3-msg ";
    } else if (WM_NAME == "sway") {
        return "/usr/bin/swaymsg ";
    }
    return null;
}


/* Get AppInfo object used to run a command */
public AppInfo get_runner_app_info (AppInfo app_info) throws GLib.Error {
    string systemd_run_path = GLib.Environment.find_program_in_path ("systemd-run");
    if (systemd_run_path == null) {
      return app_info;
    }
    string app_id = app_info.get_id ();
    string exec = app_info.get_commandline ();
    string random_suffix = Uuid.string_random ().slice (0, 8);
    string unit_name = "run_ilia_" + app_id + "_" + random_suffix + ".scope";

    string escaped_unit_name;
    try {
      string escape_launch = "systemd-escape \"" + unit_name + "\"";
      if(!Process.spawn_command_line_sync(escape_launch, out escaped_unit_name)) {
        escaped_unit_name = unit_name;
      }
    } catch (SpawnError e) {
      escaped_unit_name = unit_name;
    }

    string systemd_launch = "systemd-run --user --scope --unit "+ escaped_unit_name + " " + exec;
    return AppInfo.create_from_commandline (systemd_launch, app_id, AppInfoCreateFlags.NONE);
}

errordomain ArgParser {
    PARSE_ERROR
}
