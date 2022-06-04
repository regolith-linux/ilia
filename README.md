# Ilia - A Desktop Executor

Ilia provides a modal interface prompting the user to select an item from a list. There are various items or pages that can be selected from by specifying the desired page via a command-line parameter. Also, all pages can be loaded together in "all page" mode.

![Ilia Screenshot](https://regolith-desktop.com/regolith-ilia-keybinding-window.png)

## Status

Ilia is in active development and should be considered `beta` quality.

## Features

Ilia provides pages to view and select from the following types of things:

### Desktop Apps (`apps`)

Loads and presents all desktop applications specified in the [XDG desktop entry format](https://specifications.freedesktop.org/desktop-entry-spec/desktop-entry-spec-latest.html) found in directories specified in the `XDG_DATA_DIRS` environment variable.

### System Commands (`terminal`)

Loads all system commands available on the path.  Selecting a command will cause it to be executed from a newly created terminal.

### Desktop Keybindings (`keybindings`)

Loads all i3 keybindings from the running i3 window manager.  Selecting a keybinding will cause the keybinding to be executed in some cases.

### Notifications (`notifications`)

Loads all notifications from the rofication daemon.

### Text List (`textlist`)

Loads items specified on the command-line.  The selected item is returned from the command.  For example, to see and select from a list of all files in a directory:

```shell
$ ls | ilia -p textlist
```

### Windows (`windows`)

Loads all active windows.  The window selected will be navigated to.

### Files (`tracker`)

Provides a basic front-end to [GNOME Tracker](https://wiki.gnome.org/Projects/Tracker) to search for files with specific content.  Selecting a file will cause it to be loaded with it's default application.

## Usage

Ilia can be launched from a terminal. The `-p` option allows to specify which page to present to the user.

Ex:
```shell
ilia -p keybindings
```

The `-a` option loads all general purpose pages together.

### Text List

The `textlist` page is a bit different than the others pages.  It provides a general purpose utility to provide a list of options for the user select and when the selection occurs, the selected item is returned by the invocation to `ilia`.  In this way the program can be used in scripts to get user input from dynamic data, similar to `rofi`.  The `textlist` page supports two additional parameters for more customization:

```shell
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

```shell
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

Note: the `main` branch builds on Ubuntu Focal and Debian Bullseye, and the `ubuntu/jammy` branch builds on Ubuntu Jammy.

## Package

Debian packages for Debian and Ubuntu are available in the [Regolith 2 package repository](https://github.com/regolith-linux/voulage).

## Inspiration

`ilia`'s design is inspired by the wonderful desktop launcher [`rofi`](https://github.com/davatorium/rofi).