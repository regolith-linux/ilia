namespace Ilia {
    /**
     * Chooses the power profile through the power-profiles daemon on the system bus, at
     * its current name, or at its former name when only that one is owned.
     */
    class PowerPage : QuickPanelPage {
        private const string NEW_NAME = "org.freedesktop.UPower.PowerProfiles";
        private const string NEW_PATH = "/org/freedesktop/UPower/PowerProfiles";
        private const string OLD_NAME = "net.hadess.PowerProfiles";
        private const string OLD_PATH = "/net/hadess/PowerProfiles";

        private const string NOT_AVAILABLE = "Power profiles are not available";

        // The name, object and interface in use
        private string service_name;
        private string service_path;

        // The profiles and the one that is active, as of the last reading
        private GenericArray<string> profiles = new GenericArray<string>();
        private string ? active_profile = null;

        public override string get_name() {
            return "<u>P</u>ower";
        }

        public override string get_icon_name() {
            return "power-profile-balanced-symbolic";
        }

        public override string get_help() {
            return "This page lists the power profiles. Enter makes the highlighted profile the active one.";
        }

        public override char get_keybinding() {
            return 'p';
        }

        public override HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);
            keybindings.set("enter", "Activate Profile");
            return keybindings;
        }

        protected override async void start() {
            if (bus != null && yield has_owner(NEW_NAME)) {
                service_name = NEW_NAME;
                service_path = NEW_PATH;
            } else if (bus != null && yield has_owner(OLD_NAME)) {
                service_name = OLD_NAME;
                service_path = OLD_PATH;
            } else {
                set_status(NOT_AVAILABLE);
                return;
            }
            follow_service(service_name);
            yield refresh();
        }

        protected override async GenericArray<PanelRow> ? read_rows() {
            Variant props;
            try {
                props = yield get_all(service_name, service_path, service_name);
            } catch (GLib.Error err) {
                return null;
            }

            var active = props.lookup_value("ActiveProfile", VariantType.STRING);
            active_profile = active != null ? active.get_string() : null;
            var degraded_value = props.lookup_value("PerformanceDegraded", VariantType.STRING);
            string degraded = degraded_value != null ? degraded_value.get_string() : "";

            var rows = new GenericArray<PanelRow>();
            profiles = new GenericArray<string>();
            var listed = props.lookup_value("Profiles", null);
            if (listed == null || !listed.get_type().is_array())
                return rows;

            var iter = listed.iterator();
            Variant ? entry;
            while ((entry = iter.next_value()) != null) {
                if (entry.is_of_type(VariantType.VARIANT))
                    entry = entry.get_variant();
                if (!entry.is_of_type(VariantType.VARDICT))
                    continue;
                var profile = entry.lookup_value("Profile", VariantType.STRING);
                if (profile == null)
                    continue;
                string name = profile.get_string();
                profiles.add(name);
                string detail = name == "performance" && degraded != "" ? "degraded: " + degraded : "";
                rows.add(new PanelRow(name, profile_label(name), detail, name == active_profile ? "Active" : ""));
            }
            return rows;
        }

        protected override async void activate(string key) {
            if (!profiles.find_with_equal_func(key, str_equal))
                return; // The row that says the daemon is not there
            if (key == active_profile) {
                finish(); // Already active: nothing to change
                return;
            }
            try {
                yield write_property(service_name, service_path, service_name, "ActiveProfile", new Variant.string(key));
                finish();
            } catch (GLib.Error err) {
                report_failure(profile_label(key), err);
            }
        }

        // How a profile is named in the list: the three standard ones by title, any other as it is
        public static string profile_label(string profile) {
            switch (profile) {
                case "power-saver":
                    return "Power Saver";
                case "balanced":
                    return "Balanced";
                case "performance":
                    return "Performance";
                default:
                    return profile;
            }
        }
    }
}
