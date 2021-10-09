using Gtk;

/**
 * Application entry point
 */
public static int main (string[] args) {
    Gtk.init (ref args);

    var arg_map = parse_args (args);
    var focus_page = arg_map.get("-p") ?? "Apps";

    var window = new Ilia.DialogWindow (focus_page);
    
    window.destroy.connect (Gtk.main_quit);
    window.show_all ();

    Gtk.main ();
    return 0;
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