
@echo on
dmd -ofjsontest1 jsontest.d json.d -unittest
@echo off
if ERRORLEVEL 1 goto EXIT
@echo on
jsontest1.exe
@echo off
if ERRORLEVEL 1 goto EXIT
@echo on
dmd -ofjsontest2 jsontest.d json.d -unittest -version=OneParseJsonAtATime
@echo off
if ERRORLEVEL 1 goto EXIT
@echo on
jsontest2.exe
@echo off
if ERRORLEVEL 1 goto EXIT

@echo on
dmd -ofjsontest3 jsontest.d json.d -unittest -version=ParseJsonNoGC
@echo off
if ERRORLEVEL 1 goto EXIT
@echo on
jsontest3.exe
@echo off
if ERRORLEVEL 1 goto EXIT
@echo on
dmd -ofjsontest4 jsontest.d json.d -unittest -version=ParseJsonNoGC -version=OneParseJsonAtATime
@echo off
if ERRORLEVEL 1 goto EXIT
@echo on
jsontest4.exe
@echo off
if ERRORLEVEL 1 goto EXIT


:EXIT
