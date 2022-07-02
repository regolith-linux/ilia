using Gtk;
using GtkLayerShell;

// Globals
bool IS_SESSION_WAYLAND;
string WM_NAME;

/**
 * Application entry point
 */
public static int main (string[] args) {
    Gtk.init (ref args);

    // Get session type (wayland or x11) and set the flag
    string session_type = Environment.get_variable ("XDG_SESSION_TYPE");
    string gdk_backend = Environment.get_variable ("GDK_BACKEND");
    IS_SESSION_WAYLAND = session_type == "wayland" && gdk_backend != "x11";

    // Set window manager
    string sway_sock = Environment.get_variable ("SWAYSOCK");
    string i3_sock = Environment.get_variable ("I3SOCK");

    if(sway_sock != null) {
        WM_NAME = "sway";
    } else if(i3_sock != null) {
        WM_NAME = "i3";
    } else {
        WM_NAME = "Unknown";
    }

    var arg_map = parse_args (args);
    if (arg_map.contains ("-h") || arg_map.contains ("--help")) print_help_and_exit ();

    var window = new Ilia.DialogWindow (arg_map);
    window.destroy.connect (Gtk.main_quit); 
    
    // Grab inputs from wayland backend
    if(IS_SESSION_WAYLAND) {
        GtkLayerShell.init_for_window(window);
        GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.EXCLUSIVE);
    } else {
    }

    initialize_style (window, arg_map);
    window.show_all ();

    if (!IS_SESSION_WAYLAND) {
        Gdk.Window gdkwin = window.get_window ();
        var seat = grab_inputs (gdkwin);
        if(seat == null) {
            stderr.printf ("Failed to aquire access to input devices, aborting.");
            return 1;
        }
        window.set_seat (seat);
    }

    // Handle mouse clicks by determining if a click is in or out of bounds
    // If we get a mouse click out of bounds of the window, exit.
    window.button_press_event.connect ((event) => {
        int window_width = 0, window_height = 0;
        window.get_size (out window_width, out window_height);

        int mouse_x = (int) event.x;
        int mouse_y = (int) event.y;

        var click_out_bounds = ((mouse_x < 0 || mouse_y < 0) || (mouse_x > window_width || mouse_y > window_height));

        if (click_out_bounds) {
            window.quit ();
        }

        return !click_out_bounds;
    });

    Gtk.main ();
    return 0;
}

private void initialize_style (Gtk.Window window, HashTable<string, string ? > arg_map) {
    try {
        if (arg_map.contains ("-t") && arg_map.get ("-t") != null) {
            var file = File.new_for_path (arg_map.get ("-t"));

            if (!file.query_exists ()) {
                printerr ("File '%s' does not exist.\n", file.get_path ());
                Process.exit (1);
            }
            Gtk.CssProvider css_provider = new Gtk.CssProvider ();
            css_provider.load_from_file (file);

            Gtk.StyleContext.add_provider_for_screen (Gdk.Screen.get_default (), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER);
        } else if (!arg_map.contains ("-n")) {
            string default_css = """
                .root_box {
                    margin: 8px;
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
            Gtk.CssProvider css_provider = new Gtk.CssProvider ();
            css_provider.load_from_data (default_css);

            Gtk.StyleContext.add_provider_for_screen (Gdk.Screen.get_default (), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER);
        }
    } catch (GLib.Error ex) {
        error ("Failed to initalize style: " + ex.message);
    }
}

// Grabs the input devices for a given window
// Some systems exhibit behavior such that keyboard / mouse cannot be reliably grabbed.
// As a workaround, this function will continue to attempt to grab these resources over an
// increasing time window and eventually give up and exit if ultimately unable to aquire
// the keyboard and mouse resources.
Gdk.Seat ? grab_inputs (Gdk.Window gdkwin) {
    var display = gdkwin.get_display (); // Gdk.Display.get_default();
    if (display == null) {
        stderr.printf ("Failed to get Display\n");
        return null;
    }

    var seat = display.get_default_seat ();
    if (seat == null) {
        stdout.printf ("Failed to get Seat from Display\n");
        return null;
    }

    int attempt = 0;
    Gdk.GrabStatus ? grabStatus = null;
    int wait_time = 1000;

    do {
        grabStatus = seat.grab (gdkwin, Gdk.SeatCapabilities.KEYBOARD | Gdk.SeatCapabilities.POINTER, true, null, null, null);
        if (grabStatus != Gdk.GrabStatus.SUCCESS) {
            attempt++;
            wait_time = wait_time * 2;
            GLib.Thread.usleep (wait_time);
        }
    } while (grabStatus != Gdk.GrabStatus.SUCCESS && attempt < 8);

    if (grabStatus != Gdk.GrabStatus.SUCCESS) {
        stderr.printf ("Aborting, failed to grab input: %d\n", grabStatus);
        return null;
    } else {
        return seat;
    }
}

void print_help_and_exit () {
    stdout.printf ("Usage: ilia [-t stylesheet] [-n] [-a] [-p page]\n");
    stdout.printf ("\n\t-t: specify path to custom stylesheet.\n");
    stdout.printf ("\n\t-n: no custom styles\n");
    stdout.printf ("\n\t-a: load all pages\n");
    stdout.printf ("\npages:\n");
    stdout.printf ("\t'apps' - launch desktop applications (default)\n");
    stdout.printf ("\t'terminal' - launch a terminal command\n");
    stdout.printf ("\t'notifications' - launch notifications manager\n");
    stdout.printf ("\t'keybindings' - launch keybindings viewer\n");
    stdout.printf ("\t'textlist' - select an item from a specified list\n");
    stdout.printf ("\t\t-l: page label\n");
    stdout.printf ("\t\t-i: page icon\n");
    stdout.printf ("\t'windows' - navigate to a window\n");
    stdout.printf ("\t'tracker' - search for files by content\n");
    Process.exit (0);
}

/**
 * Convert ["-v", "-s", "asdf", "-f", "qwe"] => {("-v", null), ("-s", "adsf"), ("-f", "qwe")}
 * Populates key of "cmd" with first arg.
 * NOTE: Currently does not support quoted parameter values.
 */
HashTable<string, string ? > parse_args (string[] args) {
    var arg_hashtable = new HashTable<string, string ? >(str_hash, str_equal);

    if (args == null || args.length == 0) {
        return arg_hashtable;
    }

    string last_key = null;
    foreach (string token in args) {
        if (!arg_hashtable.contains ("cmd")) {
            arg_hashtable.set ("cmd", token);
        } else if (is_key (token)) {
            if (last_key != null) {
                arg_hashtable.set (last_key, null);
            }
            last_key = token;
        } else if (last_key != null) {
            arg_hashtable.set (last_key, token);
            last_key = null;
        } else {
            // ignore
        }
    }

    if (last_key != null) { // Trailing single param
        arg_hashtable.set (last_key, null);
    }
    /*
       foreach (var key in arg_hashtable.get_keys ()) {
        stdout.printf ("%s => %s\n", key, arg_hashtable.lookup(key));
       }
     */

    return arg_hashtable;
}

errordomain ArgParser {
    PARSE_ERROR
}

bool is_key (string inval) {
    return inval.has_prefix ("-");
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
