
@echo on
REM dmd -ofperformance -O -release -inline -boundscheck=off performance.d json_firsttry.d json.d
dmd -ofperformance -O -release -inline -boundscheck=off performance.d json.d

@echo off
if ERRORLEVEL 1 goto EXIT

@echo on
performance.exe

:EXIT
