namespace Ilia {
    // Represents actions and state that DialogPage types may access from the active session.
    public interface SessionContoller : GLib.Object {
        //FIXME: this should be renamed to make it clear that this just loads a spinner
        public abstract void launched ();
        
        // Exit the app
        public abstract void quit ();
    }
}