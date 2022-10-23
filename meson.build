project('ilia',
  ['c','vala'],
  version: '0.12.20')

add_global_arguments('-DGETTEXT_PACKAGE="ilia"',language: 'c')

find_program ('glib-compile-schemas')
gio_unix_2_0_dep = dependency('gio-unix-2.0')
json_glib_1_0_dep = dependency('json-glib-1.0')
tracker_sparql_2_0_dep = dependency('tracker-sparql-2.0')
atk_dep = dependency('atk')
cairo_gobject_dep = dependency('cairo-gobject')
gdk_3_0_dep = dependency('gdk-3.0')
gdk_pixbuf_2_0_dep = dependency('gdk-pixbuf-2.0')
gee_0_8_dep = dependency('gee-0.8')
gio_2_0_dep = dependency('gio-2.0')
glib_2_0_dep = dependency('glib-2.0')
gobject_2_0_dep = dependency('gobject-2.0')
gtk_3_0_dep = dependency('gtk+-3.0')
pango_dep = dependency('pango')
x11_dep = dependency('x11')

meson.add_install_script(join_paths(meson.current_source_dir(),'meson_scripts','install_data.sh'),join_paths(get_option('prefix'),get_option('datadir'),'ilia'),join_paths(meson.current_source_dir(),'data/local','','*'))

meson.add_install_script(join_paths(meson.current_source_dir(),'meson_scripts','install_data.sh'),join_paths(get_option('prefix'),get_option('datadir'),'doc','ilia'),join_paths(meson.current_source_dir(),'doc','','*'))

install_data('data/org.regolith-linux.ilia.gschema.xml', install_dir: join_paths(get_option('prefix'),get_option('datadir'), 'glib-2.0', 'schemas'))
meson.add_install_script('meson_scripts/install_schemas.sh')
subdir('src')
