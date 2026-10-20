using GLib;

// Layout-switch shortcuts handled while ilia holds the X11 keyboard grab
// (regolith-desktop#618). No display is needed: with a null keymap the usual
// X11 modifier mapping is assumed (Super on Mod4).

const Gdk.ModifierType SHIFT = Gdk.ModifierType.SHIFT_MASK;
const Gdk.ModifierType CTRL = Gdk.ModifierType.CONTROL_MASK;
const Gdk.ModifierType ALT = Gdk.ModifierType.MOD1_MASK;
const Gdk.ModifierType NUMLOCK = Gdk.ModifierType.MOD2_MASK;
const Gdk.ModifierType SUPER = Gdk.ModifierType.MOD4_MASK;
const Gdk.ModifierType CAPSLOCK = Gdk.ModifierType.LOCK_MASK;

Ilia.InputSourceSwitcher regolith_defaults() {
    return new Ilia.InputSourceSwitcher({ "<Alt><Super>BackSpace" }, { "<Shift><Alt><Super>BackSpace" }, null);
}

void test_match_regolith_shortcut() {
    var s = regolith_defaults();

    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, ALT | SUPER) == 1);
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, SHIFT | ALT | SUPER) == -1);

    // Num Lock and Caps Lock do not matter
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, ALT | SUPER | NUMLOCK | CAPSLOCK) == 1);

    // Anything else is not the shortcut
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, 0) == 0);
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, ALT) == 0);
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, SUPER) == 0);
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, CTRL | ALT | SUPER) == 0);
    assert (s.match(Gdk.Key.Delete, Gdk.Key.Delete, ALT | SUPER) == 0);
    assert (s.match(Gdk.Key.Super_L, Gdk.Key.Super_L, ALT) == 0);
}

void test_match_letter_shortcut_in_other_layout() {
    // GNOME's default is <Super>space; letter shortcuts must also work in a non-Latin layout
    var s = new Ilia.InputSourceSwitcher({ "<Super>space", "<Control><Shift>z" }, {}, null);

    assert (s.match(Gdk.Key.space, Gdk.Key.space, SUPER) == 1);
    assert (s.match(Gdk.Key.Z, Gdk.Key.Z, CTRL | SHIFT) == 1);
    // Cyrillic layout: the Z key types я, the first layout has z there
    assert (s.match(Gdk.Key.Cyrillic_YA, Gdk.Key.z, CTRL | SHIFT) == 1);
    assert (s.match(Gdk.Key.Cyrillic_YA, Gdk.Key.Cyrillic_YA, CTRL | SHIFT) == 0);
}

void test_no_shortcuts() {
    var s = new Ilia.InputSourceSwitcher({}, { "" }, null);
    assert (s.match(Gdk.Key.BackSpace, Gdk.Key.BackSpace, ALT | SUPER) == 0);
    assert (!s.super_starts_shortcut(ALT));
}

void test_super_starts_shortcut() {
    var s = regolith_defaults();

    // Alt (and Shift) held, then Super: wait for BackSpace instead of exiting
    assert (s.super_starts_shortcut(ALT));
    assert (s.super_starts_shortcut(ALT | NUMLOCK));
    assert (s.super_starts_shortcut(SHIFT | ALT));

    // Super on its own, or with modifiers that are not part of the shortcut, still exits
    assert (!s.super_starts_shortcut(0));
    assert (!s.super_starts_shortcut(NUMLOCK));
    assert (!s.super_starts_shortcut(CTRL));
    assert (!s.super_starts_shortcut(CTRL | ALT));

    // A shortcut without Super never delays the exit on Super
    var no_super = new Ilia.InputSourceSwitcher({ "<Alt>Shift_L" }, {}, null);
    assert (!no_super.super_starts_shortcut(ALT));
}

void test_pick_source() {
    string[] two = { "xkb:us", "xkb:de" };
    assert (Ilia.InputSourceSwitcher.pick_source(two, {}, 0, false) == 1);
    assert (Ilia.InputSourceSwitcher.pick_source(two, {}, 1, false) == 0);
    assert (Ilia.InputSourceSwitcher.pick_source(two, {}, 0, true) == 1);
    assert (Ilia.InputSourceSwitcher.pick_source(two, { "xkb:de", "xkb:us" }, 1, false) == 0);

    // Three sources: the shortcut goes back to the most recently used one, as gnome-flashback does
    string[] three = { "xkb:us", "xkb:de", "xkb:fr" };
    assert (Ilia.InputSourceSwitcher.pick_source(three, {}, 0, false) == 1);
    assert (Ilia.InputSourceSwitcher.pick_source(three, { "xkb:de", "xkb:us", "xkb:fr" }, 1, false) == 0);
    assert (Ilia.InputSourceSwitcher.pick_source(three, { "xkb:fr", "xkb:us", "xkb:de" }, 2, false) == 0);
    // Backward picks the least recently used
    assert (Ilia.InputSourceSwitcher.pick_source(three, { "xkb:de", "xkb:us", "xkb:fr" }, 1, true) == 2);

    // A stale list: unknown entries are skipped, missing ones follow in settings order,
    // and the active source counts as the most recent
    assert (Ilia.InputSourceSwitcher.pick_source(three, { "xkb:gone", "xkb:fr" }, 0, false) == 2);
    assert (Ilia.InputSourceSwitcher.pick_source(three, { "xkb:us", "xkb:de" }, 2, false) == 0);

    // Nothing to switch to
    assert (Ilia.InputSourceSwitcher.pick_source({ "xkb:us" }, {}, 0, false) == -1);
    assert (Ilia.InputSourceSwitcher.pick_source({}, {}, -1, false) == -1);
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/input_sources/match_regolith_shortcut", test_match_regolith_shortcut);
    Test.add_func("/input_sources/match_letter_shortcut_in_other_layout", test_match_letter_shortcut_in_other_layout);
    Test.add_func("/input_sources/no_shortcuts", test_no_shortcuts);
    Test.add_func("/input_sources/super_starts_shortcut", test_super_starts_shortcut);
    Test.add_func("/input_sources/pick_source", test_pick_source);

    return Test.run();
}
