namespace Ilia {
    /**
     * Reads lines from a stream asynchronously, in batches
     *
     * Lines end at '\n', which is removed; a last line without '\n' is kept, as
     * FileStream.read_line() does.
     */
    public class LineReader : GLib.Object {
        public signal void lines_read(string[] lines);
        public signal void finished();

        public bool done { get; private set; default = false; }

        private InputStream stream;
        private size_t chunk_size;
        private ByteArray incomplete = new ByteArray();
        private static uint8[] NUL = { 0 };

        public LineReader (InputStream stream, size_t chunk_size = 64 * 1024) {
            this.stream = stream;
            this.chunk_size = chunk_size;
        }

        public async void read_all() {
            try {
                while (true) {
                    var bytes = yield stream.read_bytes_async(chunk_size, Priority.DEFAULT, null);

                    if (bytes.get_size() == 0) break;
                    split(bytes.get_data());
                }
            } catch (GLib.Error e) {
                stderr.printf("Error reading input: %s\n", e.message);
            }

            if (incomplete.len > 0) {
                incomplete.append(NUL);
                string[] last = { (string) incomplete.data };
                lines_read(last);
            }
            done = true;
            finished();
        }

        private void split(uint8[] data) {
            string[] lines = {};
            int start = 0;

            for (int i = 0; i < data.length; ++i) {
                if (data[i] != '\n') continue;

                incomplete.append(data[start: i]);
                incomplete.append(NUL);
                lines += (string) incomplete.data;
                incomplete.set_size(0);
                start = i + 1;
            }
            incomplete.append(data[start: data.length]);

            if (lines.length > 0)
                lines_read(lines);
        }
    }

    /**
     * Filters a large, growing list of lines without blocking the UI (ilia#32)
     *
     * Filtering is done in slices of at most budget rows per step(), so the caller can run
     * it from an idle handler and keep handling input between slices. A new query starts
     * over and drops the unfinished work for the previous one; when the new query only
     * narrows the previous one (typing more of a word), just the rows that matched before
     * are checked again. Lines added while filtering are checked too.
     *
     * The visible rows (indices into the lines, in input order) change in two ways:
     * replaced, when filtering for a query completes (signal reset), or extended at the
     * end, when added lines match the current query (signal appended).
     */
    public class TextFilter : GLib.Object {
        public signal void reset();
        public signal void appended(int first, int count);

        // All lines, and the same lowered for matching
        private string[] lines = {};
        private string[] lowered = {};
        private int n_lines = 0;

        // Words of the current query; rows [0, filtered_upto) were checked against them
        private string[] words = {};
        private int[] visible = {};
        private int n_visible = 0;
        private int filtered_upto = 0;

        // Filtering for a new query; when done its result replaces visible
        private bool job_active = false;
        private string[] job_words = {};
        private int[] job_candidates = {};   // rows to check first (rows that matched the narrower query)
        private int job_candidates_len = 0;
        private int job_candidate_pos = 0;
        private int job_scan_from = 0;       // then rows from here to the end
        private int[] job_visible = {};
        private int job_n_visible = 0;

        // Rows checked against a query since creation; lets tests bound the work per step
        public uint64 rows_checked { get; private set; default = 0; }

        public int line_count {
            get {
                return n_lines;
            }
        }

        public int visible_count {
            get {
                return n_visible;
            }
        }

        public string get_visible_line(int position) {
            return lines[visible[position]];
        }

        /**
         * True while rows are left to check: call step() until it returns false
         */
        public bool busy {
            get {
                return job_active || filtered_upto < n_lines;
            }
        }

        public void add_lines(string[] batch) {
            foreach (unowned string line in batch) {
                if (n_lines == lines.length) {
                    lines.resize(int.max(1024, lines.length * 2));
                    lowered.resize(lines.length);
                }
                lines[n_lines] = line;
                lowered[n_lines] = line.down();
                n_lines++;
            }
        }

        public void set_query(string query) {
            var new_words = query_words(query);

            // visible holds every match for words among rows [0, filtered_upto), also while a job runs
            bool narrows = refines(words, new_words);

            job_active = true;
            job_words = new_words;
            job_visible = new int[narrows ? n_visible : 1024];
            job_n_visible = 0;
            if (narrows) {
                job_candidates = visible[0 : n_visible];
                job_candidates_len = n_visible;
                job_scan_from = filtered_upto;
            } else {
                job_candidates = {};
                job_candidates_len = 0;
                job_scan_from = 0;
            }
            job_candidate_pos = 0;
        }

        /**
         * Check at most budget rows
         *
         * @return true if work is left
         */
        public bool step(int budget) {
            if (job_active) {
                while (budget > 0 && job_candidate_pos < job_candidates_len) {
                    check_job_row(job_candidates[job_candidate_pos++]);
                    budget--;
                }
                while (budget > 0 && job_scan_from < n_lines) {
                    check_job_row(job_scan_from++);
                    budget--;
                }
                if (job_candidate_pos >= job_candidates_len && job_scan_from >= n_lines) {
                    words = job_words;
                    visible = (owned) job_visible;
                    n_visible = job_n_visible;
                    filtered_upto = n_lines;
                    job_active = false;
                    job_candidates = {};
                    job_visible = {};
                    reset();
                }
                return busy;
            }

            int first = n_visible;
            while (budget > 0 && filtered_upto < n_lines) {
                int row = filtered_upto++;
                rows_checked++;
                if (contains_all_words(lowered[row], words)) {
                    if (n_visible == visible.length)
                        visible.resize(int.max(1024, visible.length * 2));
                    visible[n_visible++] = row;
                }
                budget--;
            }
            if (n_visible > first)
                appended(first, n_visible - first);

            return busy;
        }

        /**
         * Do all remaining work now
         */
        public void finish() {
            while (step(int.MAX)) {
            }
        }

        private void check_job_row(int row) {
            rows_checked++;
            if (contains_all_words(lowered[row], job_words)) {
                if (job_n_visible == job_visible.length)
                    job_visible.resize(int.max(1024, job_visible.length * 2));
                job_visible[job_n_visible++] = row;
            }
        }

        // Every row matching new_words also matches old_words when each old word is part of a new word
        private static bool refines(string[] old_words, string[] new_words) {
            foreach (unowned string old_word in old_words) {
                bool found = false;
                foreach (unowned string new_word in new_words) {
                    if (new_word.contains(old_word)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }
    }

    /**
     * A list model over the visible rows of a TextFilter
     *
     * Unlike a Gtk.TreeModelFilter it does not re-check every row on a new query: the
     * filter works in slices, and the view is given the finished result in one go.
     */
    public class FilteredLinesModel : GLib.Object, Gtk.TreeModel {
        private TextFilter filter;
        private Gdk.Pixbuf ? icon;
        private bool with_icon;
        private int stamp = (int) Random.next_int();

        /**
         * @param with_icon If true column 0 is the icon and column 1 the line, else column 0 is the line
         */
        public FilteredLinesModel (TextFilter filter, bool with_icon, Gdk.Pixbuf ? icon) {
            this.filter = filter;
            this.with_icon = with_icon;
            this.icon = icon;
        }

        // Call after the filter's visible rows were replaced, while no view uses this model
        public void invalidate_iters() {
            stamp++;
        }

        public Gtk.TreeModelFlags get_flags() {
            return Gtk.TreeModelFlags.LIST_ONLY;
        }

        public int get_n_columns() {
            return with_icon ? 2 : 1;
        }

        public Type get_column_type(int index) {
            return with_icon && index == 0 ? typeof (Gdk.Pixbuf) : typeof (string);
        }

        private bool make_iter(out Gtk.TreeIter iter, int position) {
            iter = Gtk.TreeIter();
            if (position < 0 || position >= filter.visible_count) return false;
            iter.stamp = stamp;
            iter.user_data = (void *) (long) position;
            return true;
        }

        private int position_of(Gtk.TreeIter iter) {
            return iter.stamp == stamp ? (int) (long) iter.user_data : -1;
        }

        public bool get_iter(out Gtk.TreeIter iter, Gtk.TreePath path) {
            var indices = path.get_indices();
            if (path.get_depth() != 1) {
                iter = Gtk.TreeIter();
                return false;
            }
            return make_iter(out iter, indices[0]);
        }

        public Gtk.TreePath ? get_path(Gtk.TreeIter iter) {
            int position = position_of(iter);
            if (position < 0 || position >= filter.visible_count) return null;
            return new Gtk.TreePath.from_indices(position);
        }

        public void get_value(Gtk.TreeIter iter, int column, out Value value) {
            int position = position_of(iter);
            if (with_icon && column == 0) {
                value = Value(typeof (Gdk.Pixbuf));
                value.set_object(icon);
            } else {
                value = Value(typeof (string));
                if (position >= 0 && position < filter.visible_count)
                    value.set_string(filter.get_visible_line(position));
            }
        }

        public bool iter_next(ref Gtk.TreeIter iter) {
            int position = position_of(iter);
            if (position < 0) return false;
            return make_iter(out iter, position + 1);
        }

        public bool iter_previous(ref Gtk.TreeIter iter) {
            int position = position_of(iter);
            if (position < 1) return false;
            return make_iter(out iter, position - 1);
        }

        public bool iter_children(out Gtk.TreeIter iter, Gtk.TreeIter ? parent) {
            if (parent != null) {
                iter = Gtk.TreeIter();
                return false;
            }
            return make_iter(out iter, 0);
        }

        public bool iter_has_child(Gtk.TreeIter iter) {
            return false;
        }

        public int iter_n_children(Gtk.TreeIter ? iter) {
            return iter == null ? filter.visible_count : 0;
        }

        public bool iter_nth_child(out Gtk.TreeIter iter, Gtk.TreeIter ? parent, int n) {
            if (parent != null) {
                iter = Gtk.TreeIter();
                return false;
            }
            return make_iter(out iter, n);
        }

        public bool iter_parent(out Gtk.TreeIter iter, Gtk.TreeIter child) {
            iter = Gtk.TreeIter();
            return false;
        }

        // Tell the view about rows the filter appended at the end
        public void rows_appended(int first, int count) {
            for (int position = first; position < first + count; ++position) {
                Gtk.TreeIter iter;
                make_iter(out iter, position);
                row_inserted(new Gtk.TreePath.from_indices(position), iter);
            }
        }
    }
}
