
REM Build Json Parser from S-Ludwig
set STDX=..\std_data_json\source\stdx\data\json


REM @echo on
REM dmd -ofperfOneAtATime   -O -release -inline -boundscheck=off -I..\std_data_json\source performance.d json.d json2.d %STDX%\foundation.d %STDX%\lexer.d %STDX%\parser.d %STDX%\value.d -version=OneParseJsonAtATime

REM @echo off
REM if ERRORLEVEL 1 goto EXIT

@echo on
dmd -ofperformance -O -release -inline -boundscheck=off -I..\std_data_json\source performance.d json.d json2.d %STDX%\foundation.d %STDX%\lexer.d %STDX%\parser.d %STDX%\value.d

@echo off
if ERRORLEVEL 1 goto EXIT

REM @echo on
REM perfOneAtATime.exe

REM @echo off
REM if ERRORLEVEL 1 goto EXIT

@echo on
performance.exe

:EXIT
