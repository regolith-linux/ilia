#!/bin/bash

if [[ -z "${DESTDIR}" ]]; then
    echo Compiling gsettings schemas...
	glib-compile-schemas ${MESON_INSTALL_PREFIX}/share/glib-2.0/schemas
fi
