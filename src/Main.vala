using Gtk;
using GtkLayerShell;

/**
 * Application entry point
 */
public static int main(string[] args) {
    // ilia started by itself to keep text copied in it on the clipboard after it exits
    if (args.length == 3 && args[1] == Ilia.ClipboardKeeper.KEEP_ARGUMENT)
        return Ilia.ClipboardKeeper.serve(args[2]);

    Gtk.Application app = new Ilia.Application();

    app.run(args);
    return 0;
}

errordomain ArgParser {
    PARSE_ERROR
}
