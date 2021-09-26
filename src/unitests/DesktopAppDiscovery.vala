
namespace Ilia {
    void test_load_apps () {
        DesktopAppInfo unit = new DesktopAppInfo.from_filename ("/usr/share/applications/org.regolith-linux.remontoire.desktop");

        stdout.printf ("%s\n", unit.get_name ());

        assert (unit != null);
    }

    void test_desktop_app_loader () {
        Gtk.ListStore listStore = new Gtk.ListStore (4, typeof (Gdk.Pixbuf), typeof (string), typeof (string), typeof (string));
        Ilia.DesktopAppLoader unit = new Ilia.DesktopAppLoader (listStore);
        unit.init ();

        assert (listStore.iter_has_child (iter));
    }

    // Test Harness

    public static int main (string[] args) {
        Test.init (ref args);

        Test.add_func ("/autovala/DesktopAppDiscovery", test_load_apps);
        Test.add_func ("/autovala/DesktopAppDiscovery2", test_desktop_app_loader);

        Test.run ();
        return 0;
    }
}