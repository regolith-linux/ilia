namespace Ilia {
    /**
     * Why a new desktop entry was refused. The code names the field that is wrong,
     * WRITE when the file or a directory could not be created.
     */
    public errordomain NewDesktopEntryError {
        NAME,
        COMMAND,
        ICON,
        WRITE
    }

    /**
     * A desktop entry the user is adding, from the add-application form
     *
     * The fields hold the text as typed. validate() checks it and prepares the values
     * that are written; save() then creates the file in the user's applications directory.
     */
    public class NewDesktopEntry : GLib.Object {
        private const string GROUP = "Desktop Entry";
        // The longest file name stem made from a name
        private const int SLUG_MAX_LENGTH = 64;
        // Characters that stay unquoted in an Exec value; anything else is quoted
        private const string EXEC_PLAIN_CHARS = "-_./:,+=@%";

        public string name { get; set; default = ""; }
        public string command { get; set; default = ""; }
        public string icon { get; set; default = ""; }
        public string comment { get; set; default = ""; }
        public string keywords { get; set; default = ""; }
        public bool terminal { get; set; default = false; }

        // Prepared by validate()
        private string[] exec_words = {};
        private string ? icon_value = null;
        private string[] keyword_list = {};

        /**
         * Check every field, in the order the form shows them, and prepare the values to write
         *
         * @throws NewDesktopEntryError for the first field that is wrong
         */
        public void validate() throws NewDesktopEntryError {
            if (trimmed(name).length == 0)
                throw new NewDesktopEntryError.NAME("Enter a name.");

            exec_words = split_command_line(trimmed(command));
            exec_words[0] = resolve_program(exec_words[0]);

            icon_value = icon_key_value(trimmed(icon));
            keyword_list = split_keywords(keywords);
        }

        /**
         * The contents of the desktop file. Call validate() first.
         */
        public string to_data() {
            // Values are escaped here rather than by KeyFile.set_string(), which leaves tabs as they
            // are; desktop-file-validate refuses control characters in Exec
            var key_file = new KeyFile();
            key_file.set_value(GROUP, "Type", "Application");
            key_file.set_value(GROUP, "Name", escape_value(trimmed(name)));
            var comment_text = trimmed(comment);
            if (comment_text.length > 0)
                key_file.set_value(GROUP, "Comment", escape_value(comment_text));
            key_file.set_value(GROUP, "Exec", escape_value(exec_value(exec_words)));
            if (icon_value != null)
                key_file.set_value(GROUP, "Icon", escape_value(icon_value));
            key_file.set_boolean(GROUP, "Terminal", terminal);
            if (keyword_list.length > 0) {
                var keywords_value = new StringBuilder();
                foreach (unowned string keyword in keyword_list)
                    keywords_value.append(escape_value(keyword).replace(";", "\\;")).append_c(';');
                key_file.set_value(GROUP, "Keywords", keywords_value.str);
            }
            return key_file.to_data();
        }

        /**
         * A string as a desktop entry value: \s for a leading space, \n, \t, \r and \\
         */
        public static string escape_value(string text) {
            var escaped = new StringBuilder();
            for (int i = 0; i < text.length; ++i) {
                char c = text[i];
                switch (c) {
                    case ' ':
                        escaped.append(i == 0 ? "\\s" : " ");
                        break;
                    case '\n':
                        escaped.append("\\n");
                        break;
                    case '\t':
                        escaped.append("\\t");
                        break;
                    case '\r':
                        escaped.append("\\r");
                        break;
                    case '\\':
                        escaped.append("\\\\");
                        break;
                    default:
                        escaped.append_c(c);
                        break;
                }
            }
            return escaped.str;
        }

        /**
         * Validate the fields and write the entry to a new file in the user's applications directory
         *
         * The file is named after the name (see desktop_id_stem()), with the first free
         * -2, -3, ... suffix. Missing directories are created 0700, the file 0644 (both less
         * the umask). An existing file or link is never replaced.
         *
         * @return The path of the new file
         * @throws NewDesktopEntryError for a wrong field, or WRITE when nothing could be written
         */
        public string save() throws NewDesktopEntryError {
            validate();

            var apps_dir = user_applications_dir();
            if (DirUtils.create_with_parents(apps_dir, 0700) != 0)
                throw new NewDesktopEntryError.WRITE("Could not create %s: %s", apps_dir, strerror(errno));

            var taken = desktop_ids_in(applications_dirs());
            var stem = desktop_id_stem(trimmed(name));
            var data = to_data();
            for (int n = 1;; ++n) {
                var id = n == 1 ? stem + ".desktop" : "%s-%d.desktop".printf(stem, n);
                if (taken.contains(id))
                    continue;

                var path = Path.build_filename(apps_dir, id);
                if (create_file(path, data))
                    return path;
            }
        }

        /**
         * Create path with contents, failing if anything exists there
         *
         * @return false if something already exists at path
         */
        private static bool create_file(string path, string contents) throws NewDesktopEntryError {
            int fd = Posix.open(path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_NOFOLLOW | Posix.O_CLOEXEC, 0644);
            if (fd < 0) {
                if (errno == Posix.EEXIST)
                    return false;
                throw new NewDesktopEntryError.WRITE("Could not create %s: %s", path, strerror(errno));
            }

            unowned uint8[] bytes = contents.data;
            size_t written = 0;
            while (written < bytes.length) {
                var count = Posix.write(fd, (void *) ((uint8 *) bytes + written), bytes.length - written);
                if (count < 0 && errno == Posix.EINTR)
                    continue;
                if (count <= 0) {
                    var message = strerror(errno);
                    Posix.close(fd);
                    FileUtils.unlink(path);
                    throw new NewDesktopEntryError.WRITE("Could not write %s: %s", path, message);
                }
                written += count;
            }
            if (Posix.close(fd) != 0) {
                var message = strerror(errno);
                FileUtils.unlink(path);
                throw new NewDesktopEntryError.WRITE("Could not write %s: %s", path, message);
            }
            return true;
        }

        // The text without the spaces, tabs and newlines at both of its ends; other characters
        // there, carriage returns among them, are kept
        private static string trimmed(string text) {
            int start = 0;
            int end = text.length;
            while (start < end && " \t\n".index_of_char(text[start]) >= 0)
                ++start;
            while (end > start && " \t\n".index_of_char(text[end - 1]) >= 0)
                --end;
            return text.substring(start, end - start);
        }

        /**
         * $XDG_DATA_HOME/applications, or ~/.local/share/applications when XDG_DATA_HOME is unset or empty
         */
        public static string user_applications_dir() {
            return Path.build_filename(Environment.get_user_data_dir(), "applications");
        }

        /**
         * The applications directories desktop file ids are looked up in: the user's, then
         * those of $XDG_DATA_DIRS
         */
        public static string[] applications_dirs() {
            string[] dirs = { user_applications_dir() };
            foreach (unowned string data_dir in Environment.get_system_data_dirs())
                dirs += Path.build_filename(data_dir, "applications");
            return dirs;
        }

        /**
         * Split a command line into words as a POSIX shell does for quoting, with no expansion
         *
         * Single quotes keep everything literally. Inside double quotes a backslash escapes
         * only $, `, ", \ and newline. Outside quotes a backslash escapes any character.
         * A backslash before a newline removes both. Words are separated only by blanks that
         * are neither quoted nor escaped: spaces, tabs and newlines.
         *
         * @throws NewDesktopEntryError.COMMAND if the line is empty, a quote is not closed,
         *         or it ends in a lone backslash
         */
        public static string[] split_command_line(string command_line) throws NewDesktopEntryError {
            string[] words = {};
            var word = new StringBuilder();
            bool in_word = false;
            unowned string text = command_line;
            int i = 0;
            unichar c;

            while (text.get_next_char(ref i, out c)) {
                switch (c) {
                    case ' ':
                    case '\t':
                    case '\n':
                        if (in_word) {
                            words += word.str;
                            word.truncate();
                            in_word = false;
                        }
                        break;
                    case '\\':
                        unichar escaped;
                        if (!text.get_next_char(ref i, out escaped))
                            throw new NewDesktopEntryError.COMMAND("The command ends with a lone backslash.");
                        if (escaped != '\n') {
                            word.append_unichar(escaped);
                            in_word = true;
                        }
                        break;
                    case '\'':
                        in_word = true;
                        while (true) {
                            if (!text.get_next_char(ref i, out c))
                                throw new NewDesktopEntryError.COMMAND("The command has a single quote that is not closed.");
                            if (c == '\'')
                                break;
                            word.append_unichar(c);
                        }
                        break;
                    case '"':
                        in_word = true;
                        while (true) {
                            if (!text.get_next_char(ref i, out c))
                                throw new NewDesktopEntryError.COMMAND("The command has a double quote that is not closed.");
                            if (c == '"')
                                break;
                            if (c == '\\') {
                                int next = i;
                                unichar escaped;
                                if (text.get_next_char(ref next, out escaped) && "$`\"\\\n".index_of_char(escaped) >= 0) {
                                    i = next;
                                    if (escaped != '\n')
                                        word.append_unichar(escaped);
                                    continue;
                                }
                            }
                            word.append_unichar(c);
                        }
                        break;
                    default:
                        word.append_unichar(c);
                        in_word = true;
                        break;
                }
            }
            if (in_word)
                words += word.str;

            if (words.length == 0)
                throw new NewDesktopEntryError.COMMAND("Enter a command.");
            return words;
        }

        /**
         * The program to write for the first word of a command
         *
         * A word starting with ~/ is a path under $HOME. A word containing / must be an absolute
         * path to an executable regular file; a word without / must name one in a $PATH directory.
         *
         * @return The program: the word itself, or the absolute path for ~/
         * @throws NewDesktopEntryError.COMMAND if the program cannot be found
         */
        public static string resolve_program(string word) throws NewDesktopEntryError {
            if (word.length == 0)
                throw new NewDesktopEntryError.COMMAND("The command has no program.");

            string program = word;
            if (word.has_prefix("~/"))
                program = Path.build_filename(home_dir(), word.substring(2));

            if (program.contains("/")) {
                if (!Path.is_absolute(program))
                    throw new NewDesktopEntryError.COMMAND("The program %s is not an absolute path.", word);
                if (!is_executable_file(program))
                    throw new NewDesktopEntryError.COMMAND("The program %s is not an executable file.", word);
                return program;
            }

            var path_var = Environment.get_variable("PATH") ?? "";
            foreach (unowned string dir in path_var.split(":")) {
                if (dir.length > 0 && is_executable_file(Path.build_filename(dir, program)))
                    return program;
            }
            throw new NewDesktopEntryError.COMMAND("The program %s was not found in PATH.", word);
        }

        private static string home_dir() {
            return Environment.get_variable("HOME") ?? Environment.get_home_dir();
        }

        private static bool is_executable_file(string path) {
            return FileUtils.test(path, FileTest.IS_REGULAR) && FileUtils.test(path, FileTest.IS_EXECUTABLE);
        }

        /**
         * The Exec value that runs exactly these words: each word quoted as the Desktop Entry
         * Specification asks when it needs it, and every % doubled
         */
        public static string exec_value(string[] words) {
            string[] quoted = {};
            foreach (unowned string word in words)
                quoted += quote_exec_word(word);
            return string.joinv(" ", quoted);
        }

        private static string quote_exec_word(string word) {
            bool plain = word.length > 0;
            for (int i = 0; plain && i < word.length; ++i) {
                char c = word[i];
                plain = c.isalnum() || (uint8) c >= 0x80 || EXEC_PLAIN_CHARS.index_of_char(c) >= 0;
            }

            var result = new StringBuilder();
            if (!plain)
                result.append_c('"');
            for (int i = 0; i < word.length; ++i) {
                char c = word[i];
                if (c == '%')
                    result.append_c('%');
                else if (!plain && "\"`$\\".index_of_char(c) >= 0)
                    result.append_c('\\');
                result.append_c(c);
            }
            if (!plain)
                result.append_c('"');
            return result.str;
        }

        /**
         * The Icon value for the Icon field: null when empty, an absolute path to an existing
         * file as it is, otherwise an icon name without a trailing .png, .svg or .xpm
         *
         * @throws NewDesktopEntryError.ICON for a path that is not an existing file
         */
        public static string ? icon_key_value(string icon) throws NewDesktopEntryError {
            if (icon.length == 0)
                return null;

            if (icon.contains("/")) {
                if (!Path.is_absolute(icon) || !FileUtils.test(icon, FileTest.IS_REGULAR))
                    throw new NewDesktopEntryError.ICON("The icon %s is not an absolute path to an existing file.", icon);
                return icon;
            }

            foreach (unowned string extension in new string[] { ".png", ".svg", ".xpm" }) {
                if (icon.has_suffix(extension) && icon.length > extension.length)
                    return icon.substring(0, icon.length - extension.length);
            }
            return icon;
        }

        /**
         * The keywords of a comma-separated list, each trimmed, empty ones dropped
         */
        public static string[] split_keywords(string text) {
            string[] keywords = {};
            foreach (unowned string item in text.split(",")) {
                var keyword = trimmed(item);
                if (keyword.length > 0)
                    keywords += keyword;
            }
            return keywords;
        }

        /**
         * The file name stem for a name: A-Z lowered, each run of other characters than a-z
         * and 0-9 turned into one -, - stripped at both ends, at most 64 characters, "app" if
         * nothing is left
         */
        public static string desktop_id_stem(string name) {
            var stem = new StringBuilder();
            bool pending_dash = false;
            for (int i = 0; i < name.length; ++i) {
                char c = name[i];
                if (c >= 'A' && c <= 'Z')
                    c = c.tolower();
                if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
                    if (pending_dash && stem.len > 0)
                        stem.append_c('-');
                    pending_dash = false;
                    stem.append_c(c);
                } else {
                    pending_dash = true;
                }
            }

            if (stem.len > SLUG_MAX_LENGTH)
                stem.truncate(SLUG_MAX_LENGTH);
            while (stem.len > 0 && stem.str[stem.len - 1] == '-')
                stem.truncate(stem.len - 1);
            return stem.len > 0 ? stem.str : "app";
        }

        /**
         * The desktop file ids of every *.desktop file under the given applications directories,
         * whatever the file contains. A file in a subdirectory has the id of its relative path
         * with / turned into -.
         */
        public static GenericSet<string> desktop_ids_in(string[] dirs) {
            var ids = new GenericSet<string>(str_hash, str_equal);
            foreach (unowned string dir in dirs)
                add_desktop_ids(ids, new GenericSet<string>(str_hash, str_equal), dir, "");
            return ids;
        }

        // ancestors holds the directories being read above dir, so links back up are not followed
        private static void add_desktop_ids(GenericSet<string> ids, GenericSet<string> ancestors, string dir, string prefix) {
            string ? canonical = Posix.realpath(dir);
            if (canonical == null || ancestors.contains(canonical))
                return;

            Dir handle;
            try {
                handle = Dir.open(dir);
            } catch (FileError e) {
                return;
            }

            ancestors.add(canonical);
            unowned string ? entry;
            while ((entry = handle.read_name()) != null) {
                var path = Path.build_filename(dir, entry);
                if (FileUtils.test(path, FileTest.IS_DIR))
                    add_desktop_ids(ids, ancestors, path, prefix + entry + "-");
                else if (entry.has_suffix(".desktop"))
                    ids.add(prefix + entry);
            }
            ancestors.remove(canonical);
        }
    }
}
