unit_test_files = [
    'Util',
    'CalculatorParser'
]

foreach name : unit_test_files
    test(name, executable(name, name + 'Test.vala', ilia_sources, dependencies: ilia_deps))
endforeach
