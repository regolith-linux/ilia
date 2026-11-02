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

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/config_reply/i3_files_on_separate_lines", test_i3_files_on_separate_lines);
    Test.add_func("/config_reply/sway_includes_in_place", test_sway_includes_in_place);
    Test.add_func("/config_reply/sway_include_environment", test_sway_include_environment);

    return Test.run();
}
