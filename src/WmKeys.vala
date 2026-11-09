namespace Ilia {
    /**
     * Let i3's key bindings and the desktop's grabbed keys work while ilia holds the X11 keyboard grab
     *
     * ilia grabs the keyboard on X11, so a key press reaches neither i3's bindings nor the
     * programs that grab keys on the root window (the desktop's media and Print keys). For a key
     * press ilia does not use itself:
     *
     * - if i3 would run a binding for it in the current binding mode, ilia closes, releasing
     *   the grab, and has i3 run that binding's command over IPC. A --release binding runs
     *   when the key is released;
     * - if it is one of the desktop's keys and i3 does not bind it, ilia closes when the key
     *   is released and presses it again with XTEST, so that the program that grabs it gets it.
     *
     * Without i3 (another window manager, or no IPC socket) only the desktop's keys are passed on.
     *
     * The owner connects to release_input (give up the grab and hide, synchronously) and
     * finished (close).
     */
    public class X11KeyForwarder : GLib.Object {
        private const uint LOCK_MASK = 1 << 1;
        private const uint NUM_LOCK_KEYSYM = 0xff7f;

        // A key that ilia took, waiting for its release
        private class PendingKey {
            public uint keycode;
            // The release binding to run, or null for a desktop key to press again
            public WmBinding ? binding;
            // Real modifiers held when the key was pressed
            public uint mods;
        }

        public signal void release_input();
        public signal void finished();

        private Gdk.Display display;
        private Gdk.Keymap keymap;
        private uint numlock_mask;
        private PendingKey ? pending = null;
        // Look up i3's bindings; false when the window manager is not i3
        private bool use_i3;
        // An IPC error was reported already: say it once, not on every key
        private bool ipc_error_reported = false;

        // The last configuration read, and its bindings
        private string ? config_text = null;
        private WmBindings ? bindings = null;

        public X11KeyForwarder (Gdk.Display display, bool use_i3) {
            this.display = display;
            this.use_i3 = use_i3;
            this.keymap = Gdk.Keymap.get_for_display(display);
            this.numlock_mask = find_numlock_mask();
        }

        // The real modifier Num Lock is on; Mod2 if the server does not say
        private uint find_numlock_mask() {
            var x11_display = display as Gdk.X11.Display;
            if (x11_display == null)
                return 1 << 4;

            unowned X.Display xdisplay = x11_display.get_xdisplay();
            uint keycode = xdisplay.keysym_to_keycode(NUM_LOCK_KEYSYM);
            var modmap = xdisplay.get_modifier_mapping();
            if (keycode != 0 && modmap != null) {
                for (int mod = 0; mod < 8; mod++) {
                    for (int i = 0; i < modmap.max_keypermod; i++) {
                        if (modmap.modifiermap[mod * modmap.max_keypermod + i] == keycode)
                            return 1 << mod;
                    }
                }
            }
            return 1 << 4;
        }

        /**
         * The keys the desktop grabs, that ilia hands back when i3 does not bind them
         */
        public static bool is_desktop_key(uint keyval) {
            switch (keyval) {
                case Gdk.Key.Print:
                case Gdk.Key.AudioRaiseVolume:
                case Gdk.Key.AudioLowerVolume:
                case Gdk.Key.AudioMute:
                case Gdk.Key.AudioMicMute:
                case Gdk.Key.MonBrightnessUp:
                case Gdk.Key.MonBrightnessDown:
                case Gdk.Key.Calculator:
                case Gdk.Key.AudioPlay:
                case Gdk.Key.AudioPause:
                case Gdk.Key.AudioNext:
                case Gdk.Key.AudioPrev:
                    return true;
                default:
                    return false;
            }
        }

        private bool translate(uint keycode, uint mods, int group, out uint keyval, out int level) {
            int effective_group;
            Gdk.ModifierType consumed;
            return keymap.translate_keyboard_state(keycode, (Gdk.ModifierType) mods, group,
                                                   out keyval, out effective_group, out level, out consumed);
        }

        // i3's bindings, read again when the configuration changed
        private WmBindings read_bindings(IPCClient ipc) throws GLib.Error {
            string text = ipc.getConfig().config;
            if (bindings == null || text != config_text) {
                bindings = new WmBindings.from_i3_config(text);
                config_text = text;
            }
            return bindings;
        }

        /**
         * Handle a key press that ilia does not use itself
         *
         * @return true if the key was taken: ilia closes, now or when the key is released
         */
        public bool key_pressed(Gdk.EventKey key) {
            if (pending != null) {
                if (pending.keycode == key.hardware_keycode)
                    return true; // repeated while held
                pending = null; // another key: the held one no longer counts
            }

            uint mods = key.state & WmBindings.MODIFIER_MASK;
            WmBinding ? on_press = null, on_release = null;
            if (use_i3) {
                try {
                    var ipc = new IPCClient("i3");
                    string mode = ipc.getBindingState();
                    read_bindings(ipc).lookup(mode, key.hardware_keycode, mods, key.group, numlock_mask, translate,
                                              out on_press, out on_release);
                } catch (GLib.Error e) {
                    if (!ipc_error_reported)
                        stderr.printf("Unable to read the key bindings of i3: %s\n", e.message);
                    ipc_error_reported = true;
                }
            }

            if (on_press != null) {
                run_binding(on_press);
                return true;
            }
            if (on_release != null || is_desktop_key(base_keyval(key)) || is_desktop_key(key.keyval)) {
                pending = new PendingKey() {
                    keycode = key.hardware_keycode,
                    binding = on_release,
                    mods = mods
                };
                return true;
            }
            return false;
        }

        /**
         * Handle a key release
         *
         * @return true if the release completed a key that was taken
         */
        public bool key_released(Gdk.EventKey key) {
            if (pending == null || pending.keycode != key.hardware_keycode)
                return false;

            var taken = pending;
            pending = null;
            if (taken.binding != null)
                run_binding(taken.binding);
            else
                press_again(taken.keycode, taken.mods);
            return true;
        }

        // The key's symbol in the first layout, without modifiers
        private uint base_keyval(Gdk.EventKey key) {
            uint keyval;
            int level;
            if (translate(key.hardware_keycode, 0, 0, out keyval, out level))
                return keyval;
            return key.keyval;
        }

        // Close, then have i3 run the binding: by then the grab is gone, so what the binding starts can take the keyboard
        private void run_binding(WmBinding binding) {
            release_input();
            try {
                new IPCClient("i3").runCommand(binding.command);
            } catch (GLib.Error e) {
                stderr.printf("Unable to run the binding of i3: %s\n", e.message);
            }
            finished();
        }

        // Close, then press the key again for the program that grabs it, with the modifiers of the original press
        private void press_again(uint keycode, uint mods) {
            release_input();

            var x11_display = display as Gdk.X11.Display;
            if (x11_display != null) {
                unowned X.Display xdisplay = x11_display.get_xdisplay();
                int event_base, error_base, major, minor;
                x11_display.error_trap_push();
                if (XTest.query_extension(xdisplay, out event_base, out error_base, out major, out minor)) {
                    // Modifiers let go since the press are held again for it; never the lock modifiers
                    X.Window root_return, child_return;
                    int root_x, root_y, win_x, win_y;
                    uint held = 0;
                    xdisplay.query_pointer(xdisplay.default_root_window(), out root_return, out child_return,
                                           out root_x, out root_y, out win_x, out win_y, out held);
                    uint missing = mods & ~held & ~(LOCK_MASK | numlock_mask) & WmBindings.MODIFIER_MASK;

                    uint[] modifier_keys = {};
                    X.ModifierKeymap ? modmap = null;
                    if (missing != 0)
                        modmap = xdisplay.get_modifier_mapping();
                    for (int mod = 0; modmap != null && mod < 8; mod++) {
                        if ((missing & (1 << mod)) == 0)
                            continue;
                        for (int i = 0; i < modmap.max_keypermod; i++) {
                            uint modifier_key = modmap.modifiermap[mod * modmap.max_keypermod + i];
                            if (modifier_key != 0) {
                                modifier_keys += modifier_key;
                                break;
                            }
                        }
                    }

                    foreach (uint modifier_key in modifier_keys)
                        XTest.fake_key_event(xdisplay, modifier_key, true, 0);
                    XTest.fake_key_event(xdisplay, keycode, true, 0);
                    XTest.fake_key_event(xdisplay, keycode, false, 0);
                    foreach (uint modifier_key in modifier_keys)
                        XTest.fake_key_event(xdisplay, modifier_key, false, 0);
                } else {
                    stderr.printf("The X server has no XTEST extension, unable to pass the key on\n");
                }
                display.sync();
                x11_display.error_trap_pop_ignored();
            }

            finished();
        }
    }

    /**
     * Report the bindings sway runs while ilia is open (sway runs them even though ilia has the keyboard)
     *
     * Bindings that only switch the keyboard layout are not reported: ilia stays open for them.
     */
    public class SwayBindingWatcher : GLib.Object {
        public signal void binding_run(string command);

        private IPCClient ipc;

        public SwayBindingWatcher () throws GLib.Error {
            ipc = new IPCClient("sway");
            ipc.subscribe({ "binding" }, (event, payload) => {
                if (event != WM_EVENT.BINDING || payload.get_node_type() != Json.NodeType.OBJECT)
                    return;
                var obj = payload.get_object();
                if (obj.has_member("change") && obj.get_string_member("change") != "run")
                    return;

                string command = "";
                var binding = obj.has_member("binding") ? obj.get_object_member("binding") : null;
                if (binding != null && binding.has_member("command"))
                    command = binding.get_string_member("command") ?? "";
                if (!is_layout_switch_only(command))
                    binding_run(command);
            });
        }

        // Split a command list at the separators "," and ";" that are not quoted
        private static string[] split_commands(string commands) {
            string[] result = {};
            var current = new StringBuilder();
            bool quoted = false;

            for (int i = 0; i < commands.length; i++) {
                char c = commands[i];
                if (c == '\\' && quoted && i + 1 < commands.length) {
                    current.append_c(c);
                    current.append_c(commands[++i]);
                    continue;
                }
                if (c == '"')
                    quoted = !quoted;
                if (!quoted && (c == ',' || c == ';')) {
                    result += current.str;
                    current.truncate();
                    continue;
                }
                current.append_c(c);
            }
            result += current.str;
            return result;
        }

        // The words of a command, with quotes removed
        private static string[] split_words(string command) {
            string[] words = {};
            var current = new StringBuilder();
            bool quoted = false, in_word = false;

            for (int i = 0; i < command.length; i++) {
                char c = command[i];
                if (c == '"') {
                    quoted = !quoted;
                    in_word = true;
                } else if (c == '\\' && quoted && i + 1 < command.length) {
                    current.append_c(command[++i]);
                } else if (c.isspace() && !quoted) {
                    if (in_word)
                        words += current.str;
                    current.truncate();
                    in_word = false;
                } else {
                    current.append_c(c);
                    in_word = true;
                }
            }
            if (in_word)
                words += current.str;
            return words;
        }

        /**
         * True if a command consists only of keyboard layout switches:
         * "input <identifier> xkb_switch_layout <layout>", one or more, separated by "," or ";"
         */
        public static bool is_layout_switch_only(string command) {
            int switches = 0;
            foreach (unowned string part in split_commands(command)) {
                string[] words = split_words(part);
                if (words.length == 0)
                    continue;
                if (words.length != 4 || words[0].ascii_down() != "input" || words[2].ascii_down() != "xkb_switch_layout")
                    return false;
                switches++;
            }
            return switches > 0;
        }
    }
}
