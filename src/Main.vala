using Gtk;
using GtkLayerShell;

// Default style
char * default_css = """
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
public static int main(string[] args) {
    Gtk.Application app = new Ilia.Application ();

    app.run(args);
    return 0;
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

errordomain ArgParser {
    PARSE_ERROR
}
