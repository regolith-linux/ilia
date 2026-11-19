namespace Ilia {
    /**
     * The surroundings that programs started from the window run in.
     *
     * A window shown by the process that was started for it uses that process's own
     * environment and working directory. A window shown by the background copy belongs
     * to another process, the one that made the call: while it is showing, its
     * environment is set here, and the pages take PATH, the scope runner and the
     * environment of the programs they start from it. The working directory is the
     * caller's too, as the background copy changes into it for the call.
     */
    public class CallerEnvironment {
        // The environment of the calling process, or null for the process's own
        private static string[] ? caller_environ = null;

        public static void set_environ(string[] ? environ) {
            caller_environ = environ;
        }

        /**
         * The environment for a program that is started, or null for the process's own
         * (the default when spawning)
         */
        public static string[] ? get_environ() {
            return caller_environ;
        }

        public static string ? get_variable(string name) {
            if (caller_environ == null)
                return Environment.get_variable(name);
            return Environ.get_variable(caller_environ, name);
        }

        /**
         * The full path of a program found in the caller's PATH, as find_program_in_path() does
         * for the process's own PATH; null if it is not there
         */
        public static string ? find_program(string program) {
            if (caller_environ == null)
                return Environment.find_program_in_path(program);
            if (Path.is_absolute(program))
                return FileUtils.test(program, FileTest.IS_EXECUTABLE) && !FileUtils.test(program, FileTest.IS_DIR) ? program : null;

            string path_var = get_variable("PATH") ?? "/bin:/usr/bin:.";
            foreach (unowned string dir in path_var.split(":")) {
                // An empty entry stands for the working directory
                string candidate = Path.build_filename(dir == "" ? "." : dir, program);
                if (FileUtils.test(candidate, FileTest.IS_EXECUTABLE) && !FileUtils.test(candidate, FileTest.IS_DIR))
                    return Path.is_absolute(candidate) ? candidate : Path.build_filename(Environment.get_current_dir(), candidate);
            }
            return null;
        }

        /**
         * Flags for Process.spawn_async() with get_environ(): look the program up in the PATH
         * of the environment it is started with
         */
        public static SpawnFlags search_path_flags() {
            return caller_environ == null ? SpawnFlags.SEARCH_PATH : SpawnFlags.SEARCH_PATH | SpawnFlags.SEARCH_PATH_FROM_ENVP;
        }

        /**
         * A launch context giving programs started through GIO the caller's environment, or
         * null to use the process's own
         */
        public static AppLaunchContext ? create_launch_context() {
            if (caller_environ == null)
                return null;

            var context = new AppLaunchContext();
            foreach (unowned string variable in context.get_environment()) {
                string name = variable.split("=", 2)[0];
                if (Environ.get_variable(caller_environ, name) == null)
                    context.unsetenv(name);
            }
            foreach (unowned string variable in caller_environ) {
                string[] parts = variable.split("=", 2);
                if (parts.length == 2)
                    context.setenv(parts[0], parts[1]);
            }
            return context;
        }
    }
}
