using GLib;

// Reading i3's bindings and matching key presses against them as i3 does, for the keys
// ilia passes on while it holds the X11 keyboard grab. A small fixed keymap stands in for
// the X server's, so no display is needed.

const uint SHIFT = 1 << 0;
const uint LOCK = 1 << 1;
const uint CONTROL = 1 << 2;
const uint MOD1 = 1 << 3;
const uint NUMLOCK = 1 << 4;
const uint MOD5 = 1 << 7;

const uint KC_4 = 13;
const uint KC_E = 26;
const uint KC_T = 28;
const uint KC_Y = 29;      // y in the first layout (us), z in the second (de)
const uint KC_A = 38;
const uint KC_Z = 52;      // z in the first layout, y in the second
const uint KC_F9 = 75;
const uint KC_KP_1 = 87;   // KP_End, or KP_1 with Num Lock

// Levels: 0 plain, 1 Shift, 2 AltGr (Mod5)
bool translate(uint keycode, uint mods, int group, out uint keyval, out int level) {
    bool shift = (mods & SHIFT) != 0;
    level = shift ? 1 : 0;
    switch (keycode) {
        case KC_4:
            keyval = shift ? Gdk.Key.dollar : Gdk.Key.@4;
            return true;
        case KC_E:
            if ((mods & MOD5) != 0) {
                level = 2;
                keyval = Gdk.Key.EuroSign;
                return true;
            }
            keyval = shift ? Gdk.Key.E : Gdk.Key.e;
            return true;
        case KC_T:
            keyval = shift ? Gdk.Key.T : Gdk.Key.t;
            return true;
        case KC_Y:
            keyval = group == 1 ? (shift ? Gdk.Key.Z : Gdk.Key.z) : (shift ? Gdk.Key.Y : Gdk.Key.y);
            return true;
        case KC_A:
            keyval = shift ? Gdk.Key.A : Gdk.Key.a;
            return true;
        case KC_Z:
            keyval = group == 1 ? (shift ? Gdk.Key.Y : Gdk.Key.y) : (shift ? Gdk.Key.Z : Gdk.Key.z);
            return true;
        case KC_F9:
            level = 0;
            keyval = Gdk.Key.F9;
            return true;
        case KC_KP_1:
            bool digit = ((mods & NUMLOCK) != 0) != shift;
            level = digit ? 1 : 0;
            keyval = digit ? Gdk.Key.KP_1 : Gdk.Key.KP_End;
            return true;
        default:
            keyval = 0;
            return false;
    }
}

// The command of the binding that runs on the press, or "" if none
string pressed(Ilia.WmBindings bindings, uint keycode, uint mods, int group = 0, string mode = Ilia.WmBindings.DEFAULT_MODE) {
    Ilia.WmBinding ? on_press, on_release;
    bindings.lookup(mode, keycode, mods, group, NUMLOCK, translate, out on_press, out on_release);
    return on_press != null ? on_press.command : "";
}

// The command of the release binding the press arms, or "" if none
string armed(Ilia.WmBindings bindings, uint keycode, uint mods, string mode = Ilia.WmBindings.DEFAULT_MODE) {
    Ilia.WmBinding ? on_press, on_release;
    bindings.lookup(mode, keycode, mods, 0, NUMLOCK, translate, out on_press, out on_release);
    return on_release != null ? on_release.command : "";
}

void test_modes_and_blocks() {
    var bindings = new Ilia.WmBindings.from_i3_config("""
bindsym Mod1+t exec default-t
mode "resize" {
    bindsym t exec resize-t
    bindsym --release Mod1+t exec resize-release
}
mode --pango_markup "<b>launch</b>" {
    bindsym y exec launch-y
}
bar {
    bindsym button4 nop
    colors {
        background #000000
    }
}
bindsym Control+y exec after-bar
""");

    assert(pressed(bindings, KC_T, MOD1) == "exec default-t");
    assert(pressed(bindings, KC_T, 0) == "");
    assert(pressed(bindings, KC_T, 0, 0, "resize") == "exec resize-t");
    assert(pressed(bindings, KC_T, MOD1, 0, "resize") == "");
    assert(armed(bindings, KC_T, MOD1, "resize") == "exec resize-release");
    assert(pressed(bindings, KC_Y, 0, 0, "<b>launch</b>") == "exec launch-y");
    assert(pressed(bindings, KC_Y, 0) == "");
    // Back at the top level after the bar block and its nested block
    assert(pressed(bindings, KC_Y, CONTROL) == "exec after-bar");
}

void test_binding_syntax() {
    var bindings = new Ilia.WmBindings.from_i3_config("""
# bindsym Mod1+e exec commented-out
bindsym Mod1+e --release exec option-after-key
bindsym --border Control+t exec option-before-key
bindsym Control+Mod1+t [class="XTerm"] mark --add "a b", focus; exec "echo 'x; y'"
bindcode Control+29 exec by-code
bindsym Control+Mod1+y exec \
    continued
bindsym Control+NoSuchKey exec unknown-key
bindsym Hyper+t exec unknown-modifier
""");

    assert(pressed(bindings, KC_E, MOD1) == "");
    assert(armed(bindings, KC_E, MOD1) == "exec option-after-key");
    assert(pressed(bindings, KC_T, CONTROL) == "exec option-before-key");
    // The command is kept as written: criteria, quotes and chained commands
    assert(pressed(bindings, KC_T, CONTROL | MOD1) == "[class=\"XTerm\"] mark --add \"a b\", focus; exec \"echo 'x; y'\"");
    assert(pressed(bindings, KC_Y, CONTROL) == "exec by-code");
    assert(pressed(bindings, KC_Y, CONTROL | MOD1) == "exec     continued");
    assert(pressed(bindings, KC_T, 0) == "");
}

void test_modifiers_match_exactly() {
    var bindings = new Ilia.WmBindings.from_i3_config("bindsym Control+Mod1+t exec t\n");

    assert(pressed(bindings, KC_T, CONTROL | MOD1) == "exec t");
    // Caps Lock is ignored, and Num Lock where it does not change the key
    assert(pressed(bindings, KC_T, CONTROL | MOD1 | LOCK) == "exec t");
    assert(pressed(bindings, KC_T, CONTROL | MOD1 | NUMLOCK) == "exec t");
    assert(pressed(bindings, KC_T, CONTROL | MOD1 | NUMLOCK | LOCK) == "exec t");
    // Any other modifier, held or missing, is a different key
    assert(pressed(bindings, KC_T, CONTROL | MOD1 | SHIFT) == "");
    assert(pressed(bindings, KC_T, CONTROL) == "");
    assert(pressed(bindings, KC_T, MOD1 | MOD5 | CONTROL) == "");
}

void test_shift_level() {
    var bindings = new Ilia.WmBindings.from_i3_config("""
bindsym Mod1+A exec upper-a
bindsym Shift+a exec shift-a
bindsym dollar exec dollar
bindsym Mod1+EuroSign exec euro
""");

    // As in i3: a symbol on the Shift level also names its key without Shift, and the
    // binding's modifiers decide whether Shift is held
    assert(pressed(bindings, KC_A, MOD1) == "exec upper-a");
    assert(pressed(bindings, KC_A, MOD1 | SHIFT) == "");
    assert(pressed(bindings, KC_A, SHIFT) == "exec shift-a");
    assert(pressed(bindings, KC_A, 0) == "");
    assert(pressed(bindings, KC_4, 0) == "exec dollar");
    assert(pressed(bindings, KC_4, SHIFT) == "");
    // No such fallback for a symbol above the Shift level
    assert(pressed(bindings, KC_E, MOD1) == "");
}

void test_keypad_and_num_lock() {
    var bindings = new Ilia.WmBindings.from_i3_config("bindsym KP_End exec kp-end\nbindsym Mod2+KP_1 exec kp-1\n");

    assert(pressed(bindings, KC_KP_1, 0) == "exec kp-end");
    assert(pressed(bindings, KC_KP_1, NUMLOCK) == "exec kp-1");

    // A key code binding ignores Num Lock only where it leaves the key's symbol alone
    var by_code = new Ilia.WmBindings.from_i3_config("bindcode 87 exec code-87\nbindcode 28 exec code-28\n");
    assert(pressed(by_code, KC_KP_1, 0) == "exec code-87");
    assert(pressed(by_code, KC_KP_1, NUMLOCK) == "");
    assert(pressed(by_code, KC_T, NUMLOCK) == "exec code-28");
}

void test_layouts() {
    var bindings = new Ilia.WmBindings.from_i3_config("bindsym Mod1+y exec y\nbindsym Group2+Control+y exec second-layout-y\n");

    // Without a group, the name is looked up in the first layout, whatever layout is active
    assert(pressed(bindings, KC_Y, MOD1, 0) == "exec y");
    assert(pressed(bindings, KC_Y, MOD1, 1) == "exec y");
    assert(pressed(bindings, KC_Z, MOD1, 1) == "");
    // With a group, only in that layout and with its symbols
    assert(pressed(bindings, KC_Z, CONTROL, 1) == "exec second-layout-y");
    assert(pressed(bindings, KC_Z, CONTROL, 0) == "");
    assert(pressed(bindings, KC_Y, CONTROL, 1) == "");
}

void test_press_and_release() {
    var both = new Ilia.WmBindings.from_i3_config("bindsym --release F9 exec on-release\nbindsym F9 exec on-press\n");
    assert(pressed(both, KC_F9, 0) == "exec on-press");
    assert(armed(both, KC_F9, 0) == "");

    var release = new Ilia.WmBindings.from_i3_config("bindsym --release F9 exec on-release\n");
    assert(pressed(release, KC_F9, 0) == "");
    assert(armed(release, KC_F9, 0) == "exec on-release");

    // The first of two bindings for the same key wins, as in i3
    var twice = new Ilia.WmBindings.from_i3_config("bindsym F9 exec first\nbindsym F9 exec second\n");
    assert(pressed(twice, KC_F9, 0) == "exec first");
}

void test_layout_switch_only() {
    assert(Ilia.SwayBindingWatcher.is_layout_switch_only("input type:keyboard xkb_switch_layout next"));
    assert(Ilia.SwayBindingWatcher.is_layout_switch_only("input * xkb_switch_layout 1, input \"1:1:AT Translated Set 2 keyboard\" xkb_switch_layout prev"));
    assert(Ilia.SwayBindingWatcher.is_layout_switch_only("input * xkb_switch_layout next; input * xkb_switch_layout next"));
    assert(!Ilia.SwayBindingWatcher.is_layout_switch_only("input * xkb_switch_layout next; exec notify-send layout"));
    assert(!Ilia.SwayBindingWatcher.is_layout_switch_only("exec \"input * xkb_switch_layout next\""));
    assert(!Ilia.SwayBindingWatcher.is_layout_switch_only("input * xkb_layout us"));
    assert(!Ilia.SwayBindingWatcher.is_layout_switch_only("workspace number 2"));
    assert(!Ilia.SwayBindingWatcher.is_layout_switch_only(""));
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/wm_bindings/modes_and_blocks", test_modes_and_blocks);
    Test.add_func("/wm_bindings/binding_syntax", test_binding_syntax);
    Test.add_func("/wm_bindings/modifiers_match_exactly", test_modifiers_match_exactly);
    Test.add_func("/wm_bindings/shift_level", test_shift_level);
    Test.add_func("/wm_bindings/keypad_and_num_lock", test_keypad_and_num_lock);
    Test.add_func("/wm_bindings/layouts", test_layouts);
    Test.add_func("/wm_bindings/press_and_release", test_press_and_release);
    Test.add_func("/wm_bindings/layout_switch_only", test_layout_switch_only);

    return Test.run();
}
