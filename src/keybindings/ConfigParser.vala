/**
 * This class retrieves the wm config file over IPC and
 * produces a [Category] -> List<Keybinding> data structure
 * indended to be presented to the user.
 */
using Gee;

public class Keybinding {
    public string label { get; private set; }
    public string spec { get; private set; }
    public string exec { get; set; }
    // The keys of the row's binding lines, in the order they are written
    public ArrayList<BoundKeys> bound_keys { get; private set; }

    public Keybinding (string label, string spec) {
        this.label = label;
        this.spec = spec;
        this.bound_keys = new ArrayList<BoundKeys> ();
    }
}

/**
 * The keys of one bindsym or bindcode line, past its options and with its variables
 * replaced: "Mod4+Shift+Return", or for bindcode a keycode such as "Mod4+36".
 */
public class BoundKeys {
    public string combination { get; private set; }
    public bool is_keycode { get; private set; }
    // false once a later line binds the same keys again or unbinds them (sway)
    public bool active { get; set; default = true; }

    public BoundKeys (string combination, bool is_keycode) {
        this.combination = combination;
        this.is_keycode = is_keycode;
    }
}

public errordomain PARSE_ERROR {
    BAD_PARAM_MATCH
}

public class ConfigParser {
    private const string REMONTOIRE_LINE_WRAPPER = "##";
    private const string REMONTIORE_PARAM_DELIMITER = "//";
    private const int PARAMETER_COUNT = 3;
    private const int MIN_LINE_LENGTH = 13; // "##x//y//z//##".length
    private const string DEFAULT_MODE = "default";
    // The configuration text in pieces, each from a single file
    private string[] configs;
    private string line_prefix;
    // Form commands as sway does while it reads its configuration: sway hands its files
    // over as written, while i3 reports them with every variable already replaced.
    // Bindings follow sway too: a later binding of the same keys replaces an earlier one.
    private bool replace_variables;
    // Resource values for set_from_resource (under sway, the ones trawl serves)
    private HashTable<string, string> ? resources;
    // Variables defined so far in the reading, by name (without the '$')
    private HashTable<string, string> variables = new HashTable<string, string> (str_hash, str_equal);
    // sway: the keys bound so far, by binding_identity()
    private HashMap<string, BoundKeys> bound = new HashMap<string, BoundKeys> ();

    public ConfigParser (string config, string line_prefix, bool replace_variables = false, HashTable<string, string> ? resources = null) {
        this.from_files({ config }, line_prefix, replace_variables, resources);
    }

    /**
     * A configuration in several pieces read one after the other, such as the files
     * i3 reports: a row's bindings are taken from the row's own piece.
     */
    public ConfigParser.from_files (string[] configs, string line_prefix, bool replace_variables = false, HashTable<string, string> ? resources = null) {
        this.configs = configs;
        this.line_prefix = line_prefix;
        this.replace_variables = replace_variables;
        this.resources = resources;
    }

    public Map<string, ArrayList<Keybinding> > parse() throws PARSE_ERROR, GLib.Error, Ilia.WM_ERROR {
        var config_map = new TreeMap<string, ArrayList<Keybinding> >();
        var prefix = REMONTOIRE_LINE_WRAPPER;
        if (line_prefix != "")
            prefix = line_prefix + REMONTOIRE_LINE_WRAPPER;

        foreach (unowned string config in configs)
            parse_piece(config, prefix, config_map);

        return config_map;
    }

    /**
     * The rows of one piece of the configuration. A row's first binding line is the
     * next one at the row's block level, before the next row there; it gives the row
     * its command. The binding lines right after it, with only comments and set lines
     * in between, belong to the row too. A block, such as a mode, has rows of its own,
     * and a row whose binding follows the block, such as the one entering the mode,
     * still finds it.
     */
    private void parse_piece(string config, string prefix, Map<string, ArrayList<Keybinding> > config_map) throws PARSE_ERROR {
        // Per block level, outermost first: the row still to find its first binding line
        var waiting = new ArrayList<Keybinding ?> ();
        // Per block level: the mode its bindings are in
        var modes = new ArrayList<string> ();
        waiting.add(null);
        modes.add(DEFAULT_MODE);
        // The row taking the binding lines that follow
        Keybinding row = null;

        foreach (unowned string line in config.split("\n")) {
            string trimmedLine = line.strip();
            int level = waiting.size - 1;

            if (lineMatch(trimmedLine, prefix)) {
                if (line_prefix != "")
                    trimmedLine = trimmedLine.substring(line_prefix.length);
                waiting[level] = parseLine(trimmedLine, config_map);
                row = null;
            } else if (trimmedLine.length == 0) {
                row = null;
            } else if (trimmedLine.has_prefix("#")) {
                continue;
            } else if (replace_variables && parseVariableLine(trimmedLine)) {
                continue;
            } else if (setMatch(trimmedLine)) {
                continue;
            } else if (bindingMatch(trimmedLine)) {
                var keys = parseBindingKeys(trimmedLine, modes[level]);
                if (row == null && waiting[level] != null) {
                    row = waiting[level];
                    waiting[level] = null;
                    row.exec = parseExecLine(trimmedLine);
                }
                if (row != null && keys != null)
                    row.bound_keys.add(keys);
            } else {
                // Any other line ends the row's bindings
                row = null;
                if (trimmedLine.has_suffix("{")) {
                    waiting.add(null);
                    modes.add(blockMode(trimmedLine) ?? modes[level]);
                } else if (trimmedLine == "}" && level > 0) {
                    waiting.remove_at(level);
                    modes.remove_at(level);
                } else if (replace_variables) {
                    parseUnbindLine(trimmedLine, modes[level]);
                }
            }
        }
    }

    // A "set" or "set_from_resource" line, whichever variable it names
    private static bool setMatch(string line) {
        string[] words = split_words(line);
        return words.length > 0 && (words[0] == "set" || words[0] == "set_from_resource");
    }

    /**
     * The mode of the bindings in a block: the name of a "mode [--pango_markup] <name> {"
     * block; for any other block, such as a bar, the block itself. null for no name.
     */
    private string ? blockMode(string line) {
        string[] words = split_words(replace_variables ? replace(line) : line);
        if (words.length == 0 || words[0] != "mode")
            return line;
        int i = 1;
        while (i < words.length && words[i].has_prefix("--"))
            i++;
        if (i >= words.length || words[i] == "{")
            return null;
        string name = words[i];
        if (name.length >= 2 && (name[0] == '"' || name[0] == '\'') && name[name.length - 1] == name[0])
            name = name.substring(1, name.length - 2);
        return name;
    }

    /**
     * The keys of a binding line, "bindsym|bindcode [--option ...] <keys> <command>",
     * with the variables replaced as the window manager does. Under sway, they take the
     * place of any earlier binding of the same keys.
     */
    private BoundKeys ? parseBindingKeys(string line, string mode) {
        string[] words = split_words(replace_variables ? replace(line) : line);
        int i = 1;
        while (i < words.length && words[i].has_prefix("--"))
            i++;
        if (i >= words.length)
            return null;

        var keys = new BoundKeys(words[i], words[0] == "bindcode");
        if (replace_variables) {
            string identity = binding_identity(mode, words[0], words[1: i], words[i]);
            if (bound.has_key(identity))
                bound[identity].active = false;
            bound[identity] = keys;
        }
        return keys;
    }

    // sway: "unbindsym|unbindcode [--option ...] <keys>" takes the keys from their binding
    private void parseUnbindLine(string line, string mode) {
        string[] words = split_words(replace(line));
        if (words.length == 0 || (words[0] != "unbindsym" && words[0] != "unbindcode"))
            return;
        int i = 1;
        while (i < words.length && words[i].has_prefix("--"))
            i++;
        if (i >= words.length)
            return;

        string identity = binding_identity(mode, words[0].substring(2), words[1: i], words[i]);
        BoundKeys keys;
        if (bound.unset(identity, out keys))
            keys.active = false;
    }

    // A modifier as sway names it, whatever alias or letter case it is written in; null for a key
    private static string ? canonical_modifier(string name) {
        switch (name.ascii_down()) {
            case "shift": return "Shift";
            case "lock":
            case "caps": return "Lock";
            case "ctrl":
            case "control": return "Control";
            case "mod1":
            case "alt": return "Mod1";
            case "mod2": return "Mod2";
            case "mod3": return "Mod3";
            case "mod4":
            case "super":
            case "logo": return "Mod4";
            case "mod5": return "Mod5";
            default: return null;
        }
    }

    /**
     * What tells sway's bindings apart: the mode, the kind of binding, the options
     * that make a binding distinct, the modifiers in any order and spelling, and the
     * keys in any order and letter case.
     */
    private static string binding_identity(string mode, string kind, string[] options, string combination) {
        var distinct_options = new TreeSet<string> ();
        foreach (unowned string option in options) {
            if (option != "--no-warn" && option != "--no-repeat")
                distinct_options.add(option);
        }

        var modifiers = new TreeSet<string> ();
        var keys = new TreeSet<string> ();
        foreach (unowned string part in combination.split("+")) {
            string ? modifier = canonical_modifier(part);
            if (modifier != null)
                modifiers.add(modifier);
            else
                keys.add(part.ascii_down());
        }

        return string.joinv("\n", {
            mode,
            kind,
            string.joinv(" ", distinct_options.to_array()),
            string.joinv("+", modifiers.to_array()),
            string.joinv("+", keys.to_array())
        });
    }

    // A binding line, "bindsym ..." or "bindcode ..."
    private bool bindingMatch(string line) {
        return line.has_prefix("bindsym ") || line.has_prefix("bindsym\t") ||
               line.has_prefix("bindcode ") || line.has_prefix("bindcode\t");
    }

    /**
     * The command of a binding line: "bindsym|bindcode [--option ...] <keys> <command>".
     *
     * i3 reports its files with every variable already replaced, and holds the text
     * after the keys as written. sway replaces the variables while it reads the line,
     * with the values they have at that point, and holds the remaining words joined
     * by single spaces. Options such as --release or --to-code are not part of the
     * command, and quotes are kept either way.
     */
    private string ? parseExecLine(string line) {
        string ? command = null;

        if (!replace_variables) {
            int pos = 0;
            next_token(line, ref pos);   // bindsym
            string ? token = null;
            do {
                token = next_token(line, ref pos);
            } while (token != null && token.has_prefix("--"));
            if (token == null)   // no keys
                return null;
            command = line.substring(pos).strip();
        } else {
            string[] words = split_words(replace(line));
            int i = 1;
            while (i < words.length && words[i].has_prefix("--"))
                i++;
            i++;   // keys
            if (i < words.length)
                command = string.joinv(" ", words[i: words.length]);
        }

        return command != null && command.length > 0 ? command : null;
    }

    /**
     * "set $name value..." and "set_from_resource $name key [default...]", as sway
     * reads them. The rest of the line has its variables replaced, but not the name
     * being set, and the value is the remaining words joined by single spaces, quotes
     * included. A resource that is unset or empty takes the default; with neither the
     * variable is left as it was. Returns false for any other line.
     */
    private bool parseVariableLine(string line) {
        string[] words = split_words(line);

        if (words.length >= 2 && words[0] == "set" && words[1].has_prefix("$")) {
            string name = words[1].substring(1);
            string value = line.substring("set".length).strip().substring(words[1].length);
            variables.set(name, join_words(replace(value)));
            return true;
        }

        if (words.length >= 3 && words[0] == "set_from_resource" && words[1].has_prefix("$")) {
            string name = words[1].substring(1);
            string key = replace(words[2]);
            string ? resource = resources != null ? resources.lookup(key) : null;
            if (resource != null && resource != "")
                variables.set(name, resource);
            else if (words.length > 3)
                variables.set(name, join_words(replace(string.joinv(" ", words[3: words.length]))));
            return true;
        }

        return false;
    }

    // The words of text joined by single spaces
    private static string join_words(string text) {
        return string.joinv(" ", split_words(text));
    }

    private static bool is_name_char(char c) {
        return c.isalnum() || c == '_' || c == '.' || c == '-';
    }

    /**
     * Replace every $name in text by the value the variable has now. Where several
     * defined names start at the same '$', the longest one wins; an unknown $name is
     * left as written.
     */
    private string replace(string text) {
        if (!text.contains("$"))
            return text;

        var result = new StringBuilder();
        int i = 0;
        while (i < text.length) {
            if (text[i] != '$') {
                result.append_c(text[i]);
                i++;
                continue;
            }

            int end = i + 1;
            while (end < text.length && is_name_char(text[end]))
                end++;

            string ? name = null;
            for (int len = end - i - 1; len > 0; len--) {
                string candidate = text.substring(i + 1, len);
                if (variables.contains(candidate)) {
                    name = candidate;
                    break;
                }
            }

            if (name != null) {
                result.append(variables.get(name));
                i += 1 + name.length;
            } else {
                result.append(text.substring(i, end - i));
                i = end;
            }
        }
        return result.str;
    }

    /**
     * Split a line into words at spaces and tabs, except inside quotes or a leading
     * [criteria]; a backslash escapes the next character. The words keep their quotes
     * and backslashes.
     */
    private static string[] split_words(string line) {
        string[] words = {};
        var word = new StringBuilder();
        bool in_single = false, in_double = false, in_criteria = false, escaped = false;

        for (int i = 0; i < line.length; i++) {
            char c = line[i];

            if (escaped) {
                escaped = false;
            } else if (in_single) {
                in_single = c != '\'';
            } else if (in_double) {
                if (c == '\\')
                    escaped = true;
                else if (c == '"')
                    in_double = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (in_criteria) {
                if (c == '"')
                    in_double = true;
                else if (c == '\'')
                    in_single = true;
                else if (c == ']')
                    in_criteria = false;
            } else if (c == '\'') {
                in_single = true;
            } else if (c == '"') {
                in_double = true;
            } else if (c == '[' && word.len == 0) {
                in_criteria = true;
            } else if (c == ' ' || c == '\t') {
                if (word.len > 0) {
                    words += word.str;
                    word.truncate(0);
                }
                continue;
            }

            word.append_c(c);
        }

        if (word.len > 0)
            words += word.str;
        return words;
    }

    // The next whitespace-delimited token of line at or after pos; pos moves past it.
    private static string ? next_token(string line, ref int pos) {
        while (pos < line.length && line[pos].isspace()) pos++;
        if (pos >= line.length) return null;
        int start = pos;
        while (pos < line.length && !line[pos].isspace()) pos++;
        return line.substring(start, pos - start);
    }

    private bool lineMatch(string line, string prefix) {

        return line.length > MIN_LINE_LENGTH &&
               line.has_prefix(prefix) &&
               line.substring(REMONTOIRE_LINE_WRAPPER.length + 1).contains(REMONTOIRE_LINE_WRAPPER) &&
               line.contains(REMONTIORE_PARAM_DELIMITER);
    }

    /**
     * ## category // action // keybinding ## anything else
     */
    private Keybinding parseLine(string line, Map<string, ArrayList<Keybinding> > configMap) throws PARSE_ERROR.BAD_PARAM_MATCH {
        // Find end of machine-parsable section of line.
        int termSequenceIndex = line.index_of("##", 3);
        // Extract machine-parsable section of line.
        string valueList = line.substring(REMONTOIRE_LINE_WRAPPER.length, termSequenceIndex - REMONTOIRE_LINE_WRAPPER.length);
        // Tokenize parameters
        string[] values = valueList.split(REMONTIORE_PARAM_DELIMITER);

        if (values.length != PARAMETER_COUNT)
            throw new PARSE_ERROR.BAD_PARAM_MATCH("Invalid line: " + line + "\n");

        string category = values[0].strip();
        string label = values[1].strip();
        string spec = values[2].strip();

        if (!configMap.has_key(category)) configMap.set(category, new ArrayList<Keybinding>());

        var binding = new Keybinding(label, spec);
        configMap.get(category).add(binding);

        return binding;
    }
}
