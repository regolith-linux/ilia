using Gtk;
using GtkLayerShell;

/**
 * Application entry point
 */
public static int main(string[] args) {
    Gtk.Application app = new Ilia.Application ();

    app.run(args);
    return 0;
}

errordomain ArgParser {
    PARSE_ERROR
}
