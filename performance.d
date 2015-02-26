import std.stdio;
import std.datetime;
import std.range;

import json;
import json2;
import std.json;

// GitRepo: https://github.com/s-ludwig/std_data_json.git
import stdx.data.json.parser;

void showError()
{
  string example = "[1.0e-100000]";
  //auto value = stdx.data.json.parser.parseJSONValue(example);
  auto value = std.json.parseJSON(example);
  writefln("value = '%s'", value);
}

void main(string[] args)
{
  //runTest(3, 100_000, `"hello"`);
  //runTest(3, 100_000, `"100283.00e13"`);
  //runTest(3, 100_000, `"[100283.00e13]"`);
  runTest(3, 100_000, `["hello","is","this","working", 1, 2.485e4]`);
  //runTest(3, 10_000, `{"key":182993,"key2":"value2","key3":null,"key4":["hello","is","this","working"],"key5":{"another":false}}`);
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
      std.json.parseJSON(testString);
    }
    sw.stop();
    writefln("  std.json      : %s milliseconds", sw.peek.msecs);

    sw.reset();
    sw.start();
    for(auto i = 0; i < loopCount; i++) {
      string parsed = testString;
      stdx.data.json.parser.parseJSONValue(parsed);
    }
    sw.stop();
    writefln("  stdx.data.json: %s milliseconds", sw.peek.msecs);

    sw.reset();
    sw.start();
    for(auto i = 0; i < loopCount; i++) {
      json.parseJson(testString);
    }
    sw.stop();
    writefln("  more.json     : %s milliseconds", sw.peek.msecs);

    sw.reset();
    sw.start();
    for(auto i = 0; i < loopCount; i++) {
      json2.parseJson(cast(char[])testString);
    }
    sw.stop();
    writefln("  more.json2    : %s milliseconds", sw.peek.msecs);
  }
}

