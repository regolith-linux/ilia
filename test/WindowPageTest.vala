using GLib;

// A container as i3 or sway reports it in GET_TREE
Ilia.TreeReply container(string json) {
    var parser = new Json.Parser();
    try {
        parser.load_from_data(json);
    } catch (GLib.Error e) {
        error("bad test JSON: %s", e.message);
    }
    return new Ilia.TreeReply(parser.get_root());
}

string i3_window(string window_type, string clazz) {
    return """{"id": 1, "type": "con", "urgent": false, "name": "Title", "layout": "splith",
        "window_type": "%s", "window_properties": {"class": "%s", "instance": "%s", "title": "Title"},
        "nodes": [], "floating_nodes": []}""".printf(window_type, clazz, clazz.down());
}

// i3 lists dialogs with the other windows, as sway does: a file chooser left on another workspace stays reachable
void test_i3_windows() {
    assert (Ilia.WindowPage.navigable_window(container(i3_window("normal", "XTerm")), false));
    assert (Ilia.WindowPage.navigable_window(container(i3_window("unknown", "Legacy")), false));
    assert (Ilia.WindowPage.navigable_window(container(i3_window("dialog", "Zenity")), false));
    assert (Ilia.WindowPage.navigable_window(container(i3_window("utility", "Gimp")), false));

    // Bars are not windows to switch to
    assert (!Ilia.WindowPage.navigable_window(container(i3_window("dock", "Polybar")), false));
    assert (!Ilia.WindowPage.navigable_window(container(i3_window("normal", "i3bar")), false));

    // Split containers and workspaces have no window
    assert (!Ilia.WindowPage.navigable_window(container("""{"id": 2, "type": "con", "urgent": false, "name": null,
        "layout": "splitv", "window_type": null, "nodes": [], "floating_nodes": []}"""), false));
    assert (!Ilia.WindowPage.navigable_window(container("""{"id": 3, "type": "workspace", "urgent": false, "name": "1",
        "layout": "splith", "nodes": [], "floating_nodes": []}"""), false));
}

void test_sway_windows() {
    // Native Wayland window: no window_type, no window_properties
    assert (Ilia.WindowPage.navigable_window(container("""{"id": 4, "type": "con", "urgent": false, "name": "foot",
        "layout": "none", "app_id": "foot", "nodes": [], "floating_nodes": []}"""), true));
    // Xwayland dialog, floating
    assert (Ilia.WindowPage.navigable_window(container("""{"id": 5, "type": "floating_con", "urgent": false,
        "name": "PickAFile", "layout": "none", "window_properties": {"class": "Zenity", "instance": "zenity"},
        "nodes": [], "floating_nodes": []}"""), true));
    // Split container
    assert (!Ilia.WindowPage.navigable_window(container("""{"id": 6, "type": "con", "urgent": false, "name": null,
        "layout": "splith", "nodes": [], "floating_nodes": []}"""), true));
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/windows/i3_windows", test_i3_windows);
    Test.add_func("/windows/sway_windows", test_sway_windows);

    return Test.run();
}
