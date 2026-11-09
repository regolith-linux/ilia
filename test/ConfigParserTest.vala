using GLib;
using Gee;

// The command of the row with this label, as the keybindings page would run it.
// sway: replace the variables as sway does, with these resource values.
string ? command_of(string config, string label, bool sway = false, HashTable<string, string> ? resources = null) {
    try {
        var rows = new ConfigParser(config, "", sway, resources).parse();
        foreach (var bindings in rows.values)
            foreach (var binding in bindings)
                if (binding.label == label)
                    return binding.exec;
    } catch (GLib.Error e) {
        error("parse failed: %s", e.message);
    }
    error("no row %s", label);
}

// The row with this label
Keybinding row_of(Map<string, ArrayList<Keybinding> > rows, string label) {
    foreach (var bindings in rows.values)
        foreach (var binding in bindings)
            if (binding.label == label)
                return binding;
    error("no row %s", label);
}

Map<string, ArrayList<Keybinding> > parse_pieces(string[] pieces, bool sway = false, HashTable<string, string> ? resources = null) {
    try {
        return new ConfigParser.from_files(pieces, "", sway, resources).parse();
    } catch (GLib.Error e) {
        error("parse failed: %s", e.message);
    }
}

// The keys of a row, "code:" marking keycodes and "-" keys no longer bound, joined by spaces
string keys_of(Map<string, ArrayList<Keybinding> > rows, string label) {
    string[] keys = {};
    foreach (var keys_bound in row_of(rows, label).bound_keys)
        keys += (keys_bound.active ? "" : "-") + (keys_bound.is_keycode ? "code:" : "") + keys_bound.combination;
    return string.joinv(" ", keys);
}

// i3 reports its files with the variables replaced, including in set_from_resource lines
const string I3_CONFIG = """
set_from_resource ilia -p apps wm.program.launcher.app ilia -p apps
## Launch // Application // <> Space ##
bindsym Mod4+space exec --no-startup-id ilia -p apps
## Launch // Greeting // <><Shift> g ##
bindsym --release --to-code Mod4+Shift+g exec --no-startup-id notify-send 'Regolith says' Hi  there
## Session // Exit App // <><Shift> q ##
bindsym	Mod4+Shift+q [con_id="__focused__"] kill
## Resize // Enter Resize Mode // <> r ##
## Resize // Exit Resize Mode // Escape or Enter ##
bindsym Return mode "default"
bindsym Escape mode "other"
""";

// The text after the keys, as i3 holds it: no second round of replacement
void test_i3_command_as_written() {
    assert(command_of(I3_CONFIG, "Application") == "exec --no-startup-id ilia -p apps");
    assert(command_of(I3_CONFIG, "Exit App") == "[con_id=\"__focused__\"] kill");
}

// Options before the keys are not part of the command; the rest is kept verbatim
void test_i3_options_skipped() {
    assert(command_of(I3_CONFIG, "Greeting") == "exec --no-startup-id notify-send 'Regolith says' Hi  there");
}

// A row runs the first binding under its comment; a row with none runs nothing
void test_first_binding_of_row() {
    assert(command_of(I3_CONFIG, "Exit Resize Mode") == "mode \"default\"");
    assert(command_of(I3_CONFIG, "Enter Resize Mode") == null);
}

// sway hands its files over as written
const string SWAY_CONFIG = """
set $mod Mod4
set $wm Mod1
set $wm.binding.help question
set_from_resource $ws1 wm.workspace.01.name "1"
set $ws1 "$ws1"
set_from_resource $ilia.stylesheet ilia.stylesheet
set_from_resource $greeting wm.greeting Hi  there
set_from_resource $empty wm.empty fallback  value
# set $mod Mod3
## Navigate // Workspace 1 // <> 1 ##
bindsym $mod+1 workspace number $ws1
## Launch // Application // <> Space ##
bindsym $mod+space exec --no-startup-id ilia -p apps -t $ilia.stylesheet
## Launch // Greeting // <><Shift> g ##
bindsym --release $mod+Shift+g exec notify-send 'Regolith  says' $greeting
## Launch // Fallback // <><Shift> f ##
bindsym $mod+Shift+f exec echo $empty
## Launch // Names // <><Shift> n ##
bindsym --to-code --locked $mod+$wm.binding.help exec echo $wm.binding.help $wm.x $mod $unknown
set $next xkb_switch_layout next
## Keyboard // Next Layout // <> n ##
bindsym $mod+n exec $next
set $next xkb_switch_layout prev
## Keyboard // Previous Layout // <> p ##
bindsym $mod+p exec $next
## Session // Exit App // <><Shift> q ##
bindsym $mod+Shift+q [con_id="__focused__"]   kill
""";

// Defaults when no resource is set; quotes are kept, so "$ws1" wraps the quoted default again
void test_sway_defaults() {
    assert(command_of(SWAY_CONFIG, "Workspace 1", true) == "workspace number \"\"1\"\"");
    assert(command_of(SWAY_CONFIG, "Greeting", true) == "exec notify-send 'Regolith  says' Hi there");
    assert(command_of(SWAY_CONFIG, "Fallback", true) == "exec echo fallback value");
    // no resource and no default: the variable stays undefined and is left as written
    assert(command_of(SWAY_CONFIG, "Application", true) == "exec --no-startup-id ilia -p apps -t $ilia.stylesheet");
}

// Resource values replace the defaults; an empty value counts as unset
void test_sway_resources() {
    var resources = new HashTable<string, string> (str_hash, str_equal);
    resources.insert("wm.workspace.01.name", "1: Web");
    resources.insert("ilia.stylesheet", "/tmp/ilia.css");
    resources.insert("wm.greeting", "Hello  world");
    resources.insert("wm.empty", "");

    assert(command_of(SWAY_CONFIG, "Workspace 1", true, resources) == "workspace number \"1: Web\"");
    assert(command_of(SWAY_CONFIG, "Application", true, resources) == "exec --no-startup-id ilia -p apps -t /tmp/ilia.css");
    assert(command_of(SWAY_CONFIG, "Greeting", true, resources) == "exec notify-send 'Regolith  says' Hello world");
    assert(command_of(SWAY_CONFIG, "Fallback", true, resources) == "exec echo fallback value");
}

// The longest defined name wins, unknown names stay, commented lines set nothing,
// and options before the keys are not part of the command
void test_sway_names() {
    assert(command_of(SWAY_CONFIG, "Names", true) == "exec echo question Mod1.x Mod4 $unknown");
    assert(command_of(SWAY_CONFIG, "Exit App", true) == "[con_id=\"__focused__\"] kill");
}

// A binding takes the values its variables have where it is read, as sway does
void test_sway_value_at_binding() {
    assert(command_of(SWAY_CONFIG, "Next Layout", true) == "exec xkb_switch_layout next");
    assert(command_of(SWAY_CONFIG, "Previous Layout", true) == "exec xkb_switch_layout prev");
}

// i3 as it reports its files: variables replaced
const string I3_ROWS = """
## Launch // Terminal // <> Enter ##
set_from_resource Return wm.binding.terminal Return
bindsym Mod4+Return exec term
# a remark between the bindings of one row
bindsym --release --border Mod4+Shift+Return exec term2
bindcode Mod4+36 exec term3

bindsym Mod4+t exec after-blank
## Resize // Enter Resize Mode // <> r ##
mode "Resize Mode" {
    ## Resize // Resize Window // ← → ##
    bindsym Left resize shrink width 6 px
    bindsym Right resize grow width 6 px

    bindsym Escape mode "default"
}
set_from_resource r wm.binding.resize_mode r
bindsym Mod4+r mode "Resize Mode"
## Other // Closed // <> o ##
bindsym Mod4+o exec o
for_window [class="x"] floating enable
bindsym Mod4+p exec p
## Other // Keycode First // <> 1 ##
bindcode Mod4+10 workspace number 1
bindsym Mod4+1 workspace number 1
## Other // Bar // <> b ##
bar {
    bindsym button4 nop
}
""";

// A row's keys come from the binding lines that follow it, past their options, up to a
// blank line or a line of another kind; bindcode lines count, their keys marked as codes
void test_row_keys() {
    var rows = parse_pieces({ I3_ROWS });
    assert(keys_of(rows, "Terminal") == "Mod4+Return Mod4+Shift+Return code:Mod4+36");
    assert(row_of(rows, "Terminal").exec == "exec term");
    assert(keys_of(rows, "Closed") == "Mod4+o");
    assert(keys_of(rows, "Keycode First") == "code:Mod4+10 Mod4+1");
    assert(row_of(rows, "Keycode First").exec == "workspace number 1");
}

// A block has rows of its own; the row before it takes the first binding after it at its own level
void test_row_around_block() {
    var rows = parse_pieces({ I3_ROWS });
    assert(keys_of(rows, "Resize Window") == "Left Right");
    assert(keys_of(rows, "Enter Resize Mode") == "Mod4+r");
    assert(row_of(rows, "Enter Resize Mode").exec == "mode \"Resize Mode\"");
    // the bindings of a bar block are not the window manager's keys
    assert(keys_of(rows, "Bar") == "");
    assert(row_of(rows, "Bar").exec == null);
}

// A row does not run on into the next piece of the configuration
void test_row_within_piece() {
    var rows = parse_pieces({ "## Group // Row // x ##\n", "bindsym x exec y\n" });
    assert(keys_of(rows, "Row") == "");
    assert(row_of(rows, "Row").exec == null);
}

const string SWAY_ROWS = """
set $mod Mod4
set_from_resource $wm.binding.terminal wm.binding.terminal Return
## Launch // Terminal // <> Enter ##
bindsym $mod+$wm.binding.terminal exec term
## Launch // Browser // <><Shift> b ##
bindsym --to-code $mod+Shift+b exec browser
## Launch // Other // <> x ##
bindsym --release $mod+x exec released
bindsym $mod+x exec pressed
mode "Resize Mode" {
    ## Resize // Exit // Escape ##
    bindsym Escape mode "default"
}
""";

// sway: the keys take the values the variables have where the binding is read, resources included
void test_sway_row_keys() {
    assert(keys_of(parse_pieces({ SWAY_ROWS }, true), "Terminal") == "Mod4+Return");

    var resources = new HashTable<string, string> (str_hash, str_equal);
    resources.insert("wm.binding.terminal", "y");
    assert(keys_of(parse_pieces({ SWAY_ROWS }, true, resources), "Terminal") == "Mod4+y");
}

// sway: a later binding of the same keys in the same mode, in any spelling, replaces an earlier
// one, and unbinding takes them; options such as --release make keys distinct, --to-code does too
void test_sway_rebinding() {
    var rows = parse_pieces({ SWAY_ROWS,
                              "bindsym super+return exec other\n" +
                              "bindsym Mod4+Shift+B exec other\n" +
                              "unbindsym --release Mod4+x\n" +
                              "bindsym Escape exec other\n" }, true);
    assert(keys_of(rows, "Terminal") == "-Mod4+Return");
    assert(keys_of(rows, "Browser") == "Mod4+Shift+b");
    assert(keys_of(rows, "Other") == "-Mod4+x Mod4+x");
    // bindings in another mode are other keys
    assert(keys_of(rows, "Exit") == "Escape");

    rows = parse_pieces({ SWAY_ROWS, "bindsym --to-code Mod4+B+Shift exec other\n" }, true);
    assert(keys_of(rows, "Browser") == "-Mod4+Shift+b");
}

// i3 refuses a second binding of the same keys, so it never replaces the first
void test_i3_no_rebinding() {
    var rows = parse_pieces({ I3_ROWS, "bindsym Mod4+Return exec other\n" });
    assert(keys_of(rows, "Terminal") == "Mod4+Return Mod4+Shift+Return code:Mod4+36");
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/config_parser/i3_command_as_written", test_i3_command_as_written);
    Test.add_func("/config_parser/i3_options_skipped", test_i3_options_skipped);
    Test.add_func("/config_parser/first_binding_of_row", test_first_binding_of_row);
    Test.add_func("/config_parser/sway_defaults", test_sway_defaults);
    Test.add_func("/config_parser/sway_resources", test_sway_resources);
    Test.add_func("/config_parser/sway_names", test_sway_names);
    Test.add_func("/config_parser/sway_value_at_binding", test_sway_value_at_binding);
    Test.add_func("/config_parser/row_keys", test_row_keys);
    Test.add_func("/config_parser/row_around_block", test_row_around_block);
    Test.add_func("/config_parser/row_within_piece", test_row_within_piece);
    Test.add_func("/config_parser/sway_row_keys", test_sway_row_keys);
    Test.add_func("/config_parser/sway_rebinding", test_sway_rebinding);
    Test.add_func("/config_parser/i3_no_rebinding", test_i3_no_rebinding);

    return Test.run();
}
