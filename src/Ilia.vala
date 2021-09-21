using Gtk;

/**
 * Application entry point
 */
public static int main (string[] args) {
    Gtk.init (ref args);

    var window = new DialogWindow ();
    window.destroy.connect (Gtk.main_quit);
    window.show_all ();

    Gtk.main ();
    return 0;
}