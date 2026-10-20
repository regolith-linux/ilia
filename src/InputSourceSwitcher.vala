namespace Ilia {
    /**
     * Switch the keyboard layout while ilia holds the X11 keyboard grab
     *
     * On X11 ilia grabs the keyboard, so the desktop's layout-switch shortcut
     * (org.gnome.desktop.wm.keybindings switch-input-source, handled by
     * gnome-flashback) cannot fire while ilia is open. ilia recognises that
     * shortcut itself and asks gnome-flashback over D-Bus to activate the input
     * source the shortcut would have chosen. The grab is kept.
     */
    public class InputSourceSwitcher : GLib.Object {
        private const string KEYBINDINGS_SCHEMA = "org.gnome.desktop.wm.keybindings";
        private const string INPUT_SOURCES_SCHEMA = "org.gnome.desktop.input-sources";
        private const string FLASHBACK_BUS_NAME = "org.gnome.Flashback.InputSources";
        private const string FLASHBACK_OBJECT_PATH = "/org/gnome/Flashback/InputSources";
        private const string FLASHBACK_INTERFACE = "org.gnome.Flashback.InputSources";
        private const int DBUS_TIMEOUT_MS = 1000;

        // A shortcut, with its modifiers as real X modifiers
        private struct Accel {
            uint keyval;
            Gdk.ModifierType mods;
        }

        private Accel[] forward = {};
        private Accel[] backward = {};
        // Real modifiers that take part in matching (not Caps Lock or Num Lock)
        private Gdk.ModifierType mod_mask;
        // Real modifier that carries Super
        private Gdk.ModifierType super_mask;

        /**
         * @param forward_accels Accelerators that switch to the next source, in GTK syntax
         * @param backward_accels Accelerators that switch to the previous source
         * @param keymap Keymap used to map virtual modifiers (Super, Hyper, Meta) to real ones;
         *               if null, or it has no mapping, the usual X11 mapping is assumed (Super and Hyper on Mod4, Meta on Mod1)
         */
        public InputSourceSwitcher (string[] forward_accels, string[] backward_accels, Gdk.Keymap ? keymap) {
            // GTK's default accelerator modifiers; Gtk.accelerator_get_default_mod_mask() needs a display
            mod_mask = to_real(Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.MOD1_MASK |
                               Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.HYPER_MASK | Gdk.ModifierType.META_MASK, keymap);
            super_mask = to_real(Gdk.ModifierType.SUPER_MASK, keymap);
            forward = parse_accels(forward_accels, keymap);
            backward = parse_accels(backward_accels, keymap);
        }

        /**
         * Create a switcher for the shortcuts configured in GNOME settings, or null if there are none
         */
        public static InputSourceSwitcher ? from_settings(Gdk.Keymap keymap) {
            var schema_source = SettingsSchemaSource.get_default();
            if (schema_source == null || schema_source.lookup(KEYBINDINGS_SCHEMA, true) == null)
                return null;

            var settings = new GLib.Settings(KEYBINDINGS_SCHEMA);
            var switcher = new InputSourceSwitcher(settings.get_strv("switch-input-source"),
                                                   settings.get_strv("switch-input-source-backward"),
                                                   keymap);

            return switcher.forward.length + switcher.backward.length > 0 ? switcher : null;
        }

        // Map virtual modifiers (Super, Hyper, Meta) to the real ones that carry them. If the keymap
        // has no answer, assume the usual X11 mapping: Super and Hyper on Mod4, Meta on Mod1.
        private static Gdk.ModifierType to_real(Gdk.ModifierType mods, Gdk.Keymap ? keymap) {
            const Gdk.ModifierType VIRTUAL = Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.HYPER_MASK | Gdk.ModifierType.META_MASK;
            const Gdk.ModifierType[] VIRTUAL_MODS = { Gdk.ModifierType.SUPER_MASK, Gdk.ModifierType.HYPER_MASK, Gdk.ModifierType.META_MASK };

            var real = mods & ~VIRTUAL & Gdk.ModifierType.MODIFIER_MASK;
            foreach (var virtual_mod in VIRTUAL_MODS) {
                if ((mods & virtual_mod) == 0) continue;

                var mapped = virtual_mod;
                if (keymap != null)
                    keymap.map_virtual_modifiers(ref mapped);
                mapped &= ~VIRTUAL & Gdk.ModifierType.MODIFIER_MASK;
                if (mapped == 0)
                    mapped = virtual_mod == Gdk.ModifierType.META_MASK ? Gdk.ModifierType.MOD1_MASK : Gdk.ModifierType.MOD4_MASK;
                real |= mapped;
            }

            return real;
        }

        private Accel[] parse_accels(string[] accels, Gdk.Keymap ? keymap) {
            Accel[] parsed = {};

            foreach (unowned string accel in accels) {
                uint keyval;
                Gdk.ModifierType mods;
                Gtk.accelerator_parse(accel, out keyval, out mods);
                if (keyval == 0) continue;

                parsed += Accel() {
                    keyval = Gdk.keyval_to_lower(keyval),
                    mods = to_real(mods, keymap) & mod_mask
                };
            }

            return parsed;
        }

        private static bool matches_any(Accel[] accels, uint keyval, uint base_keyval, Gdk.ModifierType mods) {
            foreach (var accel in accels) {
                if ((accel.keyval == keyval || accel.keyval == base_keyval) && accel.mods == mods)
                    return true;
            }
            return false;
        }

        /**
         * Match a key press against the layout-switch shortcuts
         *
         * @param keyval The key as typed in the current layout
         * @param base_keyval The same physical key in the first layout, so that shortcuts on
         *                    letter keys also match while a non-Latin layout is active
         * @param state The modifier state of the key event
         * @return 1 for the next source, -1 for the previous source, 0 if this is not a shortcut
         */
        public int match(uint keyval, uint base_keyval, Gdk.ModifierType state) {
            uint lower = Gdk.keyval_to_lower(keyval);
            uint base_lower = Gdk.keyval_to_lower(base_keyval);
            var mods = state & mod_mask;

            if (matches_any(backward, lower, base_lower, mods)) return -1;
            if (matches_any(forward, lower, base_lower, mods)) return 1;
            return 0;
        }

        /**
         * True if Super, pressed while the modifiers in state are held, may be the
         * start of a layout-switch shortcut, so ilia should not exit on it yet
         *
         * Super pressed on its own still means "exit", so that Super+<key> keeps
         * reaching the window manager.
         */
        public bool super_starts_shortcut(Gdk.ModifierType state) {
            var held = state & mod_mask & ~super_mask;
            if (held == 0) return false;

            var wanted = held | super_mask;
            foreach (var accel in forward) {
                if ((wanted & ~accel.mods) == 0) return true;
            }
            foreach (var accel in backward) {
                if ((wanted & ~accel.mods) == 0) return true;
            }
            return false;
        }

        /**
         * Pick the input source a layout-switch shortcut activates
         *
         * Same choice as gnome-flashback's switcher: sources in most-recently-used order,
         * the current one first; the shortcut picks the second, the backward shortcut the last.
         *
         * @param sources Configured sources as "type:id", in settings order
         * @param mru Most-recently-used sources as "type:id"; may be empty or stale
         * @param current Index of the active source in sources, or -1
         * @param backward True for the backward shortcut
         * @return Index in sources to activate, or -1 if there is nothing to switch to
         */
        public static int pick_source(string[] sources, string[] mru, int current, bool backward) {
            int[] order = {};

            foreach (unowned string recent in mru) {
                for (int i = 0; i < sources.length; ++i) {
                    if (sources[i] == recent && !(i in order)) {
                        order += i;
                        break;
                    }
                }
            }
            for (int i = 0; i < sources.length; ++i) {
                if (!(i in order)) order += i;
            }

            if (current >= 0 && current < sources.length) {
                int[] reordered = { current };
                foreach (int i in order) {
                    if (i != current) reordered += i;
                }
                order = reordered;
            }

            if (order.length < 2) return -1;
            return backward ? order[order.length - 1] : order[1];
        }

        private static string[] read_sources(GLib.Settings settings, string key) {
            string[] sources = {};
            var iter = settings.get_value(key).iterator();
            string type, id;
            while (iter.next("(ss)", out type, out id)) {
                sources += type + ":" + id;
            }
            return sources;
        }

        /**
         * Ask gnome-flashback to activate the next (direction 1) or previous (-1) input source
         */
        public async void switch_source(int direction) {
            try {
                var bus = yield Bus.get(BusType.SESSION);

                var reply = yield bus.call(FLASHBACK_BUS_NAME, FLASHBACK_OBJECT_PATH, FLASHBACK_INTERFACE,
                                           "GetInputSources", null, new VariantType("(a(ussb)a{sv})"),
                                           DBusCallFlags.NO_AUTO_START, DBUS_TIMEOUT_MS, null);

                int count = 0;
                int current = -1;
                var iter = reply.get_child_value(0).iterator();
                uint index;
                unowned string short_name, display_name;
                bool active;
                while (iter.next("(u&s&sb)", out index, out short_name, out display_name, out active)) {
                    if (active) current = (int) index;
                    count++;
                }

                string[] sources = {};
                string[] mru = {};
                var schema_source = SettingsSchemaSource.get_default();
                if (schema_source != null && schema_source.lookup(INPUT_SOURCES_SCHEMA, true) != null) {
                    var settings = new GLib.Settings(INPUT_SOURCES_SCHEMA);
                    sources = read_sources(settings, "sources");
                    mru = read_sources(settings, "mru-sources");
                }
                // gnome-flashback numbers the sources it could load; use plain order if that is not the settings list
                if (sources.length != count) {
                    sources = new string[count];
                    for (int i = 0; i < count; ++i) sources[i] = i.to_string();
                    mru = {};
                }

                int target = pick_source(sources, mru, current, direction < 0);
                if (target < 0) return;

                yield bus.call(FLASHBACK_BUS_NAME, FLASHBACK_OBJECT_PATH, FLASHBACK_INTERFACE,
                               "Activate", new Variant("(u)", (uint) target), null,
                               DBusCallFlags.NO_AUTO_START, DBUS_TIMEOUT_MS, null);
            } catch (GLib.Error e) {
                stderr.printf("Unable to switch keyboard layout: %s\n", e.message);
            }
        }
    }
}
