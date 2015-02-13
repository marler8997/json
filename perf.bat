
REM Build Json Parser from S-Ludwig
REM Use dub in ..\std_data_json
@echo on

REM set EXTRA_VERSION=
set EXTRA_VERSION=-version=OneParseJsonAtATime


dmd -O -release -inline -boundscheck=off %EXTRA_VERSION% -I..\std_data_json\source performance.d json.d ..\std_data_json\std_data_json.lib

@echo off
if ERRORLEVEL 1 goto EXIT

@echo on
performance.exe

:EXIT
