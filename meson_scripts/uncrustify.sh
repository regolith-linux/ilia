#!/bin/bash

uncrustify -c $MESON_SOURCE_ROOT/uncrustify.cfg --no-backup --replace $(find $MESON_SOURCE_ROOT/src/ -name \*.vala)