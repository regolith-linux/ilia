namespace Ilia {
    /**
     * Tells when what is at a set of paths may have changed
     *
     * Each directory a path goes through, following symbolic links as add_path_dependencies()
     * does, is watched for the entry that leads on to the path. changed() is emitted when one
     * of those entries is created, removed, renamed onto or away, or changes attributes (as
     * permissions), or a directory on the way does; changes to file contents and to other
     * entries are ignored, and while nothing changes nothing is done. Changes that come
     * together are reported once. Where a directory cannot be watched, changed() is emitted
     * periodically instead, for as long as that lasts.
     *
     * The watches stay until watch() is given other paths or stop() is called.
     */
    public class PathWatcher : Object {
        // Report changes this long after the first one, together with any that follow: a link
        // replaced by renaming or a file written and then made executable is one change
        private const uint SETTLE_MILLISECONDS = 100;
        // How often changed() is emitted while a directory cannot be watched
        private const uint UNWATCHED_INTERVAL_MILLISECONDS = 1000;

        // Something at the paths may be different
        public signal void changed();

        private class DirectoryWatch {
            public File directory;
            public FileMonitor monitor;
            // The entries that lead on to the paths
            public GenericSet<string> names;
            // The directory watched, to notice when another one is put at its path
            public string identity;
        }

        // The watched directories by path
        private HashTable<string, DirectoryWatch> watches = new HashTable<string, DirectoryWatch>(str_hash, str_equal);
        private uint settle_source = 0;
        private uint unwatched_source = 0;

        /**
         * Watch for changes to the files at paths, in place of the paths watched before
         *
         * Called again after a change, the watches follow links that now lead elsewhere.
         */
        public void watch(string[] paths) {
            var wanted = new HashTable<string, GenericSet<string> >(str_hash, str_equal);
            foreach (unowned string path in paths)
                add_path_dependencies(path, wanted);

            // Keep the watches still needed on the same directories
            watches.foreach_remove((path, watch) => {
                if (wanted.contains(path) && directory_identity(watch.directory) == watch.identity)
                    return false;
                watch.monitor.cancel();
                return true;
            });

            bool all_watched = true;
            wanted.foreach((path, names) => {
                var watch = watches.lookup(path);
                if (watch == null) {
                    // Watching needs read access: a directory that can only be passed through
                    // is checked periodically instead, and one that cannot be passed through
                    // hides what is in it, while its own changes show in its parent
                    if (Posix.access(path, Posix.R_OK) != 0) {
                        if (Posix.access(path, Posix.X_OK) == 0)
                            all_watched = false;
                        return;
                    }
                    watch = start_watch(path);
                    if (watch == null) {
                        all_watched = false;
                        return;
                    }
                    watches.insert(path, watch);
                }
                watch.names = names;
            });
            set_unwatched_checks(!all_watched);
        }

        // Stop watching, without reporting changes still pending
        public void stop() {
            watches.foreach((path, watch) => watch.monitor.cancel());
            watches.remove_all();
            if (settle_source != 0) {
                Source.remove(settle_source);
                settle_source = 0;
            }
            set_unwatched_checks(false);
        }

        private DirectoryWatch ? start_watch(string path) {
            var watch = new DirectoryWatch();
            watch.directory = File.new_for_path(path);
            watch.identity = directory_identity(watch.directory);
            try {
                watch.monitor = watch.directory.monitor_directory(FileMonitorFlags.WATCH_MOVES);
            } catch (Error e) {
                debug("Cannot watch %s: %s", path, e.message);
                return null;
            }
            watch.monitor.changed.connect(on_directory_changed);
            return watch;
        }

        // The device and inode of a directory, empty if it cannot be read
        private static string directory_identity(File directory) {
            try {
                var info = directory.query_info(FileAttribute.UNIX_DEVICE + "," + FileAttribute.UNIX_INODE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                return info.get_attribute_as_string(FileAttribute.UNIX_DEVICE) + ":" + info.get_attribute_as_string(FileAttribute.UNIX_INODE);
            } catch (Error e) {
                return "";
            }
        }

        private void on_directory_changed(File file, File ? other_file, FileMonitorEvent event) {
            // What the paths lead to does not depend on what files hold
            if (event == FileMonitorEvent.CHANGED || event == FileMonitorEvent.CHANGES_DONE_HINT)
                return;
            if (is_watched_entry(file) || (other_file != null && is_watched_entry(other_file)))
                report_change();
        }

        // Whether file is a watched directory or an entry leading on to a path
        private bool is_watched_entry(File file) {
            string ? path = file.get_path();
            if (path == null)
                return false;
            if (watches.contains(path))
                return true;
            var watch = watches.lookup(Path.get_dirname(path));
            return watch != null && watch.names.contains(Path.get_basename(path));
        }

        private void report_change() {
            if (settle_source != 0)
                return;
            settle_source = Timeout.add(SETTLE_MILLISECONDS, () => {
                settle_source = 0;
                changed();
                return Source.REMOVE;
            });
        }

        private void set_unwatched_checks(bool needed) {
            if (needed && unwatched_source == 0) {
                unwatched_source = Timeout.add(UNWATCHED_INTERVAL_MILLISECONDS, () => {
                    changed();
                    return Source.CONTINUE;
                });
            } else if (!needed && unwatched_source != 0) {
                Source.remove(unwatched_source);
                unwatched_source = 0;
            }
        }
    }
}
