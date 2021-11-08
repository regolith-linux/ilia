# Ilia - A Desktop Executor

Ilia provides a modal interface prompting the user to select an item from a list.

## Status

Ilia is in active development and should be considered unstable and pre-alpha quality.

## Features

Ilia provides pages to view and select from the following types of things:
* Desktop Apps (`apps`)
* System Commands (`terminal`)
* Desktop Keybindings (`keybindings`)
* Notifications (`notifications`)

## Usage

Ilia can be launched from a terminal. The `-p` option allows to specify which page to present to the user.

Ex:
```
ilia -p keybindings
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

Debian packages for Debian and Ubuntu are available in the [Regolith 2 package repository](https://github.com/regolith-linux/package-repo).
