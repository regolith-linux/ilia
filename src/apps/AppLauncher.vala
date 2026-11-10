namespace Ilia {
    /**
     * Starts desktop apps for a page, as the apps page does, records each launch in the
     * launch history, and closes ilia
     *
     * An app is started at most once: a double click activates a row twice.
     */
    public class AppLauncher : GLib.Object {
        // The message bus itself, which starts apps from their service files
        private const string DBUS_NAME = "org.freedesktop.DBus";
        private const string DBUS_PATH = "/org/freedesktop/DBus";
        // Time a running app has to answer an activation request before the page closes
        private const int ACTIVATE_TIMEOUT_MS = 3000;

        private GLib.Settings settings;
        private SessionContoller session_controller;
        // Set once an app is launched; the page closes afterwards
        private bool launching = false;

        public AppLauncher (GLib.Settings settings, SessionContoller session_controller) {
            this.settings = settings;
            this.session_controller = session_controller;
        }

        /**
         * Launch a desktop app, unless one was launched already, then close
         *
         * The app runs in its own systemd scope (see get_desktop_launch_argv()); a
         * DBusActivatable app is asked over the session bus instead.
         */
        public void launch(DesktopAppInfo app_info) {
            if (launching)
                return;
            launching = true;

            string ? bus_name = get_dbus_activation_name(app_info);
            if (bus_name != null) {
                activate_app.begin(app_info, bus_name);
                return;
            }

            try {
                bool launched = true;
                if (needs_terminal(app_info) && GLib.Environment.find_program_in_path("x-terminal-emulator") == null) {
                    // GLib picks a terminal it knows, and runs the entry outside a scope
                    launched = app_info.launch(null, null);
                } else {
                    Pid pid;
                    Process.spawn_async(get_desktop_working_directory(app_info), get_desktop_launch_argv(app_info),
                                        null, SpawnFlags.SEARCH_PATH, null, out pid);
                }

                if (launched)
                    record_launch(settings, app_info.get_id());
                else
                    stderr.printf("Failed to launch %s\n", app_info.get_name());
            } catch (GLib.Error e) {
                stderr.printf("Failed to launch %s: %s\n", app_info.get_name(), e.message);
            }
            session_controller.quit();
        }

        /*
         * Start a DBusActivatable app over the session bus, with Activate on its
         * org.freedesktop.Application interface, as the Desktop Entry Specification describes
         */
        private async void activate_app(DesktopAppInfo app_info, string bus_name) {
            try {
                var bus = yield Bus.get(BusType.SESSION);

                // Have the bus start the app first if it is not running: a message that waits
                // for its destination to start is dropped once the sender has disconnected.
                var has_owner = yield bus.call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "NameHasOwner",
                                               new Variant("(s)", bus_name), new VariantType("(b)"),
                                               DBusCallFlags.NONE, -1);

                if (!has_owner.get_child_value(0).get_boolean())
                    yield bus.call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "StartServiceByName",
                                   new Variant("(su)", bus_name, (uint32) 0), new VariantType("(u)"),
                                   DBusCallFlags.NONE, -1);

                var platform_data = new VariantBuilder(new VariantType("a{sv}"));
                yield bus.call(bus_name, get_dbus_activation_path(bus_name), "org.freedesktop.Application",
                               "Activate", new Variant("(a{sv})", platform_data),
                               null, DBusCallFlags.NO_AUTO_START, ACTIVATE_TIMEOUT_MS);

                record_launch(settings, app_info.get_id());
            } catch (GLib.Error e) {
                stderr.printf("Failed to activate %s: %s\n", app_info.get_name(), e.message);
            }
            session_controller.quit();
        }
    }
}
