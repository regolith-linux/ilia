/*
 * Entry point of the ui module, which holds everything that needs GTK
 *
 * The ilia program loads this module only when the process shows a window itself or
 * becomes the background copy: a call that the background copy answers starts much faster
 * without loading the toolkit at all.
 */

/**
 * Run the launcher in this process: show the window the arguments ask for, or, with a
 * listening socket from Ilia.bind_resident_socket(), serve the calls of the session as the
 * background copy. Returns when the window has closed or the background copy ends.
 */
[CCode(cname = "ilia_ui_main")]
public int ilia_ui_main(string[] args, int resident_socket) {
    if (resident_socket < 0) {
        Gtk.Application app = new Ilia.Application(Ilia.CommandLine.parse_args(args));
        app.run(args);
        return 0;
    }

    Ilia.ResidentServer server;
    try {
        server = new Ilia.ResidentServer(resident_socket);
    } catch (GLib.Error e) {
        return 1;
    }
    var app = new Ilia.Application.resident(server);
    string[] app_args = { args[0] };
    app.run(app_args);
    return 0;
}
