unit_test_files = [
    'Util',
    'I3Ipc',
    'Launch',
    'Rofication',
    'TextFilter'
]

foreach name : unit_test_files
    test(name, executable(name, name + 'Test.vala', ilia_sources, dependencies: ilia_deps))
endforeach