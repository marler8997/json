
REM Build Json Parser from S-Ludwig
REM Use dub in ..\std_data_json
@echo on
dmd -ofperfOneAtATime   -O -release -inline -boundscheck=off -I..\std_data_json\source performance.d json.d ..\std_data_json\std_data_json.lib -version=OneParseJsonAtATime

@echo off
if ERRORLEVEL 1 goto EXIT

@echo on
dmd -ofperfMultiAtATime -O -release -inline -boundscheck=off -I..\std_data_json\source performance.d json.d ..\std_data_json\std_data_json.lib

@echo off
if ERRORLEVEL 1 goto EXIT

@echo on
perfOneAtATime.exe

@echo off
if ERRORLEVEL 1 goto EXIT

@echo on
perfMultiAtATime.exe

:EXIT
