/**
 * This class retrieves the i3 config file over IPC and 
 * produces a [Category] -> List<Keybinding> data structure
 * indended to be presented to the user.
 */
using Gee;

public class Keybinding {
  public string label { get; private set; }
  public string spec { get; private set; }

  public Keybinding(string label, string spec) {
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

  public ConfigParser(string config, string line_prefix) {
    this.config = config;
    this.line_prefix = line_prefix;
  }

  public Map<string, ArrayList<Keybinding>> parse() throws PARSE_ERROR, GLib.Error, Grelier.I3_ERROR {    
    string[] lines = config.split("\n");

    if (lines == null || lines.length == 0) return Map.empty<string, ArrayList<Keybinding>>();;

    var config_map = new TreeMap<string, ArrayList<Keybinding>>();
    var prefix = REMONTOIRE_LINE_WRAPPER;
    if (line_prefix != "") {
        prefix = line_prefix + REMONTOIRE_LINE_WRAPPER;
    }

    foreach (unowned string line in lines) {
      string trimmedLine = line.strip();
      if (lineMatch(trimmedLine, prefix)) {
        if (line_prefix != "") {
          trimmedLine = trimmedLine.substring(line_prefix.length);
        }
        parseLine(trimmedLine, config_map);
      }
    }

    // debugConfigMap(config_map);

    return config_map;
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
  private void parseLine(string line, Map<string, ArrayList<Keybinding>> configMap) throws PARSE_ERROR.BAD_PARAM_MATCH {
    // Find end of machine-parsable section of line.
    int termSequenceIndex = line.index_of("##", 3);
    // Extract machine-parsable section of line.
    string valueList = line.substring(REMONTOIRE_LINE_WRAPPER.length, termSequenceIndex - REMONTOIRE_LINE_WRAPPER.length);
    // Tokenize parameters
    string[] values = valueList.split(REMONTIORE_PARAM_DELIMITER);

    if (values.length != PARAMETER_COUNT) {
      throw new PARSE_ERROR.BAD_PARAM_MATCH("Invalid line: " + line + "\n");
    }

    string category = values[0].strip();
    string label = values[1].strip();
    string spec = values[2].strip();

    if (!configMap.has_key(category)) configMap.set(category, new ArrayList<Keybinding>());

    configMap.get(category).add(new Keybinding(label, spec));    
  }

  /** 
   * Ths method takes in a string and produces a list of strings. Ex:
   * "<super><shift>a b c" -> [<super>, <shift>, a, b, c]
  */
  public static GLib.List<string> parse_keybinding(string raw_keybinding) {
    var tokens = new GLib.List<string>();
    var str_builder = new StringBuilder();

    unichar c;
    for (int i = 0; raw_keybinding.get_next_char (ref i, out c);) {
        switch(c) {
            case '<':
                if (str_builder.len > 0) {
                    string token = str_builder.str;
                    tokens.append(token);
                    str_builder.erase(0);
                }
                str_builder.append(c.to_string ());
                break;
            case '>':
                str_builder.append(c.to_string ());
                string token = str_builder.str;
                tokens.append(token);
                str_builder.erase(0);
                break;
            case ' ': 
                if (str_builder.len > 0) {
                    string token = str_builder.str;
                    tokens.append(token);
                    str_builder.erase(0);
                }
                break;
            default:
                str_builder.append(c.to_string ());
                break;
        }
    }

    if (str_builder.len > 0) {
        string token = str_builder.str;
        tokens.append(token);
        str_builder.erase(0);
    }

    return tokens;
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
