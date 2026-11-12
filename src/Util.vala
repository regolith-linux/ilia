namespace Ilia {
    /**
     * Implement prev/next item for emacs and vim bindings
     *
     * returns true if key entry was handled
     */
    public static bool handle_emacs_vim_nav(Gtk.TreeView item_view, Gtk.TreePath path, Gdk.EventKey key) {
        if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) { // CTRL
            // The arrow keys and the mouse move the selection without updating path: start from the selected row
            Gtk.TreeModel model;
            Gtk.TreeIter iter;
            if (item_view.get_selection().get_selected(out model, out iter))
                move_path_to(path, model.get_path(iter));

            bool is_last = selection_is_last(item_view.get_selection());

            if (key.keyval == 'p' || key.keyval == 'k') {
                path.prev();
                item_view.get_selection().select_path(path);
                item_view.set_cursor(path, null, false);
                return true;
            } else if ((key.keyval == 'n' || key.keyval == 'j') && !is_last) {
                path.next();
                item_view.get_selection().select_path(path);
                item_view.set_cursor(path, null, false);
                return true;
            }
        }

        return false;
    }

    /**
     * Move path, in place, to the row at target among the same siblings
     *
     * The pages keep their path between key events, so it is updated rather than replaced.
     */
    public static void move_path_to(Gtk.TreePath path, Gtk.TreePath target) {
        while (path.compare(target) < 0)
            path.next();
        while (path.compare(target) > 0 && path.prev()) {}
    }

    /**
     * Move path, in place, to the last row of model if it points past the end, as after
     * the last row was removed. A path in an empty model is left alone.
     */
    public static void clamp_path_to_rows(Gtk.TreePath path, Gtk.TreeModel model) {
        int rows = model.iter_n_children(null);
        if (rows > 0 && path.get_indices()[0] >= rows)
            move_path_to(path, new Gtk.TreePath.from_indices(rows - 1));
    }

    public static bool selection_is_last(Gtk.TreeSelection selection) {
        Gtk.TreeModel model;
        Gtk.TreeIter iter;
        if (selection.get_selected(out model, out iter))
            return !model.iter_next(ref iter);
        return false;
    }

    /**
     * Highlight the first row of the view and move path, in place, to it
     *
     * For a new filter text, whose best match comes first. The arrow keys and Ctrl+n/p move
     * the view's cursor, and when the filter hides that row GTK highlights a neighbouring row,
     * not the first match.
     */
    public static void select_first_row(Gtk.TreeView item_view, Gtk.TreePath path) {
        move_path_to(path, new Gtk.TreePath.first());

        Gtk.TreeIter iter;
        var model = item_view.get_model();
        if (model != null && model.get_iter_first(out iter))
            item_view.set_cursor(path, null, false); // also selects the row and scrolls to it
    }

    /**
     * True for the keys that act on the selection: Return and the keypad Enter
     */
    public static bool is_enter_key(uint keyval) {
        return keyval == KEY_CODE_ENTER || keyval == KEY_CODE_KP_ENTER;
    }

    /**
     * True for the Super keys, left and right
     */
    public static bool is_super_key(uint keyval) {
        return keyval == KEY_CODE_SUPER || keyval == KEY_CODE_SUPER_R;
    }

    /**
     * True for the D-Bus signals that announce a suspend or a screen lock: logind's
     * PrepareForSleep(true) and the screensaver's ActiveChanged(true)
     */
    public static bool is_sleep_or_lock_signal(string interface_name, string signal_name, Variant parameters) {
        bool is_sleep = interface_name == "org.freedesktop.login1.Manager" && signal_name == "PrepareForSleep";
        bool is_lock = interface_name == "org.gnome.ScreenSaver" && signal_name == "ActiveChanged";
        if (!(is_sleep || is_lock) || !parameters.is_of_type(new VariantType("(b)")))
            return false;

        bool starting;
        parameters.get("(b)", out starting);
        return starting;
    }

    /*
     * Get the location for swaymsg or i3-msg as per the current session type
     */
    public static string ? get_wm_cli(string wm_name) {
        if (wm_name == "i3")
            return "/usr/bin/i3-msg ";
        else if (wm_name == "sway")
            return "/usr/bin/swaymsg ";
        return null;
    }

    /*
     * Get AppInfo object used to run a command line, as the commands page builds it
     *
     * The command is started in its own systemd scope. Desktop entries are launched
     * with get_desktop_launch_argv() instead, which keeps what the entry asks for.
     */
    public static AppInfo get_runner_app_info(AppInfo app_info) throws GLib.Error {
        string systemd_run_path = GLib.Environment.find_program_in_path("systemd-run");
        if (systemd_run_path == null)
            return app_info;
        string app_id = app_info.get_id();
        string exec = app_info.get_commandline();

        string systemd_launch = "systemd-run --user --scope --unit \"" + systemd_scope_unit_name(app_id) + "\" " + exec;
        return AppInfo.create_from_commandline(systemd_launch, app_id, AppInfoCreateFlags.NONE);
    }

    /* A new name for the systemd scope an app is started in: run_ilia_<escaped id>_<random>.scope */
    public static string systemd_scope_unit_name(string app_id) {
        string random_suffix = Uuid.string_random().slice(0, 8);
        return "run_ilia_" + systemd_escape(app_id) + "_" + random_suffix + ".scope";
    }

    /* True if the desktop file asks to be run in a terminal (Terminal=true) */
    public static bool needs_terminal(AppInfo app_info) {
        var desktop_app_info = app_info as DesktopAppInfo;
        return desktop_app_info != null && desktop_app_info.get_filename() != null && desktop_app_info.get_boolean("Terminal");
    }

    /*
     * The program and arguments of a desktop entry, from its Exec key
     *
     * Field codes are expanded as the Desktop Entry Specification describes, for a
     * launch that opens no files: %f, %F, %u and %U expand to nothing, %i to --icon and
     * the Icon key (to nothing without one), %c to the name in the user's language, %k
     * to the file name of the desktop entry and %% to %. The deprecated codes expand to
     * nothing. As in GLib, each value is quoted before the command line is split, so it
     * stays literal and a single argument, also inside a longer one as in --class=%c.
     */
    public static string[] expand_desktop_exec(DesktopAppInfo app_info) throws ShellError {
        unowned string exec = app_info.get_commandline() ?? "";
        var command_line = new StringBuilder();

        for (int i = 0; i < exec.length; ++i) {
            if (exec[i] != '%' || i + 1 == exec.length) {
                command_line.append_c(exec[i]);
                continue;
            }

            switch (exec[++i]) {
                case 'i':
                    string ? icon = app_info.get_locale_string("Icon");
                    if (icon != null && icon != "")
                        command_line.append("--icon " + Shell.quote(icon));
                    break;
                case 'c':
                    command_line.append(Shell.quote(app_info.get_name()));
                    break;
                case 'k':
                    unowned string ? filename = app_info.get_filename();
                    if (filename != null)
                        command_line.append(Shell.quote(filename));
                    break;
                case '%':
                    command_line.append_c('%');
                    break;
                default: // No files to pass, and the deprecated field codes
                    break;
            }
        }

        string[] argv;
        Shell.parse_argv(command_line.str, out argv);
        return argv;
    }

    /*
     * The command that launches a desktop entry, as a program and its arguments
     *
     * The entry is started in its own systemd scope when systemd-run is available. For
     * Terminal=true the terminal is started inside the scope, as x-terminal-emulator -e
     * <program>, so the terminal and the program running in it share the scope; without
     * x-terminal-emulator such an entry is left to GLib. The command is meant to run in
     * the directory get_desktop_working_directory() gives.
     */
    public static string[] get_desktop_launch_argv(DesktopAppInfo app_info) throws ShellError {
        string[] argv = {};

        if (GLib.Environment.find_program_in_path("systemd-run") != null)
            argv = { "systemd-run", "--user", "--scope", "--unit", systemd_scope_unit_name(app_info.get_id()) };

        if (needs_terminal(app_info)) {
            argv += "x-terminal-emulator";
            argv += "-e";
        }

        foreach (unowned string arg in expand_desktop_exec(app_info))
            argv += arg;

        return argv;
    }

    /* The directory a desktop entry asks its program to run in (the Path key), or null */
    public static string ? get_desktop_working_directory(DesktopAppInfo app_info) {
        string ? path = app_info.get_string("Path");
        return path != null && path != "" ? path : null;
    }

    /*
     * The well-known D-Bus name of a desktop entry that is started over the session bus
     * (DBusActivatable=true): its desktop file ID without .desktop. Null for other
     * entries, and, as in GLib, when the ID does not form a valid name.
     */
    public static string ? get_dbus_activation_name(DesktopAppInfo app_info) {
        unowned string ? app_id = app_info.get_id();
        if (app_id == null || !app_id.has_suffix(".desktop") || !app_info.get_boolean("DBusActivatable"))
            return null;

        string name = app_id.substring(0, app_id.length - ".desktop".length);
        return GLib.DBus.is_name(name) && !GLib.DBus.is_unique_name(name) ? name : null;
    }

    /*
     * The object path of an application from its D-Bus name: a leading /, then the
     * name with each . turned into / and each - into _
     */
    public static string get_dbus_activation_path(string bus_name) {
        return "/" + bus_name.replace(".", "/").replace("-", "_");
    }

    /**
     * A program and its arguments, started in its own systemd scope when systemd-run is available
     *
     * @param id Names the scope, see systemd_scope_unit_name()
     * @param argv The program and its arguments; the program may start with '-'
     */
    public static string[] get_scope_argv(string id, string[] argv) {
        if (GLib.Environment.find_program_in_path("systemd-run") == null)
            return argv;

        string[] scope_argv = { "systemd-run", "--user", "--scope", "--unit", systemd_scope_unit_name(id), "--" };
        foreach (unowned string arg in argv)
            scope_argv += arg;
        return scope_argv;
    }

    // Launches recorded in the launch history (the app-launch-counts setting), which ranks the rows of the apps page
    public const int LAUNCH_HISTORY_MAX_LEN = 32;

    /**
     * The launch history with one more launch: the newest max_len launches, ending with key
     */
    public static string[] append_launch_history(string[] ? history, string key, int max_len) {
        string[] result = {};
        if (history != null)
            result = history;
        result += key;
        if (result.length <= max_len)
            return result;

        string[] newest = result[result.length - max_len : result.length];
        return newest;
    }

    /* Record a launch under key in the launch history, which keeps the newest LAUNCH_HISTORY_MAX_LEN */
    public static void record_launch(GLib.Settings settings, string key) {
        string[] history = append_launch_history(settings.get_strv("app-launch-counts"), key, LAUNCH_HISTORY_MAX_LEN);
        settings.set_strv("app-launch-counts", history);
    }

    /**
     * Build the command line that the commands page launches
     *
     * @param command A command line in shell syntax: a quoted path from the list, or the text typed by the user
     * @param quiet If true run the command directly, otherwise in x-terminal-emulator
     * @return A command line for AppInfo.create_from_commandline()
     */
    public static string build_command_line(string command, bool quiet) {
        // x-terminal-emulator takes the program and its arguments after -e
        string commandline = quiet ? command : "x-terminal-emulator -e " + command;

        // AppInfo expands % field codes as in a desktop file Exec key; keep literal % signs
        return commandline.replace("%", "%%");
    }

    /**
     * The directories of a PATH value that the commands page lists, each once
     *
     * Entries that name the same directory are listed once, at the first: with merged /usr,
     * /bin and /sbin are links to /usr/bin and /usr/sbin, and PATH may repeat an entry.
     * Directories that do not exist are skipped.
     */
    public static string[] command_dirs(string ? path_var) {
        string[] dirs = {};
        if (path_var == null)
            return dirs;

        var seen = new GenericSet<string>(str_hash, str_equal);
        foreach (unowned string dir in path_var.split(":")) {
            if (dir.length == 0)
                continue;
            string ? canonical = Posix.realpath(dir);
            if (canonical == null || seen.contains(canonical) || !FileUtils.test(canonical, FileTest.IS_DIR))
                continue;
            seen.add(canonical);
            dirs += dir;
        }
        return dirs;
    }

    /**
     * True for the entries of a PATH directory that are commands: executable files, also
     * through symbolic links. The info must be queried following links, with the type and
     * access::can-execute attributes.
     */
    public static bool is_command(FileInfo info) {
        return info.get_file_type() == FileType.REGULAR
               && info.get_attribute_boolean(FileAttribute.ACCESS_CAN_EXECUTE);
    }

    /*
     * The escaping algorithm operates as follows:
     * given a string, any "/" character is replaced by "-", and all other characters which
     * are not ASCII alphanumerics, ":", "_" or "." are replaced by C-style "\x2d" escapes.
     * In addition, "." is replaced with such a C-style escape when it would appear
     * as the first character in the escaped string.
     *
     * When the input qualifies as absolute file system path, this algorithm is extended
     * slightly: the path to the root directory "/"
     * is encoded as single dash "-".
     * In addition, any leading, trailing or duplicate "/" characters are removed from the string before
     * transformation. Example: /foo//bar/baz/ becomes "foo-bar-baz".
     * - systemd.unit.5.en
     */
    public static string systemd_escape(string unescaped) {
        var escaped = new StringBuilder();

        if (unescaped.data[0] == '.')
            escaped.append("\\x2e");
        else
            escaped.append_c(unescaped.@get(0));

        for (int i = 1; i < unescaped.length; ++i) {
            uint8 c = unescaped.data[i];

            if (
                (c > 31 && c < 46) ||
                (c > 58 && c < 65) ||
                (c > 90 && c < 97 && c != 95) ||
                (c > 122))      // escape
                escaped.append_printf("\\x%llx", c);
            else                                                            // copy
                escaped.append_c(unescaped.@get(i));
        }

        return escaped.str.replace("/", "-");
    }

    /**
     * Compare two desktop applications for sorting purposes
     *
     * This function implements the core logic for sorting desktop applications based on:
     * 1. Prefix matching with a query string (if provided)
     * 2. Launch counts (popularity)
     * 3. Alphabetical order as a fallback
     *
     * @param app_a_name The lowercase name of the first application
     * @param app_b_name The lowercase name of the second application
     * @param app_a_id The ID of the first application
     * @param app_b_id The ID of the second application
     * @param query_string The lowercase query string to match against (can be empty)
     * @param launch_counts A hash table mapping app IDs to launch counts
     * @return -1 if app_a should come before app_b, 1 if app_b should come before app_a, 0 if equal
     */
    public static int compare_desktop_apps(string app_a_name,
                                           string app_b_name,
                                           string app_a_id,
                                           string app_b_id,
                                           string query_string,
                                           HashTable<string, int> launch_counts) {
        // First priority: prefix matching with query string
        if (query_string.length > 0) {
            var app_a_has_prefix = app_a_name.has_prefix(query_string);
            var app_b_has_prefix = app_b_name.has_prefix(query_string);

            if (query_string.length > 1 && (app_a_has_prefix || app_b_has_prefix)) {
                if (app_b_has_prefix && !app_a_has_prefix)
                    return 1;
                else if (app_a_has_prefix && !app_b_has_prefix)
                    return -1;
            }
        }

        // Second priority: launch counts (popularity)
        var a_count = launch_counts.get(app_a_id);
        var b_count = launch_counts.get(app_b_id);

        if (a_count > 0 || b_count > 0) {
            if (a_count > b_count)
                return -1;
            else if (a_count < b_count)
                return 1;
            // If launch counts are equal, fall through to alphabetical ordering
        }

        // Third priority: alphabetical order
        int compare_result = app_a_name.ascii_casecmp(app_b_name);
        if (compare_result < 0)
            return -1;
        else if (compare_result > 0)
            return 1;
        else
            return 0;
    }

    /**
     * The text the apps page searches besides the app name: the generic name, the
     * keywords and the comment, as the desktop file gives them for the current locale
     *
     * Each part is optional; they are separated by spaces so words do not run together.
     */
    public static string desktop_app_search_text(DesktopAppInfo app_info) {
        string[] parts = {};

        unowned string ? generic_name = app_info.get_generic_name();
        if (generic_name != null)
            parts += generic_name;

        foreach (unowned string keyword in app_info.get_keywords())
            parts += keyword;

        unowned string ? comment = app_info.get_description();
        if (comment != null)
            parts += comment;

        return string.joinv(" ", parts);
    }

    /**
     * The form in which filtering compares text: compatibility decomposition (NFKD),
     * combining marks dropped, then full Unicode case folding
     *
     * "Café" and "cafe", "Straße" and "strasse", "ﬁle" and "file" have the same folded form.
     */
    public static string fold_text(string text) {
        // NFKD leaves ASCII alone and it has no marks; its case folding is lowering
        bool is_ascii = true;
        for (int i = 0; i < text.length; ++i) {
            if (text.data[i] >= 0x80) {
                is_ascii = false;
                break;
            }
        }
        if (is_ascii)
            return text.ascii_down();

        string decomposed = (text.validate() ? text : text.make_valid()).normalize(-1, NormalizeMode.NFKD);
        var unmarked = new StringBuilder.sized(decomposed.length);
        int index = 0;
        unichar c;
        while (decomposed.get_next_char(ref index, out c)) {
            // ismark(): the nonspacing, spacing and enclosing marks. UnicodeType names the
            // spacing marks SPACING_MARK only in newer Vala bindings.
            if (!c.ismark())
                unmarked.append_unichar(c);
        }
        return unmarked.str.casefold();
    }

    /**
     * Match a filter query against the searchable text of a row
     *
     * The query is split into words at whitespace. A row matches when every
     * word occurs in at least one of its fields, in any order, compared in
     * their folded form (see fold_text()). An empty or blank query matches every row.
     *
     * @param query The text typed in the filter box
     * @param fields The searchable text of the row; null fields are skipped
     * @return true if every word of the query occurs in the fields
     */
    public static bool matches_all_words(string query, string ?[] fields) {
        var folded = new string ?[fields.length];
        for (int i = 0; i < fields.length; ++i)
            folded[i] = fields[i] != null ? fold_text(fields[i]) : null;

        return words_in_fields(query_words(query), folded);
    }

    /**
     * The words of a filter query, folded and split at whitespace
     */
    public static string[] query_words(string query) {
        string[] words = {};
        foreach (unowned string word in fold_text(query).split_set(" \t\r\n")) {
            if (word.length > 0) words += word;
        }
        return words;
    }

    /**
     * matches_all_words() for a single field that is already folded,
     * with the query split by query_words(); for filtering many rows
     */
    public static bool contains_all_words(string folded_field, string[] words) {
        foreach (unowned string word in words) {
            if (!folded_field.contains(word)) return false;
        }
        return true;
    }

    /**
     * True if every word occurs in at least one of the folded fields; null fields are skipped
     */
    public static bool words_in_fields(string[] words, string ?[] folded_fields) {
        foreach (unowned string word in words) {
            bool found = false;
            foreach (unowned string ? field in folded_fields) {
                if (field != null && field.contains(word)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /**
     * True if the characters of word appear in text in the same order, with any
     * number of other characters between them
     */
    public static bool is_subsequence(string word, string text) {
        int word_index = 0, text_index = 0;
        unichar wanted, c;
        if (!word.get_next_char(ref word_index, out wanted))
            return true;
        while (text.get_next_char(ref text_index, out c)) {
            if (c == wanted && !word.get_next_char(ref word_index, out wanted))
                return true;
        }
        return false;
    }

    /**
     * The words of the filter text, split by query_words() once for each new text
     */
    public class QueryWords {
        private string ? text = null;
        private string[] words = {};

        public string[] words_for(string text) {
            if (text != this.text) {
                this.text = text;
                words = query_words(text);
            }
            return words;
        }
    }

    /**
     * The length, in characters, of the shortest stretch of text that holds the
     * characters of word in order, or -1 if there is none
     */
    public static int subsequence_span(string word, string text) {
        var wanted = chars_of(word);
        var chars = chars_of(text);
        if (wanted.length == 0)
            return 0;

        int best = -1;
        for (int start = 0; start < chars.length; ++start) {
            if (chars[start] != wanted[0]) continue;

            // The earliest end for this start
            int matched = 1, end = start + 1;
            for ( ; matched < wanted.length && end < chars.length; ++end) {
                if (chars[end] == wanted[matched]) matched++;
            }
            if (matched < wanted.length)
                break; // a later start cannot hold the word either
            if (best < 0 || end - start < best)
                best = end - start;
        }
        return best;
    }

    /**
     * The summed spans (see subsequence_span()) of the words in the folded fields, each
     * word taking its shortest span in any field, or -1 if a word is a subsequence of
     * none of them; null fields are skipped
     */
    public static int words_subsequence_span(string[] words, string ?[] folded_fields) {
        int total = 0;
        foreach (unowned string word in words) {
            int shortest = -1;
            foreach (unowned string ? field in folded_fields) {
                if (field == null) continue;
                int span = subsequence_span(word, field);
                if (span >= 0 && (shortest < 0 || span < shortest))
                    shortest = span;
            }
            if (shortest < 0)
                return -1;
            total += shortest;
        }
        return total;
    }

    /**
     * How a row matches the words of a filter
     */
    public enum MatchKind {
        // Not shown
        NONE,
        // Every word occurs in one of the row's fields
        WORDS,
        // Only by subsequence, with subsequence matching on
        SUBSEQUENCE
    }

    /**
     * Match the words of a filter against a row's folded fields
     *
     * @param words The filter, split by query_words(); an empty list matches every row
     * @param fields The fields the words are looked for in
     * @param main_fields The fields subsequence matching looks in
     * @param subsequence True if subsequence matching is switched on
     * @param span For MatchKind.SUBSEQUENCE the summed spans, see words_subsequence_span(); else 0
     */
    public static MatchKind match_words(string[] words, string ?[] fields, string ?[] main_fields, bool subsequence, out int span) {
        span = 0;
        if (words_in_fields(words, fields))
            return MatchKind.WORDS;
        if (subsequence) {
            span = words_subsequence_span(words, main_fields);
            if (span >= 0)
                return MatchKind.SUBSEQUENCE;
            span = 0;
        }
        return MatchKind.NONE;
    }

    /**
     * Order two rows of the windows or keybindings page: rows that match only by
     * subsequence after the others, and among them shorter summed spans first; then
     * the page's usual order, by the given text as GTK sorts strings
     */
    public static int compare_matched_rows(MatchKind kind_a, int span_a, string ? text_a,
                                           MatchKind kind_b, int span_b, string ? text_b) {
        bool a_later = kind_a == MatchKind.SUBSEQUENCE;
        bool b_later = kind_b == MatchKind.SUBSEQUENCE;
        if (a_later != b_later)
            return a_later ? 1 : -1;
        if (a_later && span_a != span_b)
            return span_a < span_b ? -1 : 1;
        return (text_a ?? "").collate(text_b ?? "");
    }

    /**
     * The groups the apps page orders filtered rows in, best first. NONE is not shown.
     */
    public enum AppTier {
        NONE,
        // The name is the filter
        EXACT,
        // The name starts with the filter
        PREFIX,
        // Every word starts a word of the name
        WORD_STARTS,
        // Every word occurs in the name
        IN_NAME,
        // Every word occurs in the name or the generic name
        IN_GENERIC_NAME,
        // A keyword or the comment is needed for some word
        IN_OTHER_FIELDS,
        // Only by subsequence of the name, with subsequence matching on
        SUBSEQUENCE
    }

    /**
     * The words of a folded text: its longest runs of letters and digits
     */
    public static string[] text_words(string text) {
        string[] words = {};
        var word = new StringBuilder();
        int index = 0;
        unichar c;
        while (text.get_next_char(ref index, out c)) {
            if (c.isalpha() || c.isdigit()) {
                word.append_unichar(c);
            } else if (word.len > 0) {
                words += word.str;
                word.truncate();
            }
        }
        if (word.len > 0)
            words += word.str;
        return words;
    }

    /**
     * The fields of a desktop app that filtering on the apps page may use
     */
    [Flags]
    public enum AppField {
        NAME,
        GENERIC_NAME,
        KEYWORDS,
        COMMENT;

        public const AppField ALL = NAME | GENERIC_NAME | KEYWORDS | COMMENT;

        /**
         * The fields named in a match-fields setting; unknown names are ignored
         */
        public static AppField from_names(string[] names) {
            AppField fields = 0;
            foreach (unowned string field_name in names) {
                switch (field_name) {
                    case "name":
                        fields |= NAME;
                        break;
                    case "generic-name":
                        fields |= GENERIC_NAME;
                        break;
                    case "keywords":
                        fields |= KEYWORDS;
                        break;
                    case "comment":
                        fields |= COMMENT;
                        break;
                    default:
                        break;
                }
            }
            return fields;
        }
    }

    /**
     * A desktop app as the apps page matches it: the id and the folded text, and the
     * tier the row has for the current filter
     */
    public class AppMatch : GLib.Object {
        public string id { get; private set; }
        // Folded name; subsequence matching and ordering use it whatever the fields
        public string name { get; private set; }
        // Folded fields the word rule may use, or null for those it may not
        private string ? matched_name;
        private string ? generic_name;
        private string ? keywords;
        private string ? comment;

        public AppTier tier { get; private set; default = AppTier.NONE; }
        // For AppTier.SUBSEQUENCE: the summed spans of the words in the name, see subsequence_span()
        public int span { get; private set; default = 0; }
        // Hidden while the launcher runs (Ctrl+Delete): never shown again
        public bool removed { get; set; default = false; }

        /**
         * @param keywords The keywords joined with spaces, or null
         * @param fields The fields filtering may use
         */
        public AppMatch (string id, string name, string ? generic_name, string ? keywords, string ? comment,
                         AppField fields = AppField.ALL) {
            this.id = id;
            this.name = fold_text(name);
            this.matched_name = AppField.NAME in fields ? this.name : null;
            this.generic_name = generic_name != null && AppField.GENERIC_NAME in fields ? fold_text(generic_name) : null;
            this.keywords = keywords != null && AppField.KEYWORDS in fields ? fold_text(keywords) : null;
            this.comment = comment != null && AppField.COMMENT in fields ? fold_text(comment) : null;
        }

        /**
         * Set tier and span for a filter
         *
         * @param words The filter, split by query_words()
         * @param subsequence True if subsequence matching is switched on
         */
        public void rank(string[] words, bool subsequence) {
            tier = compute_tier(words, subsequence);
        }

        private AppTier compute_tier(string[] words, bool subsequence) {
            span = 0;
            if (words.length == 0)
                return AppTier.NONE;

            if (matched_name != null) {
                string query = string.joinv(" ", words);
                if (name == query)
                    return AppTier.EXACT;
                if (name.has_prefix(query))
                    return AppTier.PREFIX;
                if (starts_name_words(words))
                    return AppTier.WORD_STARTS;
                if (contains_all_words(name, words))
                    return AppTier.IN_NAME;
            }
            if (words_in_fields(words, { matched_name, generic_name }))
                return AppTier.IN_GENERIC_NAME;
            if (words_in_fields(words, { matched_name, generic_name, keywords, comment }))
                return AppTier.IN_OTHER_FIELDS;

            if (subsequence) {
                int total = words_subsequence_span(words, { name });
                if (total >= 0) {
                    span = total;
                    return AppTier.SUBSEQUENCE;
                }
            }
            return AppTier.NONE;
        }

        private bool starts_name_words(string[] words) {
            var name_words = text_words(name);
            foreach (unowned string word in words) {
                bool found = false;
                foreach (unowned string name_word in name_words) {
                    if (name_word.has_prefix(word)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }
    }

    /**
     * Order two apps ranked for the same, non-empty filter
     *
     * Lower tiers first. Inside a tier the app launched more often comes first, except
     * that subsequence matches go by span first; then the folded names in code-point
     * order, then the desktop ids.
     *
     * @return a negative value if a comes first, a positive one if b does, 0 if equal
     */
    public static int compare_app_matches(AppMatch a, AppMatch b, HashTable<string, int> launch_counts) {
        if (a.tier != b.tier)
            return a.tier < b.tier ? -1 : 1;

        if (a.tier == AppTier.SUBSEQUENCE && a.span != b.span)
            return a.span < b.span ? -1 : 1;

        int a_count = launch_counts.get(a.id);
        int b_count = launch_counts.get(b.id);
        if (a_count != b_count)
            return a_count > b_count ? -1 : 1;

        int by_name = strcmp(a.name, b.name);
        if (by_name != 0)
            return by_name < 0 ? -1 : 1;

        int by_id = strcmp(a.id, b.id);
        return by_id < 0 ? -1 : (by_id > 0 ? 1 : 0);
    }

    /**
     * True if the desktop id equals one of the patterns or fits it, where * stands
     * for any run of characters and ? for exactly one character
     */
    public static bool is_hidden_app(string id, string[] patterns) {
        foreach (unowned string pattern in patterns) {
            if (id == pattern || PatternSpec.match_simple(pattern, id))
                return true;
        }
        return false;
    }

    // Gtk.Entry counts positions in characters; Vala string indexes count bytes

    private static unichar[] chars_of(string text) {
        unichar[] chars = {};
        int index = 0;
        unichar c;
        while (text.get_next_char(ref index, out c))
            chars += c;
        return chars;
    }

    private static bool is_word_break(unichar c) {
        return c.isspace() || c.ispunct();
    }

    /**
     * The entry position Ctrl+w moves to: the start of the next word, or the end of the text
     *
     * @param pos A position in characters, as Gtk.Entry.get_position() gives it
     * @return A position in characters
     */
    public static int next_word_start(string text, int pos) {
        var chars = chars_of(text);
        bool found_word_break = false;

        for (int i = pos; i < chars.length; i++) {
            if (is_word_break(chars[i]))
                found_word_break = true;
            else if (found_word_break)
                return i;
        }

        return chars.length;
    }

    /**
     * The entry position Ctrl+b moves to: the start of the word before the one at pos, or 0
     *
     * @param pos A position in characters, as Gtk.Entry.get_position() gives it
     * @return A position in characters
     */
    public static int previous_word_start(string text, int pos) {
        var chars = chars_of(text);

        // Start of the word the position is in
        int start = int.min(pos, chars.length);
        while (start > 0 && !is_word_break(chars[start - 1]))
            start--;

        bool found_word = false;
        for (int i = start - 1; i >= 0; i--) {
            if (!is_word_break(chars[i]))
                found_word = true;
            else if (found_word)
                return i + 1;
        }

        return 0;
    }

    /**
     * The text between two entry positions, which count characters
     */
    public static string substring_chars(string text, int start, int end) {
        long start_byte = text.index_of_nth_char(start);
        return text.substring(start_byte, text.index_of_nth_char(end) - start_byte);
    }
}
