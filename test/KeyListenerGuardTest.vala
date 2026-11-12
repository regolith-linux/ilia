// The AT-SPI bridge removes its ATK key listener from inside that listener when the last
// AT-SPI client goes away during a key press; GTK 3.24.52 and older then crash (SIGSEGV in
// _gtk_accessibility_key_snooper()). Without KeyListenerGuard this test crashes there; with a
// GTK that has e6372d29 it passes either way. Needs a display; skipped without one.

uint self_removing_id = 0;
int self_removing_calls = 0;
int other_calls = 0;

void send_key(Gtk.Window window, uint keyval) {
    var event = new Gdk.Event(Gdk.EventType.KEY_PRESS);
    event.key.window = window.get_window();
    event.key.window.ref(); // the event owns a reference
    event.key.keyval = keyval;
    event.key.time = Gdk.CURRENT_TIME;
    event.set_device(window.get_display().get_default_seat().get_keyboard());
    event.put();

    var context = MainContext.default();
    while (context.pending())
        context.iteration(false);
}

void test_listener_removed_during_key_event() {
    var window = new Gtk.Window();
    window.show();

    // Like the bridge when a client leaves while it waits for the registry's reply
    self_removing_id = Atk.Util.add_key_event_listener((event) => {
        self_removing_calls++;
        Atk.Util.remove_key_event_listener(self_removing_id);
        return 0;
    });
    Atk.Util.add_key_event_listener((event) => {
        other_calls++;
        return 0;
    });

    send_key(window, Gdk.Key.a);
    assert (self_removing_calls == 1 && other_calls == 1);

    // The removal happened once the event was handled
    send_key(window, Gdk.Key.b);
    assert (self_removing_calls == 1 && other_calls == 2);

    window.destroy();
}

public int main(string[] args) {
    Test.init(ref args);

    // GTK's key listener list is used without the AT-SPI bridge too; the bridge would warn without an AT-SPI bus
    Environment.set_variable("NO_AT_BRIDGE", "1", true);
    if (!Gtk.init_check(ref args)) {
        Test.message("no display: skipped");
        return 77;
    }
    Ilia.KeyListenerGuard.install();

    Test.add_func("/keylistenerguard/listener_removed_during_key_event", test_listener_removed_during_key_event);

    return Test.run();
}
