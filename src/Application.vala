using Gtk;

// Default style
char * default_css = """
                .root_box {
                    margin: 8px;
                }

                window {
                    border-style: dotted;
                    border-width: 1px;
                }

                .filter_entry {
                    border: none;
                    background: none;
                    min-height: 36px;
                    min-width: 320px;
                }

                .notebook {
                    border: none;
                }

                .keybindings {
                    font-family: monospace;
                }
            """;

namespace Ilia {
    class Application : Gtk.Application {
        private GLib.HashTable<string, string ?> arg_map;
        private Ilia.DialogWindow ? window = null;
        private DBusConnection ? session_bus = null;
        private DBusConnection ? system_bus = null;

        // The style of the window shown, applied to the screen
        private Gtk.CssProvider ? style_provider = null;
        // A stylesheet that cannot be read; the call ends with this error
        private string ? style_error = null;

        // In the background copy: the socket calls come in on, and the call whose window is shown
        private ResidentServer ? resident_server = null;
        private ResidentRequest ? current_request = null;
        // The settings that switch the background copy off
        private GLib.Settings ? resident_settings = null;
        // The window manager connection that tells the background copy the session has ended
        private IPCClient ? wm_watch = null;
        // How long a restarting window manager has to come back before the background copy ends
        private const int64 WM_RESTART_WAIT_US = 3000000;
        // Ownership of the launcher's bus name while the background copy shows a window
        private uint launcher_name_id = 0;
        // End once the window shown is finished
        private bool quit_when_idle = false;
        private bool ending = false;

        public Application (HashTable<string, string ?> arg_map) {
            Object(
                application_id: "org.regolith.launcher",
                flags: ApplicationFlags.REPLACE | ApplicationFlags.ALLOW_REPLACEMENT
            );
            this.arg_map = arg_map;
        }

        /**
         * The background copy: it has no window of its own and takes over no other process,
         * it shows the windows of the calls that come in on the server's socket
         */
        public Application.resident(ResidentServer server) {
            Object(
                application_id: null,
                flags: ApplicationFlags.NON_UNIQUE
            );
            this.arg_map = new HashTable<string, string ?>(str_hash, str_equal);
            this.resident_server = server;
        }

        protected override bool local_command_line(ref unowned string[] args, out int exit_status) {
            // Start reading the desktop files now, on a worker thread, so that it overlaps with GTK's startup.
            // GtkApplication only sets the locale in the base local_command_line(), so set it first:
            // GLib translates the desktop files' Name and Keywords as it reads them
            if (resident_server == null && (arg_map.contains("-a") || (arg_map.get("-p") ?? "apps").down() == "apps")) {
                Intl.setlocale(LocaleCategory.ALL, "");
                DesktopAppPage.prefetch_apps();
            }
            args[0] = null;
            return base.local_command_line(ref args, out exit_status);
        }

        protected override void activate() {
            // Until GTK has e6372d29; see KeyListenerGuard.vala
            KeyListenerGuard.install();

            if (resident_server != null) {
                start_resident();
                return;
            }

            watch_sleep_and_lock();
            if (!show_window(arg_map))
                Process.exit(1);
        }

        /**
         * Build and show the window for a call, with the call's arguments: its pages, its style
         * and its input grabs. Returns false, having printed why, if it cannot be shown.
         */
        private bool show_window(HashTable<string, string ?> arg_map) {
            // Use the backend GDK connected with: XDG_SESSION_TYPE is not set in every Wayland session
            // (sway started from a TTY), and GDK_BACKEND or a missing compositor can mean X11
            var is_wayland_session = Gdk.Display.get_default().get_type().name() == "GdkWaylandDisplay";

            // Set window manager
            string wm_name = get_wm_name();

            var window = new Ilia.DialogWindow(arg_map, is_wayland_session, wm_name);
            window.set_application(this);

            // Grab inputs from wayland backend before showing window
            if (is_wayland_session) {
                bool is_layer_shell_supported = GtkLayerShell.is_supported();
                if (!is_layer_shell_supported) {
                    stderr.printf("The wayland compositor does not support the layer-shell protocol, aborting.");
                    window.destroy();
                    return false;
                }
                GtkLayerShell.init_for_window(window);
                GtkLayerShell.set_layer(window, GtkLayerShell.Layer.OVERLAY);
                GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            }
            place_on_focused_output(window, is_wayland_session, wm_name);

            if (!initialize_style(arg_map)) {
                window.destroy();
                return false;
            }
            this.window = window;
            // Startup timing, shown with G_MESSAGES_DEBUG=all along with the pages' own timings
            var show_timer = new GLib.Timer();
            ulong first_draw = 0;
            first_draw = window.draw.connect(() => {
                debug("First draw (%.3f seconds since show_all)", show_timer.elapsed());
                window.disconnect(first_draw);
                return false;
            });
            window.show_all();

            // Grab inputs from X11 backend after showing window
            if (!is_wayland_session) {
                Gdk.Window gdkwin = window.get_window();
                var seat = grab_inputs(gdkwin);
                if (seat == null) {
                    stderr.printf("Failed to acquire access to input devices, aborting.");
                    return false;
                }
                window.set_seat(seat);
            }

            // Handle mouse clicks by determining if a click is in or out of bounds
            // If we get a mouse click out of bounds of the window, exit.
            window.button_press_event.connect((event) => {
                int window_width = 0, window_height = 0;
                window.get_size(out window_width, out window_height);

                int mouse_x = (int) event.x;
                int mouse_y = (int) event.y;

                var click_out_bounds = ((mouse_x < 0 || mouse_y < 0) || (mouse_x > window_width || mouse_y > window_height));

                if (click_out_bounds)
                    window.quit();

                return !click_out_bounds;
            });
            return true;
        }

        /*
         * Open the window on the output that has focus now. What GDK knows of the monitors, and
         * where the pointer is, need not match the window manager's outputs, so ask it.
         */
        private void place_on_focused_output(Ilia.DialogWindow window, bool is_wayland_session, string wm_name) {
            if (wm_name == "Unknown")
                return;

            Gdk.Rectangle area;
            try {
                area = new IPCClient(wm_name).getFocusedWorkspaceRect();
            } catch (GLib.Error e) {
                return;     // GTK places the window, as before
            }
            if (area.width <= 0 || area.height <= 0)
                return;

            if (is_wayland_session) {
                // The compositor centres the layer surface on the output it is given
                var display = window.get_display();
                int centre_x = area.x + area.width / 2, centre_y = area.y + area.height / 2;
                for (int i = 0; i < display.get_n_monitors(); i++) {
                    var monitor = display.get_monitor(i);
                    Gdk.Rectangle geometry = monitor.get_geometry();
                    if (centre_x >= geometry.x && centre_x < geometry.x + geometry.width
                        && centre_y >= geometry.y && centre_y < geometry.y + geometry.height) {
                        GtkLayerShell.set_monitor(window, monitor);
                        break;
                    }
                }
            }

            // On X11 the window is unmanaged and stays where it is put: keep it centred on the area
            // as its size changes, as GTK does on a monitor it knows. On Wayland this is only the
            // position GTK reports, as to accessibility tools; it now names the right output.
            window.set_position(Gtk.WindowPosition.NONE);
            window.size_allocate.connect(() => {
                int width, height, x, y;
                window.get_size(out width, out height);
                window.get_position(out x, out y);
                int centred_x = area.x + (area.width - width) / 2;
                int centred_y = area.y + (area.height - height) / 2;
                if (x != centred_x || y != centred_y)
                    window.move(centred_x, centred_y);
            });
        }

        // The window manager of the session: sway is detected from SWAYSOCK, which it sets for its session
        private static string get_wm_name() {
            string sway_sock = Environment.get_variable("SWAYSOCK");
            string i3_sock = Environment.get_variable("I3SOCK");

            string wm_name = "Unknown";
            if (sway_sock != null)
                wm_name = "sway";
            else if (i3_sock != null)
                wm_name = "i3";
            return wm_name;
        }

        // Close when the system is about to suspend or the screen gets locked. On X11 ilia
        // grabs the keyboard and pointer, and while it does the screen locker cannot lock.
        private void watch_sleep_and_lock() {
            session_bus = get_dbus_connection();
            if (session_bus == null) {
                // The background copy does not register on the bus
                try {
                    session_bus = Bus.get_sync(BusType.SESSION);
                } catch (GLib.Error e) {
                    stderr.printf("Cannot watch for the screen locking: %s\n", e.message);
                }
            }
            if (session_bus != null)
                session_bus.signal_subscribe("org.gnome.ScreenSaver", "org.gnome.ScreenSaver", "ActiveChanged",
                                             "/org/gnome/ScreenSaver", null, DBusSignalFlags.NONE, on_sleep_or_lock_signal);

            Bus.get.begin(BusType.SYSTEM, null, (obj, res) => {
                try {
                    // Keep a reference: the subscription ends when the connection is freed
                    system_bus = Bus.get.end(res);
                    system_bus.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
                                                "/org/freedesktop/login1", null, DBusSignalFlags.NONE, on_sleep_or_lock_signal);
                } catch (GLib.Error e) {
                    stderr.printf("Cannot watch for suspend: %s\n", e.message);
                }
            });
        }

        private void on_sleep_or_lock_signal(DBusConnection connection, string ? sender, string path,
                                             string interface_name, string signal_name, Variant parameters) {
            if (window != null && is_sleep_or_lock_signal(interface_name, signal_name, parameters))
                window.quit();
        }

        /*
         * Apply the style of a call to the screen: the stylesheet given with -t, read from its
         * file now, else the built-in style unless -n is given. Returns false if the stylesheet
         * does not exist, having printed so, or cannot be read; the last is a fatal error.
         */
        private bool initialize_style(HashTable<string, string ?> arg_map) {
            Gtk.CssProvider ? css_provider = null;
            try {
                if (arg_map.contains("-t") && arg_map.get("-t") != null) {
                    var file = File.new_for_path(arg_map.get("-t"));

                    if (!file.query_exists()) {
                        printerr("File '%s' does not exist.\n", file.get_path());
                        return false;
                    }
                    css_provider = new Gtk.CssProvider();
                    css_provider.load_from_file(file);
                } else if (!arg_map.contains("-n")) {
                    css_provider = new Gtk.CssProvider();
                    css_provider.load_from_data((string) default_css);
                }
            } catch (GLib.Error ex) {
                if (resident_server == null)
                    error("Failed to initalize style: " + ex.message);
                // The caller raises the error itself, as it would have shown the window
                style_error = "Failed to initalize style: " + ex.message;
                return false;
            }

            if (css_provider != null) {
                Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER);
                style_provider = css_provider;
            }
            return true;
        }

        // Take the style of the last window off the screen: the next call brings its own
        private void remove_style() {
            if (style_provider != null) {
                Gtk.StyleContext.remove_provider_for_screen(Gdk.Screen.get_default(), style_provider);
                style_provider = null;
            }
        }

        /*
         * The background copy starts: it stays without a window until calls come in, and ends
         * when the setting is switched off or the session goes away
         */
        private void start_resident() {
            hold();

            resident_settings = new GLib.Settings("org.regolith-linux.ilia");
            resident_settings.changed["resident-mode"].connect(() => {
                if (!resident_settings.get_boolean("resident-mode"))
                    quit_resident();
            });
            if (!resident_settings.get_boolean("resident-mode")) {
                quit_resident();
                return;
            }

            // The window manager going away ends the session; the display server going away
            // ends the process from GDK. A window manager that cannot be followed does not end
            // the background copy.
            if (get_wm_name() != "Unknown")
                watch_window_manager();

            watch_sleep_and_lock();

            resident_server.request_received.connect(on_request);
            try {
                resident_server.start();
            } catch (GLib.Error e) {
                quit_resident(true);
            }
        }

        /*
         * End the background copy when the window manager exits. i3 also closes the connection
         * when it restarts in place, and is back on the same socket a moment later: the
         * background copy then follows the new instance, and ends only if it does not come back.
         * Returns false if the window manager cannot be followed.
         */
        private bool watch_window_manager() {
            bool restarting = false;
            try {
                wm_watch = new IPCClient(get_wm_name());
                wm_watch.subscribe({ "shutdown" }, (event, payload) => {
                    unowned Json.Object ? change = payload.get_node_type() == Json.NodeType.OBJECT ? payload.get_object() : null;
                    restarting = event == WM_EVENT.SHUTDOWN && change != null
                                 && change.get_string_member_with_default("change", "") == "restart";
                }, () => {
                    wm_watch = null;
                    if (restarting)
                        follow_restart();
                    else
                        quit_resident(true);
                });
                return true;
            } catch (GLib.Error e) {
                wm_watch = null;
                return false;
            }
        }

        // Reconnect to a window manager that is restarting, or end once it is clearly gone
        private void follow_restart() {
            int64 give_up = get_monotonic_time() + WM_RESTART_WAIT_US;
            Timeout.add(100, () => {
                if (ending || watch_window_manager())
                    return Source.REMOVE;
                if (get_monotonic_time() < give_up)
                    return Source.CONTINUE;
                quit_resident(true);
                return Source.REMOVE;
            });
        }

        /*
         * True once the files this process runs from have been replaced, as by a package
         * upgrade: its windows would no longer be those of the installed launcher
         */
        private static bool program_replaced() {
            try {
                if (FileUtils.read_link("/proc/self/exe").has_suffix(" (deleted)"))
                    return true;
                string maps;
                FileUtils.get_contents("/proc/self/maps", out maps);
                return maps.contains("/ilia-ui.so (deleted)");
            } catch (FileError e) {
                return false;
            }
        }

        /*
         * While the background copy shows a window, it owns the bus name that a launcher process
         * showing its own window registers, as a later launcher process would: such a window,
         * for example that of a textlist call, closes, and the session never has two. Windows
         * the background copy shows are not taken over through the name: every call reaches the
         * background copy first, which closes its window before the call shows its own.
         */
        private void take_launcher_name() {
            if (session_bus != null && launcher_name_id == 0)
                launcher_name_id = Bus.own_name_on_connection(session_bus, "org.regolith.launcher",
                                                              BusNameOwnerFlags.ALLOW_REPLACEMENT | BusNameOwnerFlags.REPLACE);
        }

        private void release_launcher_name() {
            if (launcher_name_id != 0) {
                Bus.unown_name(launcher_name_id);
                launcher_name_id = 0;
            }
        }

        // End the background copy; with now set, also if a window is showing
        private void quit_resident(bool now = false) {
            if (current_request != null && !now) {
                quit_when_idle = true;
                return;
            }
            finish_request(0);
            end_resident();
        }

        // A call came in for the background copy
        private void on_request(ResidentRequest request) {
            if (!resident_settings.get_boolean("resident-mode")) {
                // Switched off: the call starts from scratch, and this copy ends
                request.decline();
                quit_resident(true);
                return;
            }
            if (!same_surroundings(request.environ, Environ.get()) || program_replaced()) {
                // The window would not be what a fresh start shows: the call starts from scratch
                // under its own surroundings or with the launcher now installed, and this copy,
                // now out of date, ends
                request.decline();
                quit_resident(true);
                return;
            }

            // There is one window per session: a later call takes it over, and the earlier call ends
            finish_request(0);
            if (!is_resident_page(request.arg_map)) {
                // Shown by the call's own process, as these pages always are
                request.decline();
                return;
            }
            if (!request.accept())
                return;
            current_request = request;
            take_launcher_name();
            // The caller has gone; nothing it asked for stays on screen. A request is only
            // cancelled before it is finished, that is while it is the current one.
            request.cancelled.connect(() => finish_request(1));

            if (!show_window(request.arg_map)) {
                finish_request(1, style_error);
                style_error = null;
                return;
            }
            finish_with_window(window, request);
        }

        /*
         * Finish the request when its window closes by itself. Apart from on_request(): what
         * this handler holds, the window included, goes with the window.
         */
        private void finish_with_window(Ilia.DialogWindow shown, ResidentRequest request) {
            shown.destroy.connect(() => {
                if (window == shown)
                    window = null;
                if (current_request == request)
                    finish_request(0);
            });
        }

        /*
         * Finish the call whose window is shown, if any: the window goes, without a grab, and
         * the caller ends with the status
         */
        private void finish_request(int status, string ? fatal_error = null) {
            var request = current_request;
            current_request = null;

            if (window != null) {
                var shown = window;
                window = null;
                shown.dismiss();
            }
            remove_style();
            release_launcher_name();

            if (request != null)
                request.finish(status, fatal_error);

            if (quit_when_idle && request != null)
                end_resident();
        }

        private void end_resident() {
            if (resident_server == null || ending)
                return;
            ending = true;
            release();
            quit();
        }

        // Grabs the input devices for a given window
        // Some systems exhibit behavior such that keyboard / mouse cannot be reliably grabbed.
        // As a workaround, this function will continue to attempt to grab these resources over an
        // increasing time window and eventually give up and exit if ultimately unable to aquire
        // the keyboard and mouse resources.
        Gdk.Seat ? grab_inputs(Gdk.Window gdkwin) {
            var display = gdkwin.get_display();  // Gdk.Display.get_default();
            if (display == null) {
                stderr.printf("Failed to get Display\n");
                return null;
            }

            var seat = display.get_default_seat();
            if (seat == null) {
                stdout.printf("Failed to get Seat from Display\n");
                return null;
            }

            int attempt = 0;
            Gdk.GrabStatus ? grabStatus = null;
            int wait_time = 1000;

            do {
                grabStatus = seat.grab(gdkwin, Gdk.SeatCapabilities.KEYBOARD | Gdk.SeatCapabilities.POINTER, true, null, null, null);
                if (grabStatus != Gdk.GrabStatus.SUCCESS) {
                    attempt++;
                    wait_time = wait_time * 2;
                    GLib.Thread.usleep(wait_time);
                }
            } while (grabStatus != Gdk.GrabStatus.SUCCESS && attempt < 8);

            if (grabStatus != Gdk.GrabStatus.SUCCESS) {
                stderr.printf("Aborting, failed to grab input: %d\n", grabStatus);
                return null;
            } else {
                return seat;
            }
        }
    }
}

