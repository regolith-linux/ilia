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

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/config_parser/i3_command_as_written", test_i3_command_as_written);
    Test.add_func("/config_parser/i3_options_skipped", test_i3_options_skipped);
    Test.add_func("/config_parser/first_binding_of_row", test_first_binding_of_row);
    Test.add_func("/config_parser/sway_defaults", test_sway_defaults);
    Test.add_func("/config_parser/sway_resources", test_sway_resources);
    Test.add_func("/config_parser/sway_names", test_sway_names);
    Test.add_func("/config_parser/sway_value_at_binding", test_sway_value_at_binding);

    return Test.run();
}
