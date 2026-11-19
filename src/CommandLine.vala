namespace Ilia {
    /**
     * The command line: its options, and the help and version it prints. This needs no toolkit:
     * a call answered by the background copy only reads its arguments.
     */
    public class CommandLine {
        public static void print_help_and_exit() {
            stdout.printf("Usage: ilia [-t stylesheet] [-n] [-a] [-p page]\n");
            stdout.printf("\n\t-t: specify path to custom stylesheet.\n");
            stdout.printf("\n\t-n: no custom styles\n");
            stdout.printf("\n\t-a: load all pages\n");
            stdout.printf("\npages:\n");
            stdout.printf("\t'apps' - launch desktop applications (default)\n");
            stdout.printf("\t'terminal' - launch a terminal command\n");
            stdout.printf("\t\t-q: quiet execution\n");
            stdout.printf("\t'notifications' - launch notifications manager\n");
            stdout.printf("\t'keybindings' - launch keybindings viewer\n");
            stdout.printf("\t'textlist' - select an item from a specified list\n");
            stdout.printf("\t\t-l: page label\n");
            stdout.printf("\t\t-i: page/item icon\n");
            stdout.printf("\t\t-n: no icon\n");
            stdout.printf("\t'windows' - navigate to a window\n");
            stdout.printf("\t'tracker' - search for files by content\n");
            Process.exit(0);
        }

        public static void print_version_and_exit() {
            stdout.printf("ilia version 0.19\n");
            Process.exit(0);
        }

        /**
         * Convert ["-v", "-s", "asdf", "-f", "qwe"] => {("-v", null), ("-s", "adsf"), ("-f", "qwe")}
         * Populates key of "cmd" with first arg.
         * NOTE: Currently does not support quoted parameter values.
         */
        public static HashTable<string, string ?> parse_args(string[] args) {
            var arg_hashtable = new HashTable<string, string ?>(str_hash, str_equal);

            if (args == null || args.length == 0)
                return arg_hashtable;

            string last_key = null;
            foreach (string token in args) {
                if (!arg_hashtable.contains("cmd")) {
                    arg_hashtable.set("cmd", token);
                } else if (is_key(token)) {
                    if (last_key != null)
                        arg_hashtable.set(last_key, null);
                    last_key = token;
                } else if (last_key != null) {
                    arg_hashtable.set(last_key, token);
                    last_key = null;
                } else {
                    // ignore
                }
            }

            if (last_key != null)   // Trailing single param
                arg_hashtable.set(last_key, null);
            /*
               foreach (var key in arg_hashtable.get_keys ()) {
                stdout.printf ("%s => %s\n", key, arg_hashtable.lookup(key));
               }
             */

            return arg_hashtable;
        }

        static bool is_key(string inval) {
            return inval.has_prefix("-");
        }
    }
}
