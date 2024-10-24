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

errordomain ArgParser {
    PARSE_ERROR
}
