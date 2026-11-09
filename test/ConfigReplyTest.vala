using GLib;

// A GET_CONFIG reply: the main configuration and, as i3 sends it, the included files
Json.Node config_reply(string config, string[] included_contents) {
    var builder = new Json.Builder();
    builder.begin_object();
    builder.set_member_name("config");
    builder.add_string_value(config);
    builder.set_member_name("included_configs");
    builder.begin_array();
    foreach (unowned string contents in included_contents) {
        builder.begin_object();
        builder.set_member_name("variable_replaced_contents");
        builder.add_string_value(contents);
        builder.end_object();
    }
    builder.end_array();
    builder.end_object();
    return builder.get_root();
}

// A GET_CONFIG reply from i3 4.20 or later, which sends each file as written too
Json.Node i3_reply(string[] raw_contents, string[] replaced_contents) {
    var builder = new Json.Builder();
    builder.begin_object();
    builder.set_member_name("config");
    builder.add_string_value(raw_contents[0]);
    builder.set_member_name("included_configs");
    builder.begin_array();
    for (int i = 0; i < raw_contents.length; i++) {
        builder.begin_object();
        builder.set_member_name("raw_contents");
        builder.add_string_value(raw_contents[i]);
        builder.set_member_name("variable_replaced_contents");
        builder.add_string_value(replaced_contents[i]);
        builder.end_object();
    }
    builder.end_array();
    builder.end_object();
    return builder.get_root();
}

Ilia.ConfigReply reply_for(Json.Node reply, string wm_name) {
    try {
        return new Ilia.ConfigReply(reply, wm_name);
    } catch (GLib.Error e) {
        error("ConfigReply failed: %s", e.message);
    }
}

string make_dir() {
    try {
        return DirUtils.make_tmp("ilia-config-test-XXXXXX");
    } catch (GLib.Error e) {
        error("no temporary directory: %s", e.message);
    }
}

void write_file(string path, string contents) {
    try {
        DirUtils.create_with_parents(Path.get_dirname(path), 0755);
        FileUtils.set_contents(path, contents);
    } catch (GLib.Error e) {
        error("cannot write %s: %s", path, e.message);
    }
}

string read_config(Json.Node reply, string wm_name) {
    try {
        return new Ilia.ConfigReply(reply, wm_name).config;
    } catch (GLib.Error e) {
        error("ConfigReply failed: %s", e.message);
    }
}

// i3: a file that does not end with a newline does not run into the next one
void test_i3_files_on_separate_lines() {
    var config = read_config(config_reply("", { "set $a 1\nbindsym x exec a", "## Group // Row // x ##\nbindsym y exec b\n" }), "i3");
    assert(config == "set $a 1\nbindsym x exec a\n## Group // Row // x ##\nbindsym y exec b\n");
}

// sway: each include is read where it appears, its matches in sorted order and each file once,
// relative to the including file; files stay on separate lines
void test_sway_includes_in_place() {
    var dir = make_dir();
    // created in reverse order, so directory order is not sorted order
    write_file(dir + "/parts/20_b", "set $a b\n");
    write_file(dir + "/parts/10_a", "set $a a\ninclude ../extra/c\ninclude 10_a\n");
    write_file(dir + "/extra/c", "set $a c");

    var main_config = "set $a 1\ninclude " + dir + "/parts/*\nset $a 3\n";
    var config = read_config(config_reply(main_config, {}), "sway");

    assert(config == "set $a 1\ninclude " + dir + "/parts/*\n" +
           "set $a a\ninclude ../extra/c\n" +
           "set $a c\n" +
           "include 10_a\n" +
           "set $a b\n" +
           "set $a 3\n");
}

// sway: include paths may use $NAME and ${NAME} from the environment; unknown names match nothing
void test_sway_include_environment() {
    var dir = make_dir();
    write_file(dir + "/x", "set $x 1\n");
    write_file(dir + "/y", "set $y 2\n");
    Environment.set_variable("ILIA_TEST_PARTS", dir, true);
    Environment.unset_variable("ILIA_TEST_UNSET");

    var main_config = "include $ILIA_TEST_PARTS/x\ninclude ${ILIA_TEST_PARTS}/y\ninclude $ILIA_TEST_UNSET/x\n";
    var config = read_config(config_reply(main_config, {}), "sway");

    assert(config == "include $ILIA_TEST_PARTS/x\nset $x 1\ninclude ${ILIA_TEST_PARTS}/y\nset $y 2\ninclude $ILIA_TEST_UNSET/x\n");
}

// i3: the files as i3 holds them with no resource set. As i3 does, a file's set lines are read
// before any variable in it is replaced, the last value winning, and the variables carry over
// to the files after it; names match in any letter case, the longest first, values are the rest
// of the line, and a line ending in a backslash runs on into the next one unless it is a comment
void test_i3_files_without_resources() {
    string[] raw = {
        "bindsym $mod+$key exec $Term\nset $mod Mod4\nset_from_resource $key wm.key Return\nset $term foot  -e\\\n   sh\n# set $mod Mod3 \\\nset $modifier Mod1\n",
        "set_from_resource $none wm.none\nbindsym $modifier+x exec $term$none.\n"
    };
    string[] replaced = {
        "bindsym Mod1+y exec ignored\n",
        "bindsym Mod1+x exec ignored\n"
    };
    var reply = reply_for(i3_reply(raw, replaced), "i3");

    assert(reply.configs.length == 2 && reply.configs[0] == replaced[0] && reply.configs[1] == replaced[1]);
    assert(reply.unset_resources_configs.length == 2);
    assert(reply.unset_resources_configs[0] ==
           "bindsym Mod4+Return exec foot  -e   sh\nset Mod4 Mod4\nset_from_resource Return wm.key Return\nset foot  -e   sh foot  -e   sh\n# set Mod4 Mod3 \\\nset Mod1 Mod1\n");
    assert(reply.unset_resources_configs[1] == "set_from_resource  wm.none\nbindsym Mod1+x exec foot  -e   sh.\n");
}

// i3 before 4.20 sends only the files as it holds them
void test_i3_files_without_raw_contents() {
    var reply = reply_for(config_reply("", { "bindsym Mod4+y exec a\n" }), "i3");
    assert(reply.unset_resources_configs.length == 1 && reply.unset_resources_configs[0] == "bindsym Mod4+y exec a\n");
}

// sway: the configuration in pieces, each from a single file, split where a file includes others
void test_sway_pieces() {
    var dir = make_dir();
    write_file(dir + "/parts/10_a", "## Group // Row // x ##\n");

    var main_config = "set $a 1\ninclude " + dir + "/parts/*\nbindsym x exec y\n";
    var reply = reply_for(config_reply(main_config, {}), "sway");

    assert(reply.configs.length == 3);
    assert(reply.configs[0] == "set $a 1\ninclude " + dir + "/parts/*\n");
    assert(reply.configs[1] == "## Group // Row // x ##\n");
    assert(reply.configs[2] == "bindsym x exec y\n");
    assert(reply.unset_resources_configs == null);
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/config_reply/i3_files_on_separate_lines", test_i3_files_on_separate_lines);
    Test.add_func("/config_reply/sway_includes_in_place", test_sway_includes_in_place);
    Test.add_func("/config_reply/sway_include_environment", test_sway_include_environment);
    Test.add_func("/config_reply/i3_files_without_resources", test_i3_files_without_resources);
    Test.add_func("/config_reply/i3_files_without_raw_contents", test_i3_files_without_raw_contents);
    Test.add_func("/config_reply/sway_pieces", test_sway_pieces);

    return Test.run();
}
