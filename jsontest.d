import std.stdio;
import std.bigint;

import json;

//__gshared bool printTestInfo = true;
__gshared bool printTestInfo = false;

void main(string[] args)
{
}

JsonOptions options;
void test(Json expected, string text)
{
  import std.conv : to;
    
  if(printTestInfo) {
    writeln("--------------------------------------------------------------");
    writefln("[TEST] %s", escapeForTest(text));
  }
  Json actual;

  actual = parseJson(cast(char*)text.ptr, text.ptr + text.length, options);
  if(!expected.equals(actual)) {
    writefln("Expected: %s", expected);
    writefln("Actual  : %s", actual);
    stdout.flush();
    assert(0);
  }

  // Generate the JSON using toString and parse it again!
  string gen = to!string(actual);
  actual = parseJson(cast(char*)gen.ptr, gen.ptr + gen.length, options);
  if(!expected.equals(actual)) {
    writefln("OriginalJSON : %s", escapeForTest(text));
    writefln("GeneratedJSON: %s", escapeForTest(gen));
    writefln("Expected: %s", expected);
    writefln("Actual  : %s", actual);
    stdout.flush();
    assert(0);
  }
    
  // TODO: Convert to UTF(16/32)(LE/BE) and test again
  /+
   foreach(i, c; s) {
   utf16Buffer[i] = c;
   utf32Buffer[i] = c;
   }
   //json = parseJson(utf8Buffer.ptr, utf8Buffer.ptr + length, options);
   //assert(expected.equals(json));
   json = parseJson!(OnlyUtf8.no)(cast(char*)utf16Buffer.ptr, cast(char*)(utf16Buffer.ptr + s.length), options);
   assert(expected.equals(json));
   +/
}

unittest
{
  // Test Converting Parsed String to a Json Number
  assert(Json( 0  ).equals(Json( "0", 1)));
  assert(Json( 0  ).equals(Json("-0", 2)));
  assert(Json( 0.0).equals(Json("0.0", 1/*, 2*/)));

  assert(Json( 1  ).equals(Json( "1", 1)));
  assert(Json(-1  ).equals(Json("-1", 2)));
  assert(Json( 1.0).equals(Json("1.0", 1/*, 2*/)));

  assert(Json( 9  ).equals(Json( "9", 1)));
  assert(Json(-9  ).equals(Json("-9", 2)));
  assert(Json( 9.0).equals(Json("9.0", 1/*, 2*/)));

  assert(Json(ulong.max - 1)                 .equals(Json("18446744073709551614", 20)));
  assert(Json(ulong.max  )                   .equals(Json("18446744073709551615", 20)));
  assert(Json(BigInt("18446744073709551616")).equals(Json("18446744073709551616", 20)));

  assert(Json(BigInt("-9223372036854775809")).equals(Json("-9223372036854775809", 20)));
  assert(Json(long.min)                      .equals(Json("-9223372036854775808", 20)));
  assert(Json(long.min + 1)                  .equals(Json("-9223372036854775807", 20)));

  assert(Json(long.max - 1)                  .equals(Json("9223372036854775806" , 19)));
  assert(Json(long.max)                      .equals(Json("9223372036854775807" , 19)));
  assert(Json(BigInt("9223372036854775808")) .equals(Json("9223372036854775808" , 19)));
  
  assert(Json( BigInt("123456789012345678901234567890"))            .equals(Json("123456789012345678901234567890", 30)));
  assert(Json( BigInt("999999999999999999999999223372036854775807")).equals(Json("999999999999999999999999223372036854775807", 42)));

  assert(Json( 0.0).equals(Json( "0e0"    , 1)));
  assert(Json(10.0).equals(Json( "1e1"    , 1)));
  assert(Json(123.4).equals(Json("1.234e2", 1)));
  assert(Json(123.4).equals(Json("1.234E2", 1)));
  assert(Json(.01234).equals(Json("1.234e-2", 1)));
  assert(Json(.01234).equals(Json("1.234E-2", 1)));
}
unittest
{
  test(Json( 0  ), "0");
  test(Json( 0  ), "-0");
  test(Json( 0.0), "0.0");

  test(Json( 1  ), "1");
  test(Json(-1  ), "-1");
  test(Json( 1.0), "1.0");

  test(Json( 9  ), "9");
  test(Json(-9  ), "-9");
  test(Json( 9.0), "9.0");

  test(Json(ulong.max - 1)                 , "18446744073709551614");
  test(Json(ulong.max    )                 , "18446744073709551615");
  test(Json(BigInt("18446744073709551616")), "18446744073709551616");

  test(Json(BigInt("-9223372036854775809")), "-9223372036854775809");
  test(Json( long.min    )                 , "-9223372036854775808");
  test(Json( long.min + 1)                 , "-9223372036854775807");

  test(Json( long.max - 1)                 , "9223372036854775806");
  test(Json( long.max    )                 , "9223372036854775807");
  test(Json(BigInt("9223372036854775808")) , "9223372036854775808");


  test(Json( BigInt("123456789012345678901234567890"))            , "123456789012345678901234567890");
  test(Json( BigInt("999999999999999999999999223372036854775807")), "999999999999999999999999223372036854775807");

  test(Json(1.23456), "1.23456");

  test(Json( 0.0),  "0e0");
  test(Json(10.0),  "1e1");
  test(Json(123.4),  "1.234e2");

  test(Json.hugeNumber("1e993882"), "1e993882");
  test(Json.hugeNumber("0.1e7474993882"), "0.1e7474993882");

  // TODO: Converting a string to a json number does not handle
  //       double overflows like this test
  //test(Json.hugeNumber("0.1234567890123456789"), "0.1234567890123456789");
}
