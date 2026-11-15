namespace Ilia {
    /**
     * The sessions whose feature packages differ: some kinds of features only exist for one of them.
     */
    public enum FeatureSession {
        X11,
        SWAY,
        UNKNOWN;

        // The i3 socket means the X11 session, the sway socket the sway session
        public static FeatureSession from_wm_name(string wm_name) {
            switch (wm_name) {
                case "i3":
                    return X11;
                case "sway":
                    return SWAY;
                default:
                    return UNKNOWN;
            }
        }
    }

    /**
     * The kinds of feature packages, in the order the Features page lists them.
     */
    public enum FeatureKind {
        LOOKS,
        BAR_BLOCKS,
        COMPOSITORS,
        WINDOW_MANAGER;

        public string to_label() {
            switch (this) {
                case LOOKS:
                    return "Looks";
                case BAR_BLOCKS:
                    return "Bar blocks";
                case COMPOSITORS:
                    return "Compositors";
                default:
                    return "Window manager";
            }
        }
    }

    /**
     * One feature package: all the service's entries of the package collapsed into one.
     */
    public class FeaturePackage : GLib.Object {
        public string name { get; private set; }
        public FeatureKind kind { get; private set; }
        public string summary { get; private set; }
        // The id of the first installed entry, null if the package is not installed
        public string ? installed_id { get; private set; default = null; }
        // The id of the first entry available for installation, null if there is none
        public string ? available_id { get; private set; default = null; }

        public bool installed {
            get { return installed_id != null; }
        }

        internal FeaturePackage (string name, FeatureKind kind, string summary) {
            this.name = name;
            this.kind = kind;
            this.summary = summary;
        }

        // Another entry of the package: an installed entry marks it installed and gives its summary
        internal void add_entry(string package_id, string summary, bool installed) {
            if (installed) {
                if (installed_id == null) {
                    installed_id = package_id;
                    this.summary = summary;
                }
            } else if (available_id == null) {
                available_id = package_id;
            }
        }
    }

    /**
     * Turns the package service's list of packages into the feature packages of a session.
     */
    public class FeatureCatalogue : GLib.Object {
        // Name prefixes of the feature packages, the kind of package they mark, and the sessions they belong to
        private struct FeaturePrefix {
            public string prefix;
            public FeatureKind kind;
            public bool x11;
            public bool sway;
        }

        private const FeaturePrefix[] PREFIXES = {
            { "regolith-look-", FeatureKind.LOOKS, true, true },
            { "regolith-wm-", FeatureKind.WINDOW_MANAGER, true, true },
            { "i3xrocks-", FeatureKind.BAR_BLOCKS, true, false },
            { "regolith-compositor-", FeatureKind.COMPOSITORS, true, false },
            { "regolith-i3-", FeatureKind.WINDOW_MANAGER, true, false },
            { "regolith-sway-", FeatureKind.WINDOW_MANAGER, false, true },
        };

        // Packages with these name endings are parts of a feature, not features themselves
        private const string[] HIDDEN_SUFFIXES = { "-loader", "-default-style", "-session", "-config" };

        private const string TRANSITIONAL_SUMMARY = "transitional package";

        private FeatureSession session;
        private Gee.HashMap<string, FeaturePackage> by_name = new Gee.HashMap<string, FeaturePackage>();

        public FeatureCatalogue (FeatureSession session) {
            this.session = session;
        }

        /**
         * The kind of feature package name is in session, false if name is not a feature package there.
         */
        public static bool kind_of(string name, FeatureSession session, out FeatureKind kind) {
            kind = FeatureKind.LOOKS;
            foreach (var entry in PREFIXES) {
                if (!name.has_prefix(entry.prefix))
                    continue;
                // Without a known session, only the features of every session are listed
                bool in_session = session == FeatureSession.X11 ? entry.x11 :
                                  session == FeatureSession.SWAY ? entry.sway :
                                  entry.x11 && entry.sway;
                if (!in_session)
                    return false;
                kind = entry.kind;
                return true;
            }
            return false;
        }

        /**
         * True for packages that match a prefix but are no feature: parts of a feature and transitional packages.
         */
        public static bool is_hidden(string name, string summary) {
            foreach (unowned string suffix in HIDDEN_SUFFIXES) {
                if (name.has_suffix(suffix))
                    return true;
            }
            return summary.down().has_prefix(TRANSITIONAL_SUMMARY);
        }

        /**
         * Add an entry of the service's reply, in the order of the reply.
         */
        public void add(string package_id, string summary, bool installed) {
            string name = package_id.split(";", 2)[0];
            FeatureKind kind;
            if (!kind_of(name, session, out kind) || is_hidden(name, summary))
                return;

            var package = by_name.get(name);
            if (package == null) {
                package = new FeaturePackage(name, kind, summary);
                by_name.set(name, package);
            }
            package.add_entry(package_id, summary, installed);
        }

        /**
         * The feature packages, by kind and then by name (byte by byte).
         */
        public FeaturePackage[] get_packages() {
            var list = new Gee.ArrayList<FeaturePackage>();
            list.add_all(by_name.values);
            list.sort((a, b) => {
                if (a.kind != b.kind)
                    return a.kind < b.kind ? -1 : 1;
                return strcmp(a.name, b.name);
            });
            return list.to_array();
        }

        /**
         * True if the service marks package_id as an installed package: its data starts with "installed".
         */
        public static bool is_installed_id(string package_id) {
            var parts = package_id.split(";");
            return parts.length >= 4 && parts[3].has_prefix("installed");
        }

        /**
         * Package names, each once, in byte order and separated by ", ".
         */
        public static string name_list(string[] names) {
            var sorted = new Gee.TreeSet<string>((a, b) => strcmp(a, b));
            foreach (unowned string name in names)
                sorted.add(name);
            return string.joinv(", ", sorted.to_array());
        }

        /**
         * The question asked before installing name would remove the installed packages removals.
         */
        public static string install_prompt(string name, string[] removals) {
            return "Install %s and remove %s? Enter to confirm, Escape to cancel.".printf(name, name_list(removals));
        }

        /**
         * The question asked before removing name, and with it the packages also_removed.
         */
        public static string remove_prompt(string name, string[] also_removed) {
            if (also_removed.length == 0)
                return "Remove %s? Enter to confirm, Escape to cancel.".printf(name);
            return "Remove %s and also %s? Enter to confirm, Escape to cancel.".printf(name, name_list(also_removed));
        }

        /**
         * The state of a package while it is installed or removed; percentage is shown only within 0 to 100.
         */
        public static string transaction_state(bool install, int percentage) {
            string state = install ? "Installing" : "Removing";
            if (percentage >= 0 && percentage <= 100)
                state += " %d%%".printf(percentage);
            return state;
        }

        /**
         * True if a package's name or summary holds query, case disregarded.
         */
        public static bool matches(string query, string name, string summary) {
            if (query.length == 0)
                return true;
            string folded = fold_case(query);
            return fold_case(name).contains(folded) || fold_case(summary).contains(folded);
        }

        private static string fold_case(string text) {
            return text.casefold().normalize(-1, NormalizeMode.DEFAULT_COMPOSE) ?? text.casefold();
        }
    }
}
