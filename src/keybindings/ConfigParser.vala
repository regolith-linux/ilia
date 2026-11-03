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

    public Keybinding (string label, string spec) {
        this.label = label;
        this.spec = spec;
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
    private string config;
    private string line_prefix;
    // Form commands as sway does while it reads its configuration: sway hands its files
    // over as written, while i3 reports them with every variable already replaced.
    private bool replace_variables;
    // Resource values for set_from_resource (under sway, the ones trawl serves)
    private HashTable<string, string> ? resources;
    // Variables defined so far in the reading, by name (without the '$')
    private HashTable<string, string> variables = new HashTable<string, string> (str_hash, str_equal);

    public ConfigParser (string config, string line_prefix, bool replace_variables = false, HashTable<string, string> ? resources = null) {
        this.config = config;
        this.line_prefix = line_prefix;
        this.replace_variables = replace_variables;
        this.resources = resources;
    }

    public Map<string, ArrayList<Keybinding> > parse() throws PARSE_ERROR, GLib.Error, Ilia.WM_ERROR {
        string[] lines = config.split("\n");

        if (lines == null || lines.length == 0) return Map.empty<string, ArrayList<Keybinding> >(); ;

        var config_map = new TreeMap<string, ArrayList<Keybinding> >();
        var prefix = REMONTOIRE_LINE_WRAPPER;
        if (line_prefix != "")
            prefix = line_prefix + REMONTOIRE_LINE_WRAPPER;

        Keybinding last_keybinding = null;

        foreach (unowned string line in lines) {
            string trimmedLine = line.strip();
            if (lineMatch(trimmedLine, prefix)) {
                if (line_prefix != "")
                    trimmedLine = trimmedLine.substring(line_prefix.length);
                last_keybinding = parseLine(trimmedLine, config_map);
            } else if (trimmedLine.has_prefix("#")) {
                continue;
            } else if (replace_variables && parseVariableLine(trimmedLine)) {
                continue;
            } else if (execMatch(trimmedLine) && last_keybinding != null) {
                last_keybinding.exec = parseExecLine(trimmedLine);
                last_keybinding = null;
            }
        }

        return config_map;
    }

    private bool execMatch(string line) {
        return line.has_prefix("bindsym ") || line.has_prefix("bindsym\t");
    }

    /**
     * The command of a binding line: "bindsym [--option ...] <keys> <command>".
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
