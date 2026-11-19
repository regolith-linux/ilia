/**
 * Application entry point
 *
 * The program itself only reads the command line and talks to the background copy of the
 * launcher; everything that needs GTK is in the ui module, loaded when this process shows a
 * window itself or becomes the background copy. Loading the toolkit takes longer than the
 * background copy needs to show a window.
 */
public static int main(string[] args) {
    // The environment the call was made in
    string[] environ = Environ.get();
    var arg_map = Ilia.CommandLine.parse_args(args);

    // Help and version are printed here, without any other launcher process
    if (arg_map.contains("-h") || arg_map.contains("--help")) Ilia.CommandLine.print_help_and_exit();
    if (arg_map.contains("-v") || arg_map.contains("--version")) Ilia.CommandLine.print_version_and_exit();

    if (arg_map.contains(Ilia.RESIDENT_ARGUMENT))
        return run_resident(args, environ);

    // A background copy exists only while the setting is on, and checks it for each call. Pages it
    // does not answer only close the window it shows, if any.
    int status;
    string ? fatal_error;
    if (Ilia.ResidentClient.answer(args, environ, out status, out fatal_error)) {
        if (fatal_error != null)
            error("%s", fatal_error);
        return status;
    }

    status = run_ui(args, -1);

    // The window has closed: leave a background copy for the next call, unless the session has one
    if (Ilia.is_resident_page(arg_map) && Ilia.resident_mode_enabled())
        Ilia.start_resident_in_background(args[0], environ);
    return status;
}

// The background copy of the launcher, for the session of its environment
static int run_resident(string[] args, string[] environ) {
    var socket = Ilia.bind_resident_socket(environ);
    if (socket == null)
        return 0;     // The session has one already

    // Output for a call that is no longer connected must not end the process. A handler, unlike
    // ignoring the signal, does not carry over to the programs it starts
    Posix.signal(Posix.Signal.PIPE, (signum) => {});

    string[] ui_args = { args[0] };
    int status = run_ui(ui_args, socket.fd);
    // The socket stays open while the background copy runs
    socket = null;
    return status;
}

[CCode(has_target = false)]
delegate int UiMain(string[] args, int resident_socket);

/*
 * Load the ui module and run it. It is looked for next to the program, as in the build
 * directory, then where it is installed.
 */
static int run_ui(string[] args, int resident_socket) {
    string path = Path.build_filename(Constants.PKGLIBDIR, "ilia-ui.so");
    try {
        string local = Path.build_filename(Path.get_dirname(FileUtils.read_link("/proc/self/exe")), "ilia-ui.so");
        if (FileUtils.test(local, FileTest.EXISTS))
            path = local;
    } catch (FileError e) {
    }

    var module = Module.open(path, ModuleFlags.LAZY);
    void * symbol = null;
    if (module == null || !module.symbol("ilia_ui_main", out symbol) || symbol == null) {
        stderr.printf("Cannot load %s: %s\n", path, Module.error());
        return 1;
    }
    // GTK cannot be unloaded
    module.make_resident();

    UiMain ui_main = (UiMain) symbol;
    return ui_main(args, resident_socket);
}

errordomain ArgParser {
    PARSE_ERROR
}
