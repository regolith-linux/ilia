namespace Ilia {
#if WAYLAND_CLIPBOARD
    // Serve text on the clipboard with Wayland's data control protocol, see WaylandClipboard.c
    [CCode (cname = "ilia_wayland_clipboard_serve")]
    extern int wayland_clipboard_serve([CCode (array_length_type = "size_t")] uint8[] text, ClipboardKeeper.ReadyFunc ready);
#endif

    /**
     * Puts text on the clipboard so that it is still there after ilia exits
     *
     * The text is offered through GTK and handed to the clipboard manager, as other copies in
     * ilia are, and that keeps it once ilia exits on desktops that run one. On those that do
     * not, the text would go away with ilia. So when ilia exits while it still owns the text
     * and the display has no clipboard manager, ilia starts itself in the background as a
     * keeper, which takes the clipboard over and serves the text until something else is
     * copied. On Wayland the keeper needs the compositor to support the ext-data-control
     * protocol, as wl-copy does.
     */
    public class ClipboardKeeper {
        // ilia started with this argument and a GDK backend name is a keeper
        public const string KEEP_ARGUMENT = "--keep-clipboard";
        // How long ilia waits, as it exits, for the keeper to take the clipboard over
        private const int TAKE_OVER_TIMEOUT_MILLISECONDS = 5000;

        // Called by the keeper once it serves the text
        [CCode (has_target = false)]
        public delegate void ReadyFunc();

        // Text on the clipboard, owning it there
        private class CopiedText : Object {
            public Gdk.Display display;
            public string text;

            public CopiedText(Gdk.Display display, string text) {
                this.display = display;
                this.text = text;
            }
        }

        // The text copied in ilia, while ilia owns the clipboard with it
        private static CopiedText ? owned_copy = null;

        private ClipboardKeeper() {
        }

        // Put text on the clipboard of display
        public static void copy(Gdk.Display display, string text) {
            var copy = new CopiedText(display, text);
            var clipboard = Gtk.Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);
            if (!clipboard.set_with_owner(text_targets(), get_clipboard_text, clear_owned_copy, copy))
                return;
            owned_copy = copy;
            clipboard.set_can_store(null);
            clipboard.store();
        }

        /**
         * Keep the text copied in ilia on the clipboard after ilia exits, see the class description
         *
         * Called as ilia exits. Returns once a keeper serves the text, or when there is no need
         * for one or it fails to start.
         */
        public static void keep_after_exit() {
            if (owned_copy == null || owned_copy.display.supports_clipboard_persistence())
                return;

            string backend = owned_copy.display.get_type().name() == "GdkWaylandDisplay" ? "wayland" : "x11";
            // The binary ilia runs from, named ilia. Not reaped by ilia, the keeper is started
            // through an intermediate process, so it is nobody's zombie once ilia has exited.
            string[] argv = { "/proc/self/exe", "ilia", KEEP_ARGUMENT, backend };
            Pid pid;
            int input, output;
            try {
                Process.spawn_async_with_pipes(null, argv, null, SpawnFlags.FILE_AND_ARGV_ZERO | SpawnFlags.STDERR_TO_DEV_NULL,
                                               null, out pid, out input, out output);
            } catch (SpawnError e) {
                warning("Cannot keep the copied text on the clipboard: %s", e.message);
                return;
            }

            // A keeper that failed is gone already: ilia must not be killed for writing to it
            Posix.signal(Posix.Signal.PIPE, Posix.SIG_IGN);
            var text_stream = new UnixOutputStream(input, true);
            try {
                text_stream.write_all(owned_copy.text.data, null);
                text_stream.close();
            } catch (IOError e) {
                warning("Cannot keep the copied text on the clipboard: %s", e.message);
            }

            // The keeper closes its output once it serves the text, or by exiting when it cannot
            Posix.pollfd[] fds = { Posix.pollfd() { fd = output, events = Posix.POLLIN } };
            int64 deadline = get_monotonic_time() + TAKE_OVER_TIMEOUT_MILLISECONDS * 1000;
            int64 remaining;
            while ((remaining = deadline - get_monotonic_time()) > 0) {
                if (Posix.poll(fds, (int) ((remaining + 999) / 1000)) >= 0 || Posix.errno != Posix.EINTR)
                    break;
            }
            Posix.close(output);
        }

        /**
         * Run as the keeper on the display of the given GDK backend: read the text from the
         * standard input, take the clipboard over, close the standard output to tell ilia, and
         * serve the text until something else is copied. Returns the exit status.
         */
        public static int serve(string backend) {
            // Leave ilia's session: what ends ilia's terminal or process group leaves the keeper
            Posix.setsid();

            string ? text = read_standard_input();
            if (text == null)
                return 1;

            switch (backend) {
                case "x11":
                    return serve_x11(text);
#if WAYLAND_CLIPBOARD
                case "wayland":
                    return wayland_clipboard_serve(text.data, signal_ready);
#endif
                default:
                    return 1;
            }
        }

        private static int serve_x11(string text) {
            // No window is shown
            Environment.set_variable("NO_AT_BRIDGE", "1", true);
            Gdk.set_allowed_backends("x11");
            unowned string[] ? no_args = null;
            if (!Gtk.init_check(ref no_args))
                return 1;

            var copy = new CopiedText(Gdk.Display.get_default(), text);
            var clipboard = Gtk.Clipboard.get_for_display(copy.display, Gdk.SELECTION_CLIPBOARD);
            // Serve until something else is copied
            if (!clipboard.set_with_owner(text_targets(), get_clipboard_text, (clipboard, owner) => Gtk.main_quit(), copy))
                return 1;
            signal_ready();
            Gtk.main();
            return 0;
        }

        // Close the standard output ilia waits on, leaving /dev/null in its place
        private static void signal_ready() {
            int null_output = Posix.open("/dev/null", Posix.O_WRONLY);
            if (null_output < 0) {
                Posix.close(Posix.STDOUT_FILENO);
                return;
            }
            Posix.dup2(null_output, Posix.STDOUT_FILENO);
            Posix.close(null_output);
        }

        private static string ? read_standard_input() {
            var text = new MemoryOutputStream.resizable();
            try {
                text.splice(new UnixInputStream(Posix.STDIN_FILENO, true), OutputStreamSpliceFlags.CLOSE_SOURCE);
                text.write({ 0 });
                text.close();
            } catch (IOError e) {
                return null;
            }
            return (string) text.get_data();
        }

        private static Gtk.TargetEntry[] text_targets() {
            var targets = new Gtk.TargetList(null);
            targets.add_text_targets(0);
            return Gtk.target_table_new_from_list(targets);
        }

        private static void get_clipboard_text(Gtk.Clipboard clipboard, Gtk.SelectionData selection_data, uint info, void* owner) {
            selection_data.set_text(((CopiedText) owner).text, -1);
        }

        // Another copy took the clipboard over
        private static void clear_owned_copy(Gtk.Clipboard clipboard, void* owner) {
            if (owner == (void*) owned_copy)
                owned_copy = null;
        }
    }
}
