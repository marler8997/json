
REM Build Json Parser from S-Ludwig
REM Use dub in ..\std_data_json

dmd -O -release -inline -boundscheck=off -I..\std_data_json\source performance.d json.d ..\std_data_json\std_data_json.lib
performance.exe
