# Ilia - A Desktop Executor

Ilia is a tool for users to invoke actions such as launching apps, viewing notifications, and finding windows.  It provides a modal interface consisting of a filter box, and a list of matching items. There are a set pages that can be selected from by specifying the desired page via a command-line parameter or by tab if all pages are loaded (controlled by command-line parameter).

![Ilia Screenshot](https://regolith-desktop.com/regolith-ilia-keybinding-window.png)

## Features

Ilia provides pages to view and select from the following types of things:
* Desktop Apps (`apps`)
* System Commands (`terminal`)
* Desktop Keybindings (`keybindings`)
* Notifications (`notifications`)
* Text List (`textlist`)
* File Search (`tracker`)
* Open Windows (`windows`)

## Usage

Ilia can be launched from a terminal. The `-p` option allows to specify which page to present to the user.

Ex:
```
ilia -p keybindings
```

### Desktop Apps

Ilia searches the system-configured `$XDG_DATA_DIRS` with `applications` applied at the end of each path for desktop application files.  For example, if your system has `$HOME/.local/share` in the set of paths in `$XDG_DATA_DIRS`, the path `$HOME/.local/share/applications/` will be searched for destkopt app files.

### Text List

The `textlist` page is a bit different than the others pages.  It provides a general purpose utility to provide a list of options for the user select and when the selection occurs, the selected item is returned by the invocation to `ilia`.  In this way the program can be used in scripts to get user input from dynamic data, similar to `rofi`.  The `textlist` page supports two additional parameters for more customization:

```
'textlist' - select an item from a specified list
        -l: page label
        -i: page icon
```

## Configuration

Ilia supports the following configuration via gsettings under the namespace `org.regolith-linux.ilia`:

* window-width: width of window in pixels
* window-height: height of window in pixels
* icon-size: size of icons in pixels or 0 to disable icons

### Example: Resetting screen width

```
gsettings reset org.regolith-linux.ilia window-width
```

## Dependencies

### Notifications

This page communicates with the [Rofication](https://github.com/regolith-linux/regolith-rofication) daemon for managing desktop notifications.

### Keybindings

This page uses the comment format specified by [Remontoire](https://github.com/regolith-linux/remontoire) and reads the i3 config via it's local socket.

## Build

Ilia uses `meson` and `ninja` to build.  Example:

```shell
git clone https://github.com/regolith-linux/ilia.git
mkdir ilia/build
cd ilia/build
meson ..
ninja
src/ilia
```

## Lint

In a build dir run this to execute `uncrustify`:

    ninja fixstyle

## Test

Run the unit tests in a build dir with:

    ninja test

For manual testing, it is useful to run with throttled CPU in debug mode, run ilia like this:

    systemd-run --pipe --user --property=CPUQuota=10% --property=MemoryLimit=100M --property=MemorySwapMax=0 --property=RuntimeMaxSec=30 --collect --wait -E G_MESSAGES_DEBUG=all build/src/ilia -p apps

Otherwise, you won't be able to see the effects of any async issues, which only reveal themselves under heavy load.

You can always run `ilia` in debug mode by editing `~/.config/regolith3/Xresources`

    # In ~/.config/regolith3/Xresources
    # Make this file if it doesn't exist.
    # Use MOD + shift + r to reload Regolith to pick up the change
    wm.program.launcher.app: G_MESSAGES_DEBUG=all ilia -p apps

And then use:

    journalctl --user --follow | grep ilia

To see any debug messages from your session.

## Package

Debian packages for Debian and Ubuntu are available in the [Regolith package repository](https://github.com/regolith-linux/voulage).
