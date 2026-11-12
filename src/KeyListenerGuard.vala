using AtkUtilClassBinding;

namespace Ilia {
    /**
     * Works around a GTK 3 crash when an AT-SPI client goes away during a key press
     *
     * GTK calls the ATK key event listeners before it handles a key event. The AT-SPI
     * bridge's listener sends the key to the registry and waits for the reply in a nested
     * main loop. If the last AT-SPI client (a screen reader, an accessibility tool) leaves
     * meanwhile, the bridge removes its key listener from inside that loop. GTK 3.24.52
     * and older then read the next pointer of the freed list node and crash (SIGSEGV in
     * _gtk_accessibility_key_snooper(), gtkaccessibilityutil.c:154).
     *
     * GTK fixed it on the gtk-3-24 branch after 3.24.52:
     * https://gitlab.gnome.org/GNOME/gtk/-/commit/e6372d2923d04bb2bdc88fa526ca57704ca2664a
     * ("a11y: Browse key listener list safely"). Remove this file, the vapi and the call
     * in Application.activate() once the distributions ilia targets ship a GTK with it.
     *
     * While GTK handles a key event, removing a key listener is put off until GTK is done.
     */
    namespace KeyListenerGuard {
        private bool installed;
        private RemoveKeyListenerFunc gtk_remove_key_listener;
        private int key_event_depth;
        // Listeners to remove once the key event is handled
        private uint[] removals;

        /**
         * Call once after GTK is initialized
         */
        public void install() {
            if (installed) return;
            installed = true;

            // GTK set the class's key listener functions when it initialized accessibility
            UtilClass* util_class = (UtilClass*) typeof (Atk.Util).class_peek();
            if (util_class == null || util_class->remove_key_event_listener == null) return;

            gtk_remove_key_listener = util_class->remove_key_event_listener;
            util_class->remove_key_event_listener = remove_key_listener;
            // Replaces GTK's handler, gtk_main_do_event(), which handle_event() calls
            Gdk.Event.handler_set(handle_event);
        }

        private void remove_key_listener(uint listener_id) {
            if (key_event_depth > 0)
                removals += listener_id;
            else
                gtk_remove_key_listener(listener_id);
        }

        private void handle_event(Gdk.Event event) {
            bool is_key = event.type == Gdk.EventType.KEY_PRESS || event.type == Gdk.EventType.KEY_RELEASE;

            if (is_key) key_event_depth++;
            Gtk.main_do_event(event);
            if (!is_key) return;

            key_event_depth--;
            while (key_event_depth == 0 && removals.length > 0) {
                uint listener_id = removals[removals.length - 1];
                removals.resize(removals.length - 1);
                gtk_remove_key_listener(listener_id);
            }
        }
    }
}
