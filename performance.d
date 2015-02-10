import std.stdio;
import std.datetime;
import std.range;

import json;
import std.json;

void main(string[] args)
{
  runTest(3, 100_000, `["hello","is","this","working"]`);

  runTest(3, 100_000, `{"key":"value","key2":"value2","key3":null,"key4":["hello","is","this","working"]}`);
}

void runTest(size_t runCount, size_t loopCount, string testString)
{
  writeln("--------------------------------------------------");
  writefln("[TEST] %s", testString);
  writeln("--------------------------------------------------");
  StopWatch sw;
  for(auto runIndex = 0; runIndex < runCount; runIndex++) {

    writefln("run %s (loopcount %s)", runIndex + 1, loopCount);
    sw.reset();
    sw.start();
    for(auto i = 0; i < loopCount; i++) {
      parseJson(testString);
    }
    sw.stop();
    writefln("  more     : %s milliseconds", sw.peek.msecs);

    sw.reset();
    sw.start();
    for(auto i = 0; i < loopCount; i++) {
      parseJSON(testString);
    }
    sw.stop();
    writefln("  std      : %s milliseconds", sw.peek.msecs);
  }
}
