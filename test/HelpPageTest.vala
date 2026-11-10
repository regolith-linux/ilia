using GLib;

// The page's own keys come first, in key order, then the keys of every page
void test_rows() {
    var page_keys = new HashTable<string, string>(str_hash, str_equal);
    page_keys.set("enter", "Launch Application");
    page_keys.set("ctrl+delete", "Hide Application");

    string[] keys, functions;
    Ilia.HelpPage.help_rows(page_keys, { "Alt+a", "Show Apps", "Alt+h", "Show Help" }, out keys, out functions);

    assert (keys.length == functions.length);
    assert (keys[0] == "ctrl+delete" && functions[0] == "Hide Application");
    assert (keys[1] == "enter" && functions[1] == "Launch Application");
    assert ("↑ ↓" in keys);
    assert ("Home End" in keys);
    assert ("← →" in keys);

    int alt_a = -1;
    for (int i = 0; i < keys.length; ++i) {
        if (keys[i] == "Alt+a")
            alt_a = i;
    }
    assert (alt_a > 1);
    assert (functions[alt_a] == "Show Apps");
    assert (keys[alt_a + 1] == "Alt+h" && functions[alt_a + 1] == "Show Help");
    assert (keys[keys.length - 1] == "Esc" && functions[keys.length - 1] == "Exit");
}

// A page without keys of its own (the help page) still lists the common keys
void test_rows_without_page_keys() {
    string[] keys, functions;
    Ilia.HelpPage.help_rows(null, {}, out keys, out functions);

    assert (keys.length == functions.length);
    assert (keys[0] == "↑ ↓");
    assert (keys[keys.length - 1] == "Esc");
}

// Page names lose the markup that underlines their letter
void test_plain_page_name() {
    assert (Ilia.HelpPage.plain_page_name("<u>K</u>eybindings") == "Keybindings");
    assert (Ilia.HelpPage.plain_page_name("Apps") == "Apps");
    // Not markup: shown as it is
    assert (Ilia.HelpPage.plain_page_name("a < b") == "a < b");
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/help_page/rows", test_rows);
    Test.add_func("/help_page/rows_without_page_keys", test_rows_without_page_keys);
    Test.add_func("/help_page/plain_page_name", test_plain_page_name);

    return Test.run();
}
