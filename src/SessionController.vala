namespace Ilia {
    // Represents actions and state that DialogPage types may access from the active session.
    public interface SessionContoller : GLib.Object {
        
        // Exit the app
        public abstract void quit ();
    }
}