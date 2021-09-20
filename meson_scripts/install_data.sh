#!/bin/bash

shopt -s extglob
mkdir -p $DESTDIR/$1
if [ -d "$2" ]; then
	cp -a $2/!(CMakeLists.txt) $DESTDIR/$1
else
	cp -a $2 $DESTDIR/$1
fi
