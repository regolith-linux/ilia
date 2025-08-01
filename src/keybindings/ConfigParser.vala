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

    public ConfigParser (string config, string line_prefix) {
        this.config = config;
        this.line_prefix = line_prefix;
    }

    public Map<string, ArrayList<Keybinding> > parse() throws PARSE_ERROR, GLib.Error, Ilia.WM_ERROR {
        string[] lines = config.split("\n");

        if (lines == null || lines.length == 0) return Map.empty<string, ArrayList<Keybinding> >(); ;

        var config_map = new TreeMap<string, ArrayList<Keybinding> >();
        var prefix = REMONTOIRE_LINE_WRAPPER;
        if (line_prefix != "")
            prefix = line_prefix + REMONTOIRE_LINE_WRAPPER;

        Keybinding last_keybinding = null;
        var variableMap = new HashTable<string, string>(str_hash, str_equal);

        foreach (unowned string line in lines) {
            string trimmedLine = line.strip();
            if (lineMatch(trimmedLine, prefix)) {
                if (line_prefix != "")
                    trimmedLine = trimmedLine.substring(line_prefix.length);
                last_keybinding = parseLine(trimmedLine, config_map);
            } else if (execMatch(trimmedLine) && last_keybinding != null) {
                last_keybinding.exec = parseExecLine(trimmedLine, variableMap);
                // stdout.printf("got %s\n", last_keybinding.exec);
                last_keybinding = null;
            } else if (setFromResourceMatch(trimmedLine)) {
                parseSetFromResourceLine(trimmedLine, variableMap);
            }
        }

        // debugConfigMap(config_map);

        return config_map;
    }

    private void parseSetFromResourceLine(string line, HashTable<string, string> varmap) {
        var sp1 = line.index_of_char(' ');
        var sp2 = line.index_of_char(' ', sp1 + 1);
        var sp3 = line.index_of_char(' ', sp2 + 1);

        var key = line.substring(sp1, (sp2 - sp1)).strip();
        var val = line.substring(sp3 + 1).strip().strip();

        if (key.length > 0 && val.length > 0)
            varmap.insert(key, val);
    }

    // set_from_resource $i3-wm.floatingwindow.border.size i3-wm.floatingwindow.border.size 1
    private bool setFromResourceMatch(string line) {
        return line.length > MIN_LINE_LENGTH &&
               line.has_prefix("set_from_resource ");
    }

    private bool execMatch(string line) {
        return line.length > MIN_LINE_LENGTH &&
               line.has_prefix("bindsym ");
    }

    private string parseExecLine(string line, HashTable<string, string> varmap) {
        var sp1 = line.index_of_char(' ');
        var sp2 = line.index_of_char(' ', sp1 + 1);

        var exec_expr = line.substring(sp2 + 1).strip();

        string[] tokens = exec_expr.split(" ");
        string final_expr = "";

        foreach (unowned string token in tokens) {
            // TODO: Read from Xresources
            if (varmap.contains(token))
                final_expr = final_expr + varmap.get(token) + " ";
            else
                final_expr = final_expr + token + " ";
        }

        return final_expr;
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

    /*
       private void debugConfigMap(Map<string, ArrayList<Keybinding>> configMap) {
       foreach (var entry in config_map.entries) {
        stdout.printf ("%s =>\n", entry.key);
        foreach (Keybinding k in entry.value) {
          stdout.printf ("      %s %s\n", k.label, k.spec);
        }
       }
       }
     */
}
