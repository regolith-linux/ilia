namespace Ilia {
    /**
     * Translate a key code, with real X modifiers held, to its key symbol in a layout
     *
     * @param keycode X key code
     * @param mods Real X modifiers (ShiftMask to Mod5Mask)
     * @param group Layout (keyboard group), from 0
     * @param keyval The key symbol
     * @param level The shift level the key symbol is on, from 0
     * @return false if the key has no symbol there
     */
    public delegate bool KeyTranslator(uint keycode, uint mods, int group, out uint keyval, out int level);

    /**
     * A keyboard binding of i3, as i3 reads it from its configuration
     */
    public class WmBinding {
        // The binding mode it belongs to
        public string mode;
        // bindsym: the key symbol; 0 for bindcode
        public uint keyval;
        // bindcode: the key code; 0 for bindsym
        public uint keycode;
        // Real X modifiers (ShiftMask to Mod5Mask)
        public uint mods;
        // The layout given with Group1 to Group4 (from 0), or -1 for any layout
        public int group = -1;
        // --release: runs when the key is released
        public bool release;
        // The command, as the configuration has it
        public string command;
    }

    /**
     * The keyboard bindings of an i3 configuration, matched against key events as i3 matches them
     *
     * - Only the bindings of the current binding mode count.
     * - bindsym: the key is looked up in the binding's layout (the first, unless one is given),
     *   with the binding's modifiers; if that gives another symbol and the key is not on a level
     *   above Shift, it is looked up again with Shift toggled ("Shift+x" matches the x key).
     * - bindcode: the key code must be the binding's.
     * - The modifiers held must be exactly the binding's. Caps Lock is ignored, and Num Lock
     *   as long as it does not change the key's symbol.
     */
    public class WmBindings {
        public const string DEFAULT_MODE = "default";

        private const uint SHIFT_MASK = 1 << 0;
        private const uint LOCK_MASK = 1 << 1;
        private const uint CONTROL_MASK = 1 << 2;
        private const uint MOD1_MASK = 1 << 3;
        // Real X modifiers
        public const uint MODIFIER_MASK = 0xff;

        private WmBinding[] bindings = {};

        /**
         * Read the keyboard bindings of an i3 configuration, with variables already replaced
         * (as in the "variable_replaced_contents" of i3's configuration reply)
         */
        public WmBindings.from_i3_config(string config) {
            // Bindings count at the top level and directly inside a mode block; blocks such as "bar { }" have bindings of their own
            int depth = 0;
            string ? mode = null;

            foreach (unowned string line in join_continued_lines(config)) {
                string text = line.strip();
                if (text == "" || text.has_prefix("#"))
                    continue;

                // A command is the rest of its line, so a binding may end in a brace too
                var binding = parse_binding(text);
                if (binding != null) {
                    if (depth == 0 || (depth == 1 && mode != null)) {
                        binding.mode = mode ?? DEFAULT_MODE;
                        bindings += binding;
                    }
                    continue;
                }

                if (text.has_prefix("}")) {
                    if (depth > 0) depth--;
                    if (depth == 0) mode = null;
                    continue;
                }

                if (text.has_suffix("{")) {
                    string ? name = depth == 0 ? parse_mode_name(text) : null;
                    if (name != null)
                        mode = name;
                    depth++;
                }
            }
        }

        // Lines ending in a backslash continue on the next line
        private static string[] join_continued_lines(string config) {
            string[] lines = {};
            var current = new StringBuilder();

            foreach (unowned string line in config.split("\n")) {
                string chomped = line.chomp();
                if (chomped.has_suffix("\\")) {
                    current.append(chomped.substring(0, chomped.length - 1));
                    continue;
                }
                current.append(chomped);
                lines += current.str;
                current.truncate();
            }
            if (current.len > 0)
                lines += current.str;

            return lines;
        }

        // Split off the next word, honouring double quotes; null at the end of the text
        private static string ? next_word(string text, ref int pos, bool unquote = false) {
            while (pos < text.length && text[pos].isspace())
                pos++;
            if (pos >= text.length)
                return null;

            var word = new StringBuilder();
            bool quoted = false;
            while (pos < text.length && (quoted || !text[pos].isspace())) {
                char c = text[pos];
                if (c == '"') {
                    quoted = !quoted;
                    if (!unquote)
                        word.append_c(c);
                } else if (c == '\\' && quoted && pos + 1 < text.length) {
                    pos++;
                    if (!unquote)
                        word.append_c(c);
                    word.append_c(text[pos]);
                } else {
                    word.append_c(c);
                }
                pos++;
            }
            return word.str;
        }

        // "mode [--pango_markup] <name> {" gives the name
        private static string ? parse_mode_name(string text) {
            string head = text.substring(0, text.length - 1).strip();
            int pos = 0;
            var keyword = next_word(head, ref pos);
            if (keyword == null || keyword.ascii_down() != "mode")
                return null;

            string ? name = next_word(head, ref pos, true);
            if (name == "--pango_markup")
                name = next_word(head, ref pos, true);
            if (name == null || name == "" || next_word(head, ref pos) != null)
                return null;
            return name;
        }

        private static bool is_option(string word, ref bool release) {
            switch (word) {
                case "--release":
                    release = true;
                    return true;
                case "--border":
                case "--whole-window":
                case "--exclude-titlebar":
                    return true;
                default:
                    return false;
            }
        }

        // Parse "Mod1+Shift" style modifiers into a mask and layout; false for an unknown modifier
        private static bool parse_modifiers(string[] names, out uint mods, out int group) {
            mods = 0;
            group = -1;

            foreach (unowned string name in names) {
                switch (name.ascii_down()) {
                    case "shift": mods |= SHIFT_MASK; break;
                    case "control":
                    case "ctrl": mods |= CONTROL_MASK; break;
                    case "mod1": mods |= MOD1_MASK; break;
                    case "mod2": mods |= 1 << 4; break;
                    case "mod3": mods |= 1 << 5; break;
                    case "mod4": mods |= 1 << 6; break;
                    case "mod5": mods |= 1 << 7; break;
                    case "group1": group = 0; break;
                    case "group2":
                    case "mode_switch": group = 1; break;
                    case "group3": group = 2; break;
                    case "group4": group = 3; break;
                    default: return false;
                }
            }
            return true;
        }

        // "bindsym|bindcode [options] [modifiers+]key [options] command"
        private static WmBinding ? parse_binding(string text) {
            int pos = 0;
            var keyword = next_word(text, ref pos);
            if (keyword == null)
                return null;
            bool by_code = keyword.ascii_down() == "bindcode";
            if (!by_code && keyword.ascii_down() != "bindsym")
                return null;

            bool release = false;
            string ? spec = next_word(text, ref pos);
            while (spec != null && is_option(spec, ref release))
                spec = next_word(text, ref pos);
            if (spec == null)
                return null;

            // Options may also follow the key
            int command_start = pos;
            string ? word = next_word(text, ref pos);
            while (word != null && is_option(word, ref release)) {
                command_start = pos;
                word = next_word(text, ref pos);
            }
            string command = text.substring(command_start).strip();
            if (command == "")
                return null;

            string[] parts = spec.split("+");
            string key = parts[parts.length - 1];
            uint mods = 0;
            int group = -1;
            if (key == "" || !parse_modifiers(parts[0 : parts.length - 1], out mods, out group))
                return null;

            var binding = new WmBinding();
            binding.release = release;
            binding.command = command;
            binding.mods = mods;
            binding.group = group;

            if (by_code) {
                uint64 code;
                if (!uint64.try_parse(key, out code) || code == 0 || code > 255)
                    return null;
                binding.keycode = (uint) code;
            } else {
                // Mouse button bindings are not keys
                if (key.ascii_down().has_prefix("button"))
                    return null;
                binding.keyval = Gdk.keyval_from_name(key);
                if (binding.keyval == 0 || binding.keyval == Gdk.Key.VoidSymbol)
                    return null;
            }
            return binding;
        }

        // Keypad keys keep their own symbol: KP_1 can be bound apart from KP_End
        private static bool is_keypad_symbol(uint keyval) {
            return keyval >= Gdk.Key.KP_Space && keyval <= Gdk.Key.KP_Equal;
        }

        /**
         * True if the binding matches a key press
         *
         * @param keycode X key code of the event
         * @param mods Real modifiers of the event
         * @param group Active layout of the event, from 0
         * @param numlock_mask The real modifier that carries Num Lock
         */
        public static bool matches(WmBinding binding, uint keycode, uint mods, int group, uint numlock_mask, KeyTranslator translate) {
            if (binding.group >= 0 && binding.group != group)
                return false;

            mods &= MODIFIER_MASK & ~LOCK_MASK;
            bool with_numlock = false;
            if (mods != binding.mods) {
                if (numlock_mask == 0 || (binding.mods & numlock_mask) != 0 || mods != (binding.mods | numlock_mask))
                    return false;
                with_numlock = true;
            }

            int layout = int.max(binding.group, 0);
            uint keyval;
            int level;

            if (binding.keycode != 0) {
                if (keycode != binding.keycode)
                    return false;
                if (!with_numlock)
                    return true;
                // Num Lock is ignored only where it does not change the symbol
                uint keyval_numlock;
                if (!translate(keycode, binding.mods, layout, out keyval, out level))
                    return false;
                return translate(keycode, binding.mods | numlock_mask, layout, out keyval_numlock, out level) && keyval_numlock == keyval;
            }

            uint state = binding.mods;
            if (!translate(keycode, state, layout, out keyval, out level))
                return false;
            if (keyval != binding.keyval) {
                if (level > 1 || is_keypad_symbol(keyval))
                    return false;
                state = binding.mods ^ SHIFT_MASK;
                if (!translate(keycode, state, layout, out keyval, out level) || keyval != binding.keyval)
                    return false;
            }

            if (with_numlock)
                return translate(keycode, state | numlock_mask, layout, out keyval, out level) && keyval == binding.keyval;
            return true;
        }

        /**
         * Find what i3 does with a key press in a binding mode
         *
         * @param on_press The binding that runs on the press, if any
         * @param on_release The release binding that the press arms, if no binding runs on the press
         */
        public void lookup(string mode, uint keycode, uint mods, int group, uint numlock_mask, KeyTranslator translate,
                           out WmBinding ? on_press, out WmBinding ? on_release) {
            on_press = null;
            on_release = null;

            foreach (var binding in bindings) {
                if (binding.mode != mode || !matches(binding, keycode, mods, group, numlock_mask, translate))
                    continue;
                if (!binding.release) {
                    on_press = binding;
                    on_release = null;
                    return;
                }
                if (on_release == null)
                    on_release = binding;
            }
        }
    }
}
