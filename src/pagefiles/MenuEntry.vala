namespace Ilia {
    /**
     * What choosing a menu row does
     */
    public enum MenuEntryKind {
        // Opens a submenu of more entries (the Entries key)
        SUBMENU,
        // Runs a binding of the window manager, by its description (the Binding key)
        BINDING,
        // Runs a command (the Exec key)
        EXEC
    }

    /**
     * An entry of a menu defined in a page file: the group [Entry <id>]
     *
     * Its keys:
     *  - Name: the row's text, as plain text (required)
     *  - Icon: the row's icon; without it the page's icon
     *  - exactly one of Entries (the ids of the submenu's entries), Binding (the description of
     *    a binding, "Action" or "Category // Action", as the keybindings page shows it) and
     *    Exec (a command line, split into words as a shell does, with %% for a literal %)
     *  - When: a command line; the row is shown only once it has exited with status 0
     *  - State: a command line; its first line, on/true/1 or off/false/0, is shown as On or Off
     *  - OnlyShowIn, NotShowIn: the window managers the row is shown under (i3, sway, other)
     */
    public class MenuEntry : GLib.Object {
        public const string GROUP_PREFIX = "Entry ";

        public string id { get; private set; }
        // The key file group that describes the entry
        public string group { get; private set; }
        // Plain text
        public string name { get; set; default = ""; }
        // The icon name, or null for the page's icon
        public string ? icon { get; set; default = null; }
        public MenuEntryKind kind { get; set; default = MenuEntryKind.EXEC; }
        // SUBMENU: the usable entries, in the order listed
        public MenuEntry[] children = {};
        // BINDING: the description, as written
        public string ? binding { get; set; default = null; }
        // EXEC: the program and its arguments
        public string[] ? exec_argv = null;
        // The entry has a When key: it is shown only if the condition succeeds
        public bool has_condition { get; set; default = false; }
        // The words of When; null if there is none, or it could not be split (then it never succeeds)
        public string[] ? when_argv = null;
        // The words of State; null if there is none, or it could not be split
        public string[] ? state_argv = null;
        // Window manager names, lower case
        public string[] only_show_in = {};
        public string[] not_show_in = {};

        public MenuEntry (string id) {
            this.id = id;
            this.group = GROUP_PREFIX + id;
        }

        /**
         * True if the row is shown under the window manager (sway, i3 or other), as far as
         * OnlyShowIn and NotShowIn decide
         */
        public bool is_shown_under(string wm_name) {
            return PageFile.wm_lists_allow(only_show_in, not_show_in, wm_name);
        }

        /**
         * Split a command line into words, as a shell does, without running a shell
         *
         * @throws ShellError if the line is blank or cannot be split
         */
        public static string[] parse_command(string command_line) throws ShellError {
            string[] argv;
            Shell.parse_argv(command_line, out argv);
            return argv;
        }

        /**
         * The words of an Exec key: split as a shell does, then %% becomes %; there is no other substitution
         */
        public static string[] parse_exec(string command_line) throws ShellError {
            string[] argv = {};
            foreach (unowned string word in parse_command(command_line))
                argv += word.replace("%%", "%");
            return argv;
        }

        /**
         * The on/off text for the first line a State command printed: "On" for on, true and 1,
         * "Off" for off, false and 0, in any letter case and with blank space around; else null
         */
        public static string ? state_text(string ? first_line) {
            if (first_line == null)
                return null;
            switch (first_line.strip().ascii_down()) {
                case "on":
                case "true":
                case "1":
                    return "On";
                case "off":
                case "false":
                case "0":
                    return "Off";
                default:
                    return null;
            }
        }

        /**
         * Whether a binding with this category and action is the one a Binding value names
         *
         * The value is "Action" or "Category // Action". Letter case is ignored, as are spaces
         * around each // and at either end.
         */
        public static bool binding_matches(string value, string category, string action) {
            string[] parts = value.split("//");
            string wanted_action;
            if (parts.length == 1) {
                wanted_action = parts[0];
            } else if (parts.length == 2) {
                if (!same_text(parts[0], category))
                    return false;
                wanted_action = parts[1];
            } else {
                return false;
            }
            return same_text(wanted_action, action);
        }

        private static bool same_text(string a, string b) {
            return a.strip().casefold() == b.strip().casefold();
        }
    }
}
