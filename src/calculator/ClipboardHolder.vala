namespace Ilia {
    /**
     * Keeps a value on the clipboard after the dialog has closed.
     *
     * The clipboard is served by the program that owns it. When a clipboard manager that saves
     * the clipboard of programs that exit is running (X11 only), the value is handed to it and
     * the application exits as usual. Otherwise the application keeps running while it holds
     * the value, and finishes once something else is put on the clipboard. A later launch
     * takes over as the application meanwhile (see Application.name_lost).
     */
    class ClipboardHolder : GLib.Object {
        private static ClipboardHolder ? instance = null;

        private string text = "";
        private bool holding = false;

        public static void hold(Gdk.Display display, string text) {
            if (instance == null)
                instance = new ClipboardHolder();
            instance.take(display, text);
        }

        // True while the application keeps running to serve a value
        public static bool is_holding() {
            return instance != null && instance.holding;
        }

        private void take(Gdk.Display display, string text) {
            this.text = text;

            var targets = new Gtk.TargetList(null);
            targets.add_text_targets(0);
            var clipboard = Gtk.Clipboard.get_for_display(display, Gdk.SELECTION_CLIPBOARD);
            // With this object as the owner, holding a new value does not count as losing the old one
            if (!clipboard.set_with_owner(Gtk.target_table_new_from_list(targets), get_text, clear_text, this)) {
                stderr.printf("Cannot put the value on the clipboard\n");
                return;
            }

            if (display.supports_clipboard_persistence()) {
                clipboard.set_can_store(null);
                clipboard.store();
                return;
            }

            if (!holding) {
                holding = true;
                GLib.Application.get_default().hold();
            }
        }

        private static void get_text(Gtk.Clipboard clipboard, Gtk.SelectionData selection_data, uint info, void * owner) {
            selection_data.set_text(((ClipboardHolder) owner).text, -1);
        }

        // Something else was put on the clipboard
        private static void clear_text(Gtk.Clipboard clipboard, void * owner) {
            var holder = (ClipboardHolder) owner;
            if (!holder.holding)
                return;
            holder.holding = false;
            GLib.Application.get_default().release();
        }
    }
}
