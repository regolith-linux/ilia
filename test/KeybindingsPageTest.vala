using GLib;
using Gee;

// The Super mark the page shows, as in the comments of Regolith's configuration
const string SUPER = "\uf17a";

Gee.List<BoundKeys> bound(string[] combinations, bool is_keycode = false) {
    var list = new ArrayList<BoundKeys> ();
    foreach (unowned string combination in combinations)
        list.add(new BoundKeys(combination, is_keycode));
    return list;
}

string keys_label(string[] combinations) {
    return Ilia.KeybingingsPage.format_keys(bound(combinations));
}

// Modifiers and keys are shown by name, whatever their spelling or letter case
void test_names() {
    assert(keys_label({ "Mod4+Shift+Return" }) == SUPER + " Shift Enter");
    assert(keys_label({ "super+control+space" }) == SUPER + " Ctrl Space");
    assert(keys_label({ "Logo+Mod1+question" }) == SUPER + " Alt ?");
    assert(keys_label({ "Mod3+BackSpace" }) == "Mod3 Backspace");
    assert(keys_label({ "Tab" }) == "Tab");
}

// A keysym that types a character shows the character; other keysyms show their name
void test_keysyms() {
    assert(keys_label({ "Mod4+bracketleft" }) == SUPER + " [");
    assert(keys_label({ "Mod4+odiaeresis" }) == SUPER + " ö");
    assert(keys_label({ "Mod4+F9" }) == SUPER + " F9");
    assert(keys_label({ "XF86AudioMute" }) == "XF86AudioMute");
    assert(keys_label({ "KP_Add" }) == "KP_Add");
}

// Bindings with the same modifiers share them; others are joined by "or"; each shown once
void test_grouping() {
    assert(keys_label({ "Mod4+y", "Super+j", "Logo+k", "mod4+l" }) == SUPER + " y j k l");
    assert(keys_label({ "Mod4+Shift+y", "Shift+Mod4+v" }) == SUPER + " Shift y or Shift " + SUPER + " v");
    assert(keys_label({ "Return", "Escape", "Mod1+r" }) == "Enter or Escape or Alt r");
    assert(keys_label({ "Mod1+Mod1+Mod4+1", "Alt+Mod4+2" }) == "Alt " + SUPER + " 1 2");
    assert(keys_label({ "Mod4+F12", "mod4+F12" }) == SUPER + " F12");
}

// Without a display there is no keyboard layout to name a keycode by
void test_keycode_without_display() {
    assert(Ilia.KeybingingsPage.format_keys(bound({ "Mod4+36" }, true)) == SUPER + " 36");
}

Keybinding row(string spec, string[] combinations, bool[] active = {}) {
    var binding = new Keybinding("Row", spec);
    var keys = bound(combinations);
    for (int i = 0; i < active.length; i++)
        keys[i].active = active[i];
    binding.bound_keys.add_all(keys);
    return binding;
}

// The comment's keys stay while the row binds what it binds with no resource set, in any
// spelling; otherwise the keys bound show, and a row with no bindings keeps its comment
void test_row_label() {
    string written = "<" + SUPER + "> Enter";
    string shown = SUPER + " Enter";
    assert(Ilia.KeybingingsPage.row_keys_label(row(written, { "Mod4+Return" }), row(written, { "Super+return" })) == shown);
    assert(Ilia.KeybingingsPage.row_keys_label(row(written, { "Mod4+y" }), row(written, { "Mod4+Return" })) == SUPER + " y");
    assert(Ilia.KeybingingsPage.row_keys_label(row(written, {}), row(written, {})) == shown);
    assert(Ilia.KeybingingsPage.row_keys_label(row(written, { "Mod4+Return" }), null) == shown);
    // keys another binding has taken are not shown, even when no resource is involved
    assert(Ilia.KeybingingsPage.row_keys_label(row(written, { "Mod4+Return", "Mod4+t" }, { false, true }),
                                               row(written, { "Mod4+Return", "Mod4+t" }, { false, true })) == SUPER + " t");
    assert(Ilia.KeybingingsPage.row_keys_label(row(written, { "Mod4+Return" }, { false }), row(written, { "Mod4+Return" })) == "");
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/keybindings_page/names", test_names);
    Test.add_func("/keybindings_page/keysyms", test_keysyms);
    Test.add_func("/keybindings_page/grouping", test_grouping);
    Test.add_func("/keybindings_page/keycode_without_display", test_keycode_without_display);
    Test.add_func("/keybindings_page/row_label", test_row_label);

    return Test.run();
}
