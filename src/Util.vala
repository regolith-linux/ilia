namespace Ilia {
    /**
     * Implement prev/next item for emacs and vim bindings
     *
     * returns true if key entry was handled
     */
    public static bool handle_emacs_vim_nav(Gtk.TreeView item_view, Gtk.TreePath path, Gdk.EventKey key) {
        if ((key.state & Gdk.ModifierType.CONTROL_MASK) == Gdk.ModifierType.CONTROL_MASK) { // CTRL
            bool is_last = selection_is_last(item_view.get_selection ());

            if (key.keyval == 'p' || key.keyval == 'k') {
                path.prev ();
                item_view.get_selection ().select_path(path);
                item_view.set_cursor(path, null, false);
                return true;
            } else if ((key.keyval == 'n' || key.keyval == 'j') && !is_last) {
                path.next ();
                item_view.get_selection ().select_path(path);
                item_view.set_cursor(path, null, false);
                return true;
            }
        }

        return false;
    }

    public static bool selection_is_last(Gtk.TreeSelection selection) {
        Gtk.TreeModel model;
        Gtk.TreeIter iter;
        if (selection.get_selected(out model, out iter))
            return !model.iter_next(ref iter);
        return false;
    }

    /*
     * Get the location for swaymsg or i3-msg as per the current session type
     */
    public static string ? get_wm_cli(string wm_name) {
        if (wm_name == "i3")
            return "/usr/bin/i3-msg ";
        else if (wm_name == "sway")
            return "/usr/bin/swaymsg ";
        return null;
    }

    /* Get AppInfo object used to run a command */
    public static AppInfo get_runner_app_info(AppInfo app_info) throws GLib.Error {
        string systemd_run_path = GLib.Environment.find_program_in_path("systemd-run");
        if (systemd_run_path == null)
            return app_info;
        string app_id = app_info.get_id ();
        stdout.printf("KG2: \nbefore: '%s'\nafter : '%s'\n", app_id, systemd_escape(app_id));
        stdout.flush();
        string exec = app_info.get_commandline ();
        string random_suffix = Uuid.string_random ().slice(0, 8);
        string unit_name = "run_ilia_" + systemd_escape(app_id) + "_" + random_suffix + ".scope";
        string systemd_launch = "systemd-run --user --scope --unit \"" + unit_name + "\" " + exec;
        return AppInfo.create_from_commandline(systemd_launch, app_id, AppInfoCreateFlags.NONE);
    }

    /*
     * The escaping algorithm operates as follows: 
     * given a string, any "/" character is replaced by "-", and all other characters which 
     * are not ASCII alphanumerics, ":", "_" or "." are replaced by C-style "\x2d" escapes. 
     * In addition, "." is replaced with such a C-style escape when it would appear 
     * as the first character in the escaped string.
     * 
     * When the input qualifies as absolute file system path, this algorithm is extended 
     * slightly: the path to the root directory "/" 
     * is encoded as single dash "-". 
     * In addition, any leading, trailing or duplicate "/" characters are removed from the string before 
     * transformation. Example: /foo//bar/baz/ becomes "foo-bar-baz".
     * - systemd.unit.5.en
     */
    public static string systemd_escape(string unescaped) {
        var escaped = new StringBuilder();
        
        if (unescaped.data[0] == '.') {
            escaped.append("\\x2e");
        } else {
            escaped.append_c(unescaped.@get(0));
        }

        for (int i = 1; i < unescaped.length; ++i) {
            uint8 c = unescaped.data[i];
       
            if (
                (c > 31 && c < 46) || 
                (c > 58 && c < 65) || 
                (c > 90 && c < 97 && c != 95) || 
                (c > 122)) {    // escape
                escaped.append_printf("\\x%llx", c);
            } else {                                                        // copy
                escaped.append_c(unescaped.@get(i));
            }
        }

        return escaped.str.replace("/", "-");
    }
    
    /**
     * Fuzzy search algorithm to match strings with more flexibility
     * Returns a score between 0-100 where 100 is a perfect match and 0 is no match
     */
    public static int fuzzy_match_score(string source, string pattern) {
        if (pattern.length == 0) return 100;
        if (source.length == 0) return 0;
        
        // Normalize strings for comparison
        string s_lower = source.down();
        string p_lower = pattern.down();
        
        // Check for exact substring match first (highest priority)
        if (s_lower.contains(p_lower)) {
            // Calculate score based on match position and completeness
            // Give higher scores to matches at the beginning
            int pos = s_lower.index_of(p_lower);
            if (pos == 0) {
                // Starting match is best
                return 95 + int.min(5, 5 * pattern.length / source.length);
            } else {
                // Penalize matches later in the string
                return 80 + int.min(15, 20 * pattern.length / source.length) - int.min(15, pos / 2);
            }
        }
        
        // Check for character matches in sequence
        int matched_chars = 0;
        int last_matched_pos = -1;
        int consecutive_matches = 0;
        int max_consecutive = 0;
        
        for (int i = 0; i < p_lower.length; i++) {
            char pattern_char = p_lower[i];
            bool found = false;
            
            // Start looking from the last matched position
            for (int j = last_matched_pos + 1; j < s_lower.length; j++) {
                if (s_lower[j] == pattern_char) {
                    matched_chars++;
                    
                    // Check for consecutive matches
                    if (last_matched_pos + 1 == j) {
                        consecutive_matches++;
                    } else {
                        consecutive_matches = 1;
                    }
                    
                    max_consecutive = int.max(max_consecutive, consecutive_matches);
                    last_matched_pos = j;
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                // Character not found in the source string
                return 0; // No match if not all characters are present
            }
        }
        
        // Calculate score based on matched characters, their consecutiveness,
        // and ratio to total string length
        double match_ratio = (double)matched_chars / (double)p_lower.length;
        double length_ratio = (double)p_lower.length / (double)s_lower.length;
        
        // Bonus for consecutive character matches
        double consecutive_bonus = (double)max_consecutive / (double)p_lower.length * 15.0;
        
        // Calculate final score (0-100)
        int score = (int)(match_ratio * 60.0 + length_ratio * 25.0 + consecutive_bonus);
        return int.min(75, score); // Cap at 75 to rank below exact substring matches
    }
    
    /**
     * Check if a string fuzzy matches a pattern with a minimum threshold
     */
    public static bool fuzzy_match(string source, string pattern, int threshold = 50) {
        return fuzzy_match_score(source, pattern) >= threshold;
    }
}
