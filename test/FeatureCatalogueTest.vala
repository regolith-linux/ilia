using GLib;

string[] names_of(Ilia.FeaturePackage[] packages) {
    string[] names = {};
    foreach (var package in packages)
        names += package.name;
    return names;
}

// Each session lists its own prefixes and the shared ones, by kind and then by name
void test_session_prefixes_and_order() {
    string[] ids = {
        "regolith-wm-common;1;amd64;apt",
        "regolith-sway-extra;1;amd64;apt",
        "regolith-i3-extra;1;amd64;apt",
        "regolith-compositor-p;1;amd64;apt",
        "i3xrocks-net;1;amd64;installed:apt",
        "regolith-look-a2;1;amd64;apt",
        "regolith-look-a10;1;amd64;apt",
        "unrelated-editor;1;amd64;apt",
        "prefix-regolith-look-false;1;amd64;apt",
    };

    var x11 = new Ilia.FeatureCatalogue(Ilia.FeatureSession.X11);
    var sway = new Ilia.FeatureCatalogue(Ilia.FeatureSession.SWAY);
    foreach (unowned string id in ids) {
        x11.add(id, "Summary", Ilia.FeatureCatalogue.is_installed_id(id));
        sway.add(id, "Summary", Ilia.FeatureCatalogue.is_installed_id(id));
    }

    assert (string.joinv(" ", names_of(x11.get_packages())) ==
            "regolith-look-a10 regolith-look-a2 i3xrocks-net regolith-compositor-p regolith-i3-extra regolith-wm-common");
    assert (string.joinv(" ", names_of(sway.get_packages())) ==
            "regolith-look-a10 regolith-look-a2 regolith-sway-extra regolith-wm-common");

    var packages = x11.get_packages();
    assert (packages[2].kind.to_label() == "Bar blocks" && packages[2].installed);
    assert (packages[3].kind.to_label() == "Compositors" && !packages[3].installed);
    assert (packages[5].kind.to_label() == "Window manager");
    assert (packages[0].kind.to_label() == "Looks");
}

// Parts of features and transitional packages are no features
void test_hidden_packages() {
    assert (Ilia.FeatureCatalogue.is_hidden("regolith-look-x-loader", "Look"));
    assert (Ilia.FeatureCatalogue.is_hidden("regolith-wm-default-style", "Style"));
    assert (Ilia.FeatureCatalogue.is_hidden("regolith-i3-session", "Session"));
    assert (Ilia.FeatureCatalogue.is_hidden("regolith-wm-config", "Config"));
    assert (Ilia.FeatureCatalogue.is_hidden("regolith-look-old", "TrAnSiTiOnAl PaCkAgE for old look"));
    assert (!Ilia.FeatureCatalogue.is_hidden("regolith-look-loader-addon", "Tail is not at the end"));
    assert (!Ilia.FeatureCatalogue.is_hidden("regolith-look-new", "Useful transitional package wording"));
}

// Entries of one package become one row: installed if any entry is, with an installed entry's summary
void test_duplicates_collapse() {
    var catalogue = new Ilia.FeatureCatalogue(Ilia.FeatureSession.SWAY);
    catalogue.add("regolith-look-z;2;amd64;apt", "Uninstalled first", false);
    catalogue.add("regolith-look-z;1;amd64;installed:apt", "Installed summary", true);
    catalogue.add("regolith-look-z;3;amd64;apt", "Other available summary", false);
    catalogue.add("regolith-look-a;1;amd64;apt", "First available summary", false);
    catalogue.add("regolith-look-a;1;amd64;other", "Later available summary", false);

    var packages = catalogue.get_packages();
    assert (packages.length == 2);
    assert (packages[0].name == "regolith-look-a" && packages[0].summary == "First available summary");
    assert (!packages[0].installed && packages[0].available_id == "regolith-look-a;1;amd64;apt");
    assert (packages[1].summary == "Installed summary" && packages[1].installed);
    assert (packages[1].installed_id == "regolith-look-z;1;amd64;installed:apt");
    assert (packages[1].available_id == "regolith-look-z;2;amd64;apt");
}

void test_prompts_and_states() {
    assert (Ilia.FeatureCatalogue.install_prompt("regolith-look-a", { "z", "a10", "a2" }) ==
            "Install regolith-look-a and remove a10, a2, z? Enter to confirm, Escape to cancel.");
    assert (Ilia.FeatureCatalogue.remove_prompt("regolith-wm-x", {}) ==
            "Remove regolith-wm-x? Enter to confirm, Escape to cancel.");
    assert (Ilia.FeatureCatalogue.remove_prompt("regolith-wm-x", { "z-dep", "a-dep" }) ==
            "Remove regolith-wm-x and also a-dep, z-dep? Enter to confirm, Escape to cancel.");
    assert (Ilia.FeatureCatalogue.transaction_state(true, 40) == "Installing 40%");
    assert (Ilia.FeatureCatalogue.transaction_state(false, 0) == "Removing 0%");
    assert (Ilia.FeatureCatalogue.transaction_state(true, 101) == "Installing");
    assert (Ilia.FeatureCatalogue.transaction_state(false, -1) == "Removing");
}

void test_matching() {
    assert (Ilia.FeatureCatalogue.matches("", "regolith-look-a", "Amber ocean"));
    assert (Ilia.FeatureCatalogue.matches("LOOK-A", "regolith-look-a", "Amber ocean"));
    assert (Ilia.FeatureCatalogue.matches("OCEAN", "regolith-look-a", "Amber ocean"));
    assert (!Ilia.FeatureCatalogue.matches("OCEAN ", "regolith-look-a", "Amber ocean"));
    assert (Ilia.FeatureCatalogue.matches("CAFÉ", "regolith-look-a", "Café summer"));
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/feature_catalogue/session_prefixes_and_order", test_session_prefixes_and_order);
    Test.add_func("/feature_catalogue/hidden_packages", test_hidden_packages);
    Test.add_func("/feature_catalogue/duplicates_collapse", test_duplicates_collapse);
    Test.add_func("/feature_catalogue/prompts_and_states", test_prompts_and_states);
    Test.add_func("/feature_catalogue/matching", test_matching);

    return Test.run();
}
