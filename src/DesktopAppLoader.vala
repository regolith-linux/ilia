using Gee;

namespace Ilia {
    class DesktopAppLoader: GLib.Object {

        Gtk.ListStore model;

        public DesktopAppLoader (Gtk.ListStore listStore) {
            model = listStore;
        }

        public async void init () {
            var dir = File.new_for_path ("/usr/share/applications/");
            try {
                var enumerator = yield dir.enumerate_children_async (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT);

                while (true) {
                    // asynchronous call, to get entries so far
                    var files = yield enumerator.next_files_async (10, Priority.DEFAULT);

                    if (files == null) {
                        break;
                    }
                    // append the files found so far to the list
                    foreach (var info in files) {
                        read_desktop_file ("/usr/share/applications/" + info.get_name ());
                    }
                }
            } catch (Error err) {
                stderr.printf ("Error: list_files failed: %s\n", err.message);
            }
        }

        private void read_desktop_file (string desktopPath) {
            DesktopAppInfo appInfo = new DesktopAppInfo.from_filename (desktopPath);
            if (appInfo != null) {
                model.append (out iter);
                model.set (iter, 0, null, 1, appInfo.get_name (), 2, "comment", 3, "exec");
            }
        }
    }
}