namespace Ilia {
    /**
     * Where the rows of a page defined in a file come from
     */
    public enum PageSource {
        // Desktop entries, by desktop file ID (the Apps key)
        APPS,
        // Lines of text given in the file (the Items key)
        ITEMS,
        // The lines a shell command prints (the ItemsCommand key)
        COMMAND,
        // A menu of entries, each described by an [Entry <id>] group (the Entries key)
        ENTRIES
    }

    public errordomain PageFileError {
        INVALID
    }

    /**
     * A page defined in a key file: ilia/pages/<id>.page in the XDG configuration directories
     *
     * The file has one group, [Ilia Page], with these keys:
     *  - Name: the tab label, as plain text (required)
     *  - Icon: the icon of the tab and of the rows (default applications-other)
     *  - Key: a letter that selects the page with Alt when all pages are shown
     *  - OnlyShowIn, NotShowIn: the window managers the page is shown under (i3, sway, other)
     *  - exactly one of Apps (desktop file IDs), Items (lines of text), ItemsCommand
     *    (a shell command, each line it prints is a row) and Entries (the ids of the
     *    top-level entries of a menu, see MenuEntry)
     *  - Exec: what choosing a row of Items or ItemsCommand runs, with %s replaced by the
     *    row's value; without it the value is printed
     *  - Sort: frequency puts the rows of Items or ItemsCommand chosen most often first
     *
     * A row of Items or ItemsCommand is a label, shown and searched, and a value, which
     * choosing the row acts on: the text before and after its first tab.
     *
     * In a menu, an entry that cannot be used is left out and reported on stderr. An id
     * listed more than once, or a submenu that contains itself at any depth, makes the
     * whole file unusable.
     */
    public class PageFile : GLib.Object {
        public const string GROUP = "Ilia Page";
        public const string SUFFIX = ".page";
        public const string DEFAULT_ICON = "applications-other";

        // The identifier: the file name without .page, as written
        public string id { get; private set; }
        // The file the page was read from
        public string path { get; private set; }
        public string file_name { get; private set; }
        // The display name, plain text
        public string name { get; private set; }
        public string icon { get; private set; default = DEFAULT_ICON; }
        // The lower-case letter of a usable Key, or 0
        public char key { get; private set; default = 0; }
        public PageSource source { get; private set; }
        public string[] apps = {};
        public string[] items = {};
        public string ? command { get; private set; default = null; }
        // Entries: the top-level entries of the menu, in the order listed, without the unusable ones
        public MenuEntry[] entries = {};
        // The words of the Exec key; null if the page has none, or it could not be split
        public string[] ? exec_argv = null;
        // The Exec key could not be split into words: choosing a row does nothing
        public bool exec_invalid { get; private set; default = false; }
        // Sort=frequency: rows chosen most often come first, and choices are recorded
        public bool sort_by_frequency { get; private set; default = false; }
        // Window manager names, lower case
        private string[] only_show_in = {};
        private string[] not_show_in = {};

        // The names of the built-in pages, which a file cannot use
        public const string[] BUILTIN_PAGES = { "apps", "terminal", "notifications", "keybindings", "textlist", "windows", "tracker" };

        /**
         * True for the names of the built-in pages, in any letter case
         */
        public static bool is_builtin_page(string id) {
            return id.ascii_down() in BUILTIN_PAGES;
        }

        /**
         * True if id can name a page from a file: one or more ASCII letters, digits, '-' and '_'
         */
        public static bool is_valid_id(string id) {
            if (id.length == 0)
                return false;
            for (int i = 0; i < id.length; ++i) {
                char c = id[i];
                if (!(c.isalnum() || c == '-' || c == '_'))
                    return false;
            }
            return true;
        }

        /**
         * True if the page is shown under the window manager (sway, i3 or other)
         */
        public bool is_shown_under(string wm_name) {
            return wm_lists_allow(only_show_in, not_show_in, wm_name);
        }

        /**
         * True if OnlyShowIn and NotShowIn lists (lower case) allow the window manager (sway, i3 or other)
         */
        public static bool wm_lists_allow(string[] only_show_in, string[] not_show_in, string wm_name) {
            string wm = wm_name.down();
            if (only_show_in.length > 0 && !(wm in only_show_in))
                return false;
            return !(wm in not_show_in);
        }

        /**
         * The submenus a menu link names, from the top level down
         *
         * Each id must be, exactly, a submenu directly below the one before (the top level
         * for the first), shown under the window manager. Conditions and bindings are not
         * consulted.
         *
         * @param ids The entry ids of the link, from the top level down
         * @return the submenus, or null if the page has no such menu
         */
        public MenuEntry[] ? find_menu(string[] ids, string wm_name) {
            if (source != PageSource.ENTRIES || ids.length == 0)
                return null;

            MenuEntry[] path = {};
            MenuEntry[] level = entries;
            foreach (unowned string id in ids) {
                MenuEntry ? found = null;
                foreach (var entry in level) {
                    if (entry.id == id) {
                        found = entry;
                        break;
                    }
                }
                if (found == null || found.kind != MenuEntryKind.SUBMENU || !found.is_shown_under(wm_name))
                    return null;
                path += found;
                level = found.children;
            }
            return path;
        }

        /**
         * The directories page files are read from, the one that wins first: the user's,
         * then those of XDG_CONFIG_DIRS in their order
         */
        public static string[] page_dirs() {
            string[] dirs = { Path.build_filename(Environment.get_user_config_dir(), "ilia", "pages") };
            foreach (unowned string dir in Environment.get_system_config_dirs()) {
                if (dir.length > 0)
                    dirs += Path.build_filename(dir, "ilia", "pages");
            }
            return dirs;
        }

        /**
         * Read the page files, reporting each unusable one on stderr
         *
         * For each page the file in the first directory wins, and in a directory the file
         * whose name comes first in byte order; only the winning file is read. Identifiers
         * are compared without regard to letter case.
         *
         * @return the usable pages, ordered by file name (byte order)
         */
        public static PageFile[] load_all() {
            var winners = new HashTable<string, int>(str_hash, str_equal);
            string[] paths = {};
            string[] ids = {};

            string[] dirs = page_dirs();
            for (int dir_index = 0; dir_index < dirs.length; ++dir_index) {
                foreach (unowned string file_name in list_page_files(dirs[dir_index])) {
                    string file_path = Path.build_filename(dirs[dir_index], file_name);
                    string id = file_name.substring(0, file_name.length - SUFFIX.length);

                    if (!is_valid_id(id)) {
                        report_unusable(file_path, "a page name may only contain ASCII letters, digits, '-' and '_'");
                        continue;
                    }
                    if (is_builtin_page(id)) {
                        report_unusable(file_path, "'%s' is the name of a built-in page".printf(id));
                        continue;
                    }

                    string folded = id.ascii_down();
                    if (winners.contains(folded)) {
                        // A file in an earlier directory hides this one without notice
                        if (winners.get(folded) == dir_index)
                            report_unusable(file_path, "another file for the same page comes first in this directory");
                        continue;
                    }
                    winners.insert(folded, dir_index);
                    paths += file_path;
                    ids += id;
                }
            }

            var pages = new GenericArray<PageFile>();
            for (int i = 0; i < paths.length; ++i) {
                try {
                    pages.add(new PageFile.from_file(paths[i], ids[i]));
                } catch (GLib.Error e) {
                    report_unusable(paths[i], e.message);
                }
            }
            pages.sort((a, b) => strcmp(a.file_name, b.file_name));
            return pages.data;
        }

        // The names of the page files directly in dir, in byte order; none if it cannot be read
        private static string[] list_page_files(string dir_path) {
            var names = new GenericArray<string>();
            try {
                var dir = Dir.open(dir_path);
                unowned string ? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_suffix(SUFFIX) && FileUtils.test(Path.build_filename(dir_path, name), FileTest.IS_REGULAR))
                        names.add(name);
                }
            } catch (FileError e) {
                return {};
            }
            names.sort(strcmp);
            return names.data;
        }

        private static void report_unusable(string file_path, string reason) {
            stderr.printf("ilia: ignoring page file '%s': %s\n", file_path, reason);
        }

        private void report_problem(string reason) {
            stderr.printf("ilia: page file '%s': %s\n", path, reason);
        }

        /**
         * Read a page file
         *
         * A Key that is not a single ASCII letter, and an Exec that cannot be split into
         * words, are reported on stderr; the page is still usable.
         *
         * @throws PageFileError.INVALID, KeyFileError or FileError if the page is not usable
         */
        public PageFile.from_file(string path, string id) throws GLib.Error {
            this.path = path;
            this.id = id;
            this.file_name = Path.get_basename(path);

            var key_file = new KeyFile();
            key_file.load_from_file(path, KeyFileFlags.NONE);
            if (!key_file.has_group(GROUP))
                throw new PageFileError.INVALID("it has no [%s] group", GROUP);

            string ? name_value = get_string(key_file, GROUP, "Name");
            if (name_value == null || name_value.strip() == "")
                throw new PageFileError.INVALID("Name is missing or blank");
            name = name_value;

            string ? icon_value = get_string(key_file, GROUP, "Icon");
            if (icon_value != null && icon_value.strip() != "")
                icon = icon_value;

            apps = get_list(key_file, GROUP, "Apps");
            items = get_list(key_file, GROUP, "Items");
            string ? command_value = get_string(key_file, GROUP, "ItemsCommand");
            if (command_value != null && command_value.strip() != "")
                command = command_value;
            string[] entry_ids = get_list(key_file, GROUP, "Entries");

            int sources = (apps.length > 0 ? 1 : 0) + (items.length > 0 ? 1 : 0) + (command != null ? 1 : 0) + (entry_ids.length > 0 ? 1 : 0);
            if (sources == 0)
                throw new PageFileError.INVALID("it gives none of Apps, Items, ItemsCommand and Entries");
            if (sources > 1)
                throw new PageFileError.INVALID("it gives more than one of Apps, Items, ItemsCommand and Entries");
            if (apps.length > 0)
                source = PageSource.APPS;
            else if (items.length > 0)
                source = PageSource.ITEMS;
            else if (command != null)
                source = PageSource.COMMAND;
            else
                source = PageSource.ENTRIES;

            only_show_in = get_wm_list(key_file, GROUP, "OnlyShowIn");
            not_show_in = get_wm_list(key_file, GROUP, "NotShowIn");

            if (source == PageSource.ENTRIES)
                entries = read_menu(key_file, entry_ids);

            string ? key_value = get_string(key_file, GROUP, "Key");
            if (key_value != null) {
                if (key_value.length == 1 && key_value[0].isalpha())
                    key = key_value[0].tolower();
                else
                    report_problem("Key '%s' is not a single ASCII letter, ignoring it".printf(key_value));
            }

            // Rows of desktop entries always start the app, in the order listed; menu rows act as their entries say
            if (source == PageSource.ITEMS || source == PageSource.COMMAND) {
                string ? sort_value = get_string(key_file, GROUP, "Sort");
                if (sort_value != null && sort_value.strip() != "") {
                    if (sort_value.strip().ascii_down() == "frequency")
                        sort_by_frequency = true;
                    else
                        report_problem("Sort '%s' is not recognised, keeping the listed order".printf(sort_value));
                }

                string ? exec_value = get_string(key_file, GROUP, "Exec");
                if (exec_value != null && exec_value.strip() != "") {
                    try {
                        string[] argv;
                        Shell.parse_argv(exec_value, out argv);
                        exec_argv = argv;
                    } catch (ShellError e) {
                        exec_invalid = true;
                        report_problem("Exec cannot be split into words, choosing a row does nothing: %s".printf(e.message));
                    }
                }
            }
        }

        // The value of a key of a group, or null if the key is absent
        private static string ? get_string(KeyFile key_file, string group, string key) throws KeyFileError {
            if (!key_file.has_key(group, key))
                return null;
            return key_file.get_string(group, key);
        }

        // The entries of a ;-separated list, without the empty ones; none if the key is absent
        private static string[] get_list(KeyFile key_file, string group, string key) throws KeyFileError {
            string[] entries = {};
            if (!key_file.has_key(group, key))
                return entries;
            foreach (unowned string entry in key_file.get_string_list(group, key)) {
                if (entry != "")
                    entries += entry;
            }
            return entries;
        }

        // A list of window manager names, without surrounding blank space, in lower case
        private static string[] get_wm_list(KeyFile key_file, string group, string key) throws KeyFileError {
            string[] names = {};
            foreach (unowned string entry in get_list(key_file, group, key)) {
                string name = entry.strip().down();
                if (name != "")
                    names += name;
            }
            return names;
        }

        /**
         * Read the menu whose top level lists entry_ids
         *
         * Each entry that cannot be used is left out and reported on stderr, once the whole
         * menu is known to be usable.
         *
         * @throws PageFileError.INVALID if an id is listed more than once, or a submenu
         * contains itself
         */
        private MenuEntry[] read_menu(KeyFile key_file, string[] entry_ids) throws GLib.Error {
            var listed = new HashTable<string, bool>(str_hash, str_equal);
            var problems = new GenericArray<string> ();
            var menu = read_entries(key_file, entry_ids, {}, listed, problems);
            foreach (unowned string problem in problems.data)
                report_problem(problem);
            return menu;
        }

        // The usable entries of a list, depth first; enclosing holds the ids of the submenus the list is in
        private MenuEntry[] read_entries(KeyFile key_file, string[] ids, string[] enclosing,
                                         HashTable<string, bool> listed, GenericArray<string> problems) throws GLib.Error {
            MenuEntry[] menu = {};
            foreach (unowned string id in ids) {
                if (id in enclosing)
                    throw new PageFileError.INVALID("the submenu of entry '%s' leads back to it", id);
                if (listed.contains(id))
                    throw new PageFileError.INVALID("entry '%s' is listed more than once", id);
                listed.insert(id, true);

                string ? problem = null;
                var entry = read_entry(key_file, id, out problem);
                if (entry == null) {
                    problems.add("leaving out entry '%s': %s".printf(id, problem));
                    continue;
                }
                if (problem != null)
                    problems.add("entry '%s': %s".printf(id, problem));
                if (entry.kind == MenuEntryKind.SUBMENU) {
                    string[] inner = enclosing;
                    inner += id;
                    entry.children = read_entries(key_file, get_list(key_file, entry.group, "Entries"), inner, listed, problems);
                }
                menu += entry;
            }
            return menu;
        }

        /**
         * Read the group of an entry, without its children
         *
         * @param problem Why the entry is not usable; or, for a usable one, a key that is ignored
         * @return null if the entry is not usable
         */
        private static MenuEntry ? read_entry(KeyFile key_file, string id, out string ? problem) throws KeyFileError {
            problem = null;
            if (!is_valid_id(id)) {
                problem = "an entry id may only contain ASCII letters, digits, '-' and '_'";
                return null;
            }
            var entry = new MenuEntry(id);
            if (!key_file.has_group(entry.group)) {
                problem = "there is no [%s] group".printf(entry.group);
                return null;
            }

            bool has_entries = key_file.has_key(entry.group, "Entries");
            bool has_binding = key_file.has_key(entry.group, "Binding");
            bool has_exec = key_file.has_key(entry.group, "Exec");
            int kinds = (has_entries ? 1 : 0) + (has_binding ? 1 : 0) + (has_exec ? 1 : 0);
            if (kinds == 0) {
                problem = "it gives none of Entries, Binding and Exec";
                return null;
            }
            if (kinds > 1) {
                problem = "it gives more than one of Entries, Binding and Exec";
                return null;
            }

            string ? name_value = get_string(key_file, entry.group, "Name");
            if (name_value == null || name_value.strip() == "") {
                problem = "Name is missing or blank";
                return null;
            }
            entry.name = name_value;

            string ? icon_value = get_string(key_file, entry.group, "Icon");
            if (icon_value != null && icon_value.strip() != "")
                entry.icon = icon_value;

            if (has_entries) {
                entry.kind = MenuEntryKind.SUBMENU;
            } else if (has_binding) {
                entry.kind = MenuEntryKind.BINDING;
                entry.binding = get_string(key_file, entry.group, "Binding");
            } else {
                entry.kind = MenuEntryKind.EXEC;
                try {
                    entry.exec_argv = MenuEntry.parse_exec(get_string(key_file, entry.group, "Exec"));
                } catch (ShellError e) {
                    problem = "Exec cannot be split into words: %s".printf(e.message);
                    return null;
                }
            }

            entry.only_show_in = get_wm_list(key_file, entry.group, "OnlyShowIn");
            entry.not_show_in = get_wm_list(key_file, entry.group, "NotShowIn");

            string ? when_value = get_string(key_file, entry.group, "When");
            if (when_value != null) {
                entry.has_condition = true;
                try {
                    entry.when_argv = MenuEntry.parse_command(when_value);
                } catch (ShellError e) {
                    // A condition that cannot run never succeeds
                    problem = "When cannot be split into words, the entry is not shown: %s".printf(e.message);
                }
            }

            string ? state_value = get_string(key_file, entry.group, "State");
            if (state_value != null) {
                try {
                    entry.state_argv = MenuEntry.parse_command(state_value);
                } catch (ShellError e) {
                    // Both When and State may be wrong: report both on the entry's one line
                    string state_problem = "State cannot be split into words, ignoring it: %s".printf(e.message);
                    problem = problem == null ? state_problem : problem + "; " + state_problem;
                }
            }
            return entry;
        }

        /**
         * Divide a row of Items or ItemsCommand at its first tab into the label, which is
         * shown and searched, and the value, which choosing the row acts on
         *
         * A row without a tab, or with nothing on one side of it, uses the same text for both.
         *
         * @return false if the row has no text besides the tab, and is not shown
         */
        public static bool split_row(string row, out string label, out string value) {
            int tab = row.index_of_char('\t');
            label = tab < 0 ? row : row.substring(0, tab);
            value = tab < 0 ? row : row.substring(tab + 1);
            if (label == "")
                label = value;
            else if (value == "")
                value = label;
            return label != "";
        }

        /**
         * The command an Exec key runs for a chosen row
         *
         * In each word %s is replaced by the row's value and %% by %; any other % is kept. The
         * value is never split or interpreted. If no word holds %s it is added as the last word.
         *
         * @param exec_argv The words of the Exec key
         */
        public static string[] expand_exec(string[] exec_argv, string value) {
            string[] argv = {};
            bool substituted = false;

            foreach (unowned string word in exec_argv) {
                var arg = new StringBuilder();
                for (int i = 0; i < word.length; ++i) {
                    if (word[i] == '%' && i + 1 < word.length) {
                        if (word[i + 1] == 's') {
                            arg.append(value);
                            substituted = true;
                            ++i;
                            continue;
                        }
                        if (word[i + 1] == '%') {
                            arg.append_c('%');
                            ++i;
                            continue;
                        }
                    }
                    arg.append_c(word[i]);
                }
                argv += arg.str;
            }

            if (!substituted)
                argv += value;
            return argv;
        }
    }
}
