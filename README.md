# Ilia - A Desktop Executor

Ilia provides a modal interface prompting the user to select an item from a list. There are various items or pages that can be selected from by specifying the desired page via a command-line parameter. Also, all pages can be loaded together in "all page" mode.

## Status

Ilia is in active development and should be considered `beta` quality.

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

## Dependencies

### Notifications

This page communicates with the [Rofication](https://github.com/regolith-linux/regolith-rofication) daemon for managing desktop notifications.

### Keybindings

This page uses the comment format specified by [Remontoire](https://github.com/regolith-linux/remontoire) and reads the i3 config via it's local socket.

## Build

Ilia uses `meson` and `ninja` to build.  Example:

```
$ git clone https://github.com/regolith-linux/ilia.git
$ mkdir ilia/build
$ cd ilia/build
$ meson ..
$ ninja
$ src/ilia
```

## Package

Debian packages for Debian and Ubuntu are available in the [Regolith 2 package repository](https://github.com/regolith-linux/voulage).
