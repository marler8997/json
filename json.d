/* TODO
--------------------------------------------------------------------------------
* !!!! Handle overflows for long doubles when converting string to number in Json constructor
* Implement non-ascii chars
* Implement error messages with line/col numbers and filenames
   - Already setup to do this, the linenumber is kept track of and the column
     number can be calculated by subtracting the next pointer from lineStart
* Implement comments
* Implement UTF16 & UTF32
* Support single-quoted strings?
   Add an argument to the scanQuotedString that says what the end character is
* What to do about memory?
   - For arrays, I could do a 2-pass on arrays
     On the first pass I can count the number of elements and on
     the seconds I can perform the parse (make this a compile option for now)
* Think about making JsonParser.parse re-entrant.
  Some of the functions will need to rewind their state
* Note: std.json crashes when an exponent exceeds what a double can represent
        this parser handles those numbers by storing the number as a string
*/
module json;

// Compile Options
alias LineNumber = uint;
version(unittest)
{
  //__gshared bool printTestInfo = true;
  __gshared bool printTestInfo = false;
}
/**
--------------------------------------------------------------------------------
The "OneParseJsonAtATime" version uses a single __gshared global variable for
the parser state. This results in the best performance but will have
unpredictable results if two threads call parseJson at the same time.  The
default version uses a TLS pointer to point to the memory for the parser. This
memory is allocated on the function stack when parserJsonValues is called.

It is recommended to set the thread model version using the command line, i.e.
   dcompiler -version=OneParseJsonAtATime
*/
import std.stdio  : write, writeln, writefln, stdout;
import std.string : format;
import std.bigint;
import std.array : appender, Appender;

//
// The JSON Specification is defined in RFC4627 and RFC7159
//
enum JsonType : ubyte { bool_ = 0, number = 1, string_ = 2, array = 3, object = 4}
/++
Lenient JSON
 1. Ignores end-of-line comments starting with // or #
 2. Ignores multiline comments /* till */ (cannot be nested)
 3. Unquoted or Single quoted strings
 4. Allows a trailing comma after the last array element or object name/value pair
+/
class JsonException : Exception
{
  enum Type {
    unknown,
    noJson,
    multipleRoots,
    invalidChar, // Encountered an invalid character (not inside a string)
    controlChar, // Encountered non-whitespace control char (ascii=0x00-0x1F)
    endedInsideStructure, // The JSON ended inside an object or an array
    unexpectedChar, // Encountered a char unexpectedly
    tabNewlineCRInsideQuotes,
    controlCharInsideQuotes,
    invalidEscapeChar,
    keywordAsKey // A keyword was used as an object key
  }
  Type type;
  this(Type type, string msg, string file = __FILE__, size_t line = __LINE__,
       Throwable next = null) pure nothrow @safe
  {
    this.type = type;
    super(msg, file, line, next);
  }
}
/*
 Control Characters
----------------------------------------
 1. '{' begin-object
 2. '}' end-object
 3. '[' begin-array
 4. ']' end-array
 5. ':' name-separator
 6. ',' value-separator
 (Lenient JSON)
 7. '#' Single-line comment
 8. '//' Single-line comment
 9  '/*' Multi-line comment

 Whitespace
----------------------------------------
 1. ' '  0x20
 2. '\t' 0x09
 3. '\n' 0x0A
 4. '\r' 0x0D

Grammar
----------------------------------------
value = 'null' | 'false' | 'true' | object | array | number | string

object = '{' '}' | '{' members '}'

(JSON)  members = pair       | pair ',' members
(LJSON) members = pair [','] | pair ',' members

pair = string ':' value

array = '[' ']' | '[' elements ']'

(JSON)  elements = value       | value ',' elements
(LJSON) elements = value [','] | value ',' elements

number = [ '-' ] int [ frac ] [ exp ]

digit1-9 = '1' - '9'
digit    = '0' - '9'
int = '0' | digit1-9 digit*

frac = '.' DIGIT+
exp  = 'e' ( '-' | '+' )? DIGIT+

string = '"' char* '"'

char = Any UNICODE character except '"' (0x22), '\' (0x5C) or a control char (less than ' ' (0x20))
     | '\' escape-char

(LJSON) string |= unquoted-char*
(LJSON) unquoted-char = Any UNICODE character except control chars (< ' ' (0x20)), Whitespace, or structure chars "{}[]:,#/"

escape-char = '"' | // 0x22
              '\' | // 0x5C
              '/' | // 0x2F
              'b' | // 0x08 (backspace)
              't' | // 0x09 (tab)
              'n' | // 0x0A (line feed)
              'f' | // 0x0C (form feed)
              'r' | // 0x0D (carriage return)
              'u'XXXX | // hex code for unicode char

Encoding
---------------------
Note that you can tell the encoding of a json file by looking at the first 2 characters.  This is because the first 2 characters must be ascii characters so you can tell if it is UTF-8, UTF-16 or UTF-32

 00 00 00 xx  UTF-32BE
 00 xx 00 xx  UTF-16BE
 xx 00 00 00  UTF-32LE
 xx 00 xx 00  UTF-16LE
 xx xx        UTF-8

*/
enum JsonCharSet : ubyte {
  other          =  0, // (default) Any ascii character that is not in another set 
  notAscii       =  1, // Any character larger then 127
  spaceTabCR     =  2, // ' ', '\t' or '\r'
  newline        =  3, // '\n'
  startObject    =  4, // '{'
  endObject      =  5, // '}'
  startArray     =  6, // '['
  endArray       =  7, // ']'
  nameSeparator  =  8, // ':'
  valueSeparator =  9, // ','
  slash          = 10, // '/' (Used for comments)
  hash           = 11, // '#' (Used for comments)
  quote          = 12, // '"'
  asciiControl   = 13, // Any character less then 0x20 (an ascii control character)
}
enum JsonCharSetLookupLength = 128;
__gshared immutable JsonCharSet[JsonCharSetLookupLength] jsonCharSetMap =
  [
   '\0'   : JsonCharSet.asciiControl,
   '\x01' : JsonCharSet.asciiControl,
   '\x02' : JsonCharSet.asciiControl,
   '\x03' : JsonCharSet.asciiControl,
   '\x04' : JsonCharSet.asciiControl,
   '\x05' : JsonCharSet.asciiControl,
   '\x06' : JsonCharSet.asciiControl,
   '\x07' : JsonCharSet.asciiControl,
   '\x08' : JsonCharSet.asciiControl,

   '\x0B' : JsonCharSet.asciiControl,
   '\x0C' : JsonCharSet.asciiControl,

   '\x0E' : JsonCharSet.asciiControl,
   '\x0F' : JsonCharSet.asciiControl,
   '\x10' : JsonCharSet.asciiControl,
   '\x11' : JsonCharSet.asciiControl,
   '\x12' : JsonCharSet.asciiControl,
   '\x13' : JsonCharSet.asciiControl,
   '\x14' : JsonCharSet.asciiControl,
   '\x15' : JsonCharSet.asciiControl,
   '\x16' : JsonCharSet.asciiControl,
   '\x17' : JsonCharSet.asciiControl,
   '\x18' : JsonCharSet.asciiControl,
   '\x19' : JsonCharSet.asciiControl,
   '\x1A' : JsonCharSet.asciiControl,
   '\x1B' : JsonCharSet.asciiControl,
   '\x1C' : JsonCharSet.asciiControl,
   '\x1D' : JsonCharSet.asciiControl,
   '\x1E' : JsonCharSet.asciiControl,
   '\x1F' : JsonCharSet.asciiControl,

   '\t'   : JsonCharSet.spaceTabCR,
   '\n'   : JsonCharSet.newline,
   '\r'   : JsonCharSet.spaceTabCR,
   ' '    : JsonCharSet.spaceTabCR,

   '{'    : JsonCharSet.startObject,
   '}'    : JsonCharSet.endObject,
   '['    : JsonCharSet.startArray,
   ']'    : JsonCharSet.endArray,

   ':'    : JsonCharSet.nameSeparator,
   ','    : JsonCharSet.valueSeparator,

   '/'    : JsonCharSet.slash,
   '#'    : JsonCharSet.hash,

   '"'    : JsonCharSet.quote];

//
// The location of every Json value will be stored
// in the same place.  The Json value will not know it's own location.
// You will need the other data structure to locate the json value.
// WHY?
// 1. The location of the Json value will not be looked up very often, sometimes never.
//    It will probably only be used when reporting errors.
// 2. This will make locations of json values optional (at runtime) without wasting memory.
//
struct Json
{
  enum NumberType : ubyte { long_ = 0, double_ = 1, bigInt = 2, string_ = 3 }

  union Payload {
    bool bool_;
    long long_;
    double double_;
    BigInt bigInt;
    string string_;
    Json[] array;
    Json[string] object;
  }

  private ubyte info;
  Payload payload;

  @property static Json null_() {
    return Json(cast(Json[string])null);
  }
  @property static Json emptyObject() {
    Json[string] map;
    return Json(map);
  }
  @property static Json emptyArray() {
    return Json(cast(Json[])[]);
  }
  
  /// ditto
  this(bool value) {
    this.info = JsonType.bool_;
    this.payload.bool_ = value;
  }
  /// ditto
  this(int value) {
    this.info = NumberType.long_ << 3 | JsonType.number;
    this.payload.long_ = value;
  }
  /// ditto
  this(uint value) {
    this.info = NumberType.long_ << 3 | JsonType.number;
    this.payload.long_ = value;
  }
  /// ditto
  this(long value) {
    this.info = NumberType.long_ << 3 | JsonType.number;
    this.payload.long_ = value;
  }
  /// ditto
  this(ulong value) {
    this.info = NumberType.bigInt << 3 | JsonType.number;
    this.payload.bigInt = value;
  }
  /// ditto
  this(double value) {
    this.info = NumberType.double_ << 3 | JsonType.number;
    this.payload.double_ = value;
  }
  /// ditto
  this(BigInt value) {
    this.info = NumberType.bigInt << 3 | JsonType.number;
    this.payload.bigInt = value;
  }
  /// ditto
  this(string value) {
    this.info = JsonType.string_;
    this.payload.string_ = value;
  }
  /// ditto
  this(Json[] value) {
    this.info = JsonType.array;
    this.payload.array = value;
  }
  /// ditto
  this(Json[string] value) {
    this.info = JsonType.object;
    this.payload.object = value;
  }

  static immutable maxNegativeLongString  =  "-9223372036854775808";
  static immutable maxLongString          =   "9223372036854775807";
  //static immutable maxUlongString = "18446744073709551615";
  this(const(char[]) numberString, size_t intPartLength)
  {
    import std.conv : to, ConvException;
    if(intPartLength == numberString.length) {
      if(numberString[0] == '-') {
	if(numberString.length <  maxNegativeLongString.length ||
	   (numberString.length == maxNegativeLongString.length && numberString <= maxNegativeLongString)) {
	  this(to!long(numberString));
	  return;
	}
      } else {
	if(numberString.length <  maxLongString.length ||
	   (numberString.length == maxLongString.length && numberString <= maxLongString)) {
	  this(to!long(numberString));
	  return;
	}
      }
      this(BigInt(numberString));
    } else {
      try {
	// TODO: how to handle double overflow?
	//       the 'to' function will not fail if there are too many
	//       digits after the decimal point
	this(to!double(numberString));
      } catch(ConvException) {
	setupAsHugeNumber(cast(string)numberString);
      }
    }
  }
  unittest
  {
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

  private this (ubyte info, Payload payload) {
    this.info = info;
    this.payload = payload;
  }
  static Json hugeNumber(string number)
  {
    //return Json(cast(ubyte)(Json.NumberType.string_ << 3 | JsonType.number), Payload(cast(string)number));
    Json json;
    json.setupAsHugeNumber(number);
    return json;
  }
  void setupAsHugeNumber(string number)
  {
    info = Json.NumberType.string_ << 3 | JsonType.number;
    payload.string_ = cast(string)number;
  }
  
  bool isObject()
  {
    return this.info == JsonType.object;
  }
  void setupAsObject()
  {
    this.info = JsonType.object;
  }
  bool isArray()
  {
    return this.info == JsonType.array;
  }
  void setupAsArray()
  {
    this.info = JsonType.array;
  }
  bool isString()
  {
    return this.info == JsonType.string_;
  }
  bool opEquals(ref Json other)
  {
    assert(0, "Do not compare Json values using '==', instead, use value.equals(otherValue)");
  }
  bool equals(Json other)
  {
    final switch(info & 0b111) {
    case JsonType.bool_:
      return other.info == JsonType.bool_ && this.payload.bool_ == other.payload.bool_;
    case JsonType.number:
      final switch((info >> 3) & 0b111) {
      case NumberType.long_  : return this.info == other.info && this.payload.long_   == other.payload.long_;
      case NumberType.double_: return this.info == other.info && this.payload.double_ == other.payload.double_;
      case NumberType.bigInt : return this.info == other.info && this.payload.bigInt  == other.payload.bigInt;
      case NumberType.string_: return this.info == other.info && this.payload.string_ == other.payload.string_;
      }
    case JsonType.string_:
      return other.info == JsonType.string_ && this.payload.string_ == other.payload.string_;
    case JsonType.array:
      if(other.info != JsonType.array)
	return false;
      if(this.payload.array.length != other.payload.array.length)
	return false;
      foreach(i; 0..this.payload.array.length) {
	if(!this.payload.array[i].equals(other.payload.array[i]))
	  return false;
      }
      return true;
    case JsonType.object:
      if(other.info != JsonType.object)
	return false;
      if(this.payload.object.length != other.payload.object.length)
	return false;
      foreach(key, value; this.payload.object) {
	if(!value.equals(other.payload.object[key]))
	  return false;
      }
      return true;
    }
  }
/+
  void arrayAppend(Json value)
  {
    payload.array ~= value;
  }
  void add(string key, Json value) {
    payload.object[key] = value;
  }
+/
  @property string typeString()
  {
    import std.conv : to;
    if((info & 0b111) == JsonType.number) {
      final switch((info >> 3) & 0b111) {
      case NumberType.long_  : return "number:long";
      case NumberType.double_: return "number:double";
      case NumberType.bigInt : return "number:bigint";
      case NumberType.string_: return "number:string";
      }
    }
    return to!string(cast(JsonType)(info & 0b111));
  }
  void toString(scope void delegate(const(char)[]) sink) const
  {
    import std.conv : to;
    
    final switch(info & 0b111) {
    case JsonType.bool_:
      sink(payload.bool_ ? "true" : "false");
      return;
    case JsonType.number:
      final switch((info >> 3) & 0b111) {
      case NumberType.long_:
	sink(payload.long_.to!string());
	return;
      case NumberType.double_:
	sink(payload.double_.to!string());
	return;
      case NumberType.bigInt:
	sink(payload.bigInt.to!string());
	return;
      case NumberType.string_:
	sink(payload.string_);
	return;
      }
    case JsonType.string_:
      if(payload.string_ is null) {
	sink("null");
      } else {
	sink(`"`);
	sink(payload.string_);
	sink(`"`);
      }
      return;
    case JsonType.array:
      if(payload.array is null) {
	sink("null");
      } else if(payload.array.length == 0) {
	sink("[]");
      } else {
	sink("[");
	payload.array[0].toString(sink);
	foreach(value; payload.array[1..$]) {
	  sink(",");
	  value.toString(sink);
	}
	sink("]");
      }
      return;
    case JsonType.object:
      if(payload.object is null) {
	sink("null");
      } else if(payload.object.length == 0) {
	sink("{}");
      } else {
	sink("{");
	bool atFirst = true;
	foreach(key, value; payload.object) {
	  if(atFirst) {atFirst = false;} else {sink(",");}
	  sink("\"");
	  sink(key);
	  sink("\":");
	  value.toString(sink);
	}
	sink("}");
      }
      return;
    }
  }
}
/// Shows the basic construction and operations on JSON values.
unittest
{
  Json a = 12;
  Json b = 13;

/+
  assert(a == 12);
  assert(b == 13);
  //assert(a + b == 25.0);
  
  auto c = Json([a, b]);
  assert(c.array == [12.0, 13.0]);
  assert(c[0] == 12.0);
  assert(c[1] == 13.0);

  auto d = Json(["a": a, "b": b]);
  assert(d.map == ["a": a, "b": b]);
  assert(d["a"] == 12.0);
  assert(d["b"] == 13.0);
  //assert(d["a"] == 12);
  //assert(d["b"] == 13);
+/
}

/+
number = [ '-' ] int [ frac ] [ exp ]

digit1-9 = '1' - '9'
digit    = '0' - '9'
int = '0' | digit1-9 digit*

frac = '.' DIGIT+
exp  = 'e' ( '-' | '+' )? DIGIT+


<number>
    '-'     = goto <int1>
    '0'     = goto <frac_exp_or_done>
    '1'-'9' = goto <int2>

<int1>
    '0'     = goto <frac_exp_or_done>
    '1'-'9' = goto <int2>

<int2>
    '0'-'9' = stay
    '.'     = goto <frac>
    'e' 'E' = goto <exp1>

<frac_exp_or_done>
    '.'     = goto <frac>
    'e' 'E' = goto <exp1>

<frac>
    '0'-'9' = stay
    'e' 'E' = goto <exp1>

<exp1>
    '-'     = goto <exp2>
    '+'     = goto <exp2>
    '0'-'9' = goto <exp2>

<exp2>
    '0'-'9' = stay
+/

struct JsonOptions
{
  ubyte flags;
  
  @property bool lenient() pure nothrow @safe @nogc const { return (flags & 0x01) != 0;}
  @property void lenient(bool v) pure nothrow @safe @nogc { if (v) flags |= 0x01;else flags &= ~0x01;}
}
struct JsonParserState
{
  JsonOptions options;
  char* next;
  char c;
  char* limit;

  JsonCharSet charSet;
  string currentContextDebugName;
  immutable(void function())[] currentContextMap;

  char* lastLineStart;
  LineNumber lineNumber;

  Appender!(Json[]) rootValues;
  StructureContext currentContext;
}

private
{
  struct StructureContext
  {
    immutable(ContainerMethods)* vtable;
    bool containerEnded;

    union Structure {
      ObjectContext object;
      ArrayContext array;
    }
    Structure structure;
    alias structure this;

    void setRootContext() {
      vtable = null;
    }
    bool atRootContext() {
      return vtable == null;
    }
  }

  struct ObjectContext
  {
    Json[string] map;
    string currentKey;
  }
  struct ArrayContext
  {
    auto values = appender!(Json[])();
  }

  version(OneParseJsonAtATime) {
    __gshared JsonParserState state;
  } else {
    JsonParserState* state;
  }
  
  struct ContainerMethods
  {
    void function(string key) setKey;
    void function(ref StructureContext context, Json value) addValue;
    bool function() isEmpty;
    void function() setCommaContext;

    static void setObjectKey(string key)
    {
      assert(state.currentContext.object.currentKey is null);
      state.currentContext.object.currentKey = key;
    }
    static void invalidSetKey(string key)
    {
      assert(0, "code bug: cannot call setKey on a non-object container");
    }
    static void addObjectValue(ref StructureContext context, Json value) {
      assert(context.object.currentKey !is null);
      context.object.map[context.object.currentKey] = value;
      context.object.currentKey = null; // NOTE: only for debugging purposes
    }
    static void addArrayValue(ref StructureContext context, Json value) {
      context.array.values.put(value);
    }
    static void invalidAddValue(ref StructureContext context, Json value) {
      assert(0, "code bug: cannot call addValue on a non-object/array value");
    }
    static bool objectIsEmpty() {
      return state.currentContext.object.map.length == 0;
    }
    static bool arrayIsEmpty() {
      return state.currentContext.array.values.data.length == 0;
    }
    static bool invalidIsEmpty() {
      assert(0, "code bug: cannot call isEmpty on a non-object/array value");;
    }
    static void invalidSetCommaContext() {
      assert(0, "code bug: cannot call setCommmaContext on a non-object/array value");;
    }
    
    static immutable ContainerMethods object =
      ContainerMethods(&setObjectKey, &addObjectValue, &objectIsEmpty, &setObjectCommaContext);
    static immutable ContainerMethods array =
      ContainerMethods(&invalidSetKey, &addArrayValue, &arrayIsEmpty, &setArrayCommaContext);
    static immutable ContainerMethods value =
      ContainerMethods(&invalidSetKey, &invalidAddValue, &invalidIsEmpty, &invalidSetCommaContext);
  }

  /*
   * ExpectedState: next points to the character in question
   * Note: uses the c variable and charSet
   * other          = 0,  YES
   * notAscii       = 1,  YES
   * spaceTabCR     = 2,  NO
   * newline        = 3,  NO
   * startObject    = 4,  NO
   * endObject      = 5,  NO
   * startArray     = 6,  NO
   * endArray       = 7,  NO
   * nameSeparator  = 8,  NO
   * valueSeparator = 9,  NO
   * slash          = 10, NO
   * hash           = 11, NO
   * quote          = 12, NO
   * asciiControl   = 13, NO
   */
  bool nextCouldBePartOfUnquotedString()
  {
    if(state.next >= state.limit) return false;
    state.c = *state.next;
    if(state.c >= JsonCharSetLookupLength)
      return true;
    state.charSet = jsonCharSetMap[state.c];
    return state.charSet == JsonCharSet.other;
  }

  //
  // ExpectedState: c is first letter, next points to char after first letter
  //
  Json tryScanKeywordOrNumber()
  {
    if(state.c == 'n') {
      if(state.next + 3 <= state.limit && state.next[0..3] == "ull") {
	state.next += 3;
	if(nextCouldBePartOfUnquotedString()) {
	  state.next -= 3;
	} else {
	  return Json.null_;
	}
      }
    } else if(state.c == 't') {
      if(state.next + 3 <= state.limit && state.next[0..3] == "rue") {
	state.next += 3;
	if(nextCouldBePartOfUnquotedString()) {
	  state.next -= 3;
	} else {
	  return Json(true);
	}
      }
    } else if(state.c == 'f') {
      if(state.next + 4 <= state.limit && state.next[0..4] == "alse") {
	state.next += 4;
	if(nextCouldBePartOfUnquotedString()) {
	  state.next -= 4;
	} else {
	  return Json(false);
	}
      }
    }

    state.next--;
    char* startNum = state.next;
    auto intPartLength = tryScanNumber();
    if(intPartLength == 0) {
      state.next++; // restore next
      return Json(cast(Json[])null); // Used to flag that no keyword or number was found
    }

    return Json(startNum[0..state.next-startNum], intPartLength);
  }
  // ExpectedState: c is the first char, next points to the next char
  // ReturnState: next points to the char after the string
  Json scanNumberOrUnquoted()
  {
    //
    // Try to scan a number first
    //
    state.next--;
    {
      char* startNum = state.next;
      auto intPartLength = tryScanNumber();
      if(intPartLength > 0) {
	if(nextCouldBePartOfUnquotedString()) {
	  state.next = startNum; // must be an unquoted string
	} else {
	  return Json(startNum[0..state.next-startNum], intPartLength);
	}
      }
    }

    auto start = state.next;
    state.next++;
    while(true) {
      if(state.next >= state.limit)
	break;
      state.c = *state.next;
      if(state.c >= JsonCharSetLookupLength)
	throw new Exception("non-ascii chars not implemented");
      state.charSet = jsonCharSetMap[state.c];
      if(state.charSet != JsonCharSet.other)
	break;
      state.next++;
    }

    auto s = start[0..state.next-start];
    if(s.length == 4) {
      if(s == "null")
	return Json.null_;
      if(s == "true")
	return Json(true);
    } else if(s.length == 5) {
      if(s == "false")
	return Json(false);
    }
    return Json(cast(string)s);
  }

  // TODO: if the character after the number can be part of an unquoted
  //       string, then it is an error for strict json, and an unquoted string
  //       for lenient json.
  // ExpectedState: c is the first char, next points to c
  // Returns: length of the integer part of the string
  //          next points to the character after the number (no change if not a number)
  size_t tryScanNumber()
  {
    size_t intPartLength;
    char* cpos = state.next + 1;

    if(state.c == '-') {
      if(cpos >= state.limit)
       	return 0; // '-' is not a number
      state.c = *cpos;
      cpos++;
    }

    if(state.c == '0') {
      intPartLength = cpos-state.next;
      if(cpos < state.limit) {
	state.c = *cpos;
	if(state.c == '.')
	  goto FRAC;
	if(state.c == 'e' || state.c == 'E')
	  goto EXPONENT;
      }
      state.next += intPartLength;
      return intPartLength;
    }

    if(state.c > '9' || state.c < '1')
      return 0; // can't be a number

    while(true) {
      if(cpos < state.limit) {
	state.c = *cpos;
	if(state.c <= '9' && state.c >= '0') {
	  cpos++;
	  continue;
	}
	if(state.c == '.') {
	  intPartLength = cpos-state.next;
	  goto FRAC;
	}
	if(state.c == 'e' || state.c == 'E') {
	  intPartLength = cpos-state.next;
	  goto EXPONENT;
	}
      }
      intPartLength = cpos-state.next;
      state.next += intPartLength;
      return intPartLength;
    }

  FRAC:
    // cpos points to '.'
    cpos++;
    if(cpos >= state.limit)
      return 0; // Must have digits after decimal point but got end of input
    state.c = *cpos;
    if(state.c > '9' || state.c < '0')
      return 0; // Must have digits after decimal point but got something else
    //number.decimalOffset = cpos-next;
    while(true) {
      cpos++;
      if(cpos < state.limit) {
	state.c = *cpos;
	if(state.c <= '9' && state.c >= '0')
	  continue;
	if(state.c == 'e' || state.c == 'E')
	  goto EXPONENT;
      }
      state.next = cpos;
      return intPartLength;
    }

  EXPONENT:
    // cpos points to 'e' or 'E'
    cpos++;
    if(cpos >= state.limit)
      return 0; // Must have -/+/digits after 'e' but got end of input
    //number.exponentOffset = cpos-next;
    state.c = *cpos;
    if(state.c == '-') {
      //number.exponentNegative = true;
      cpos++;
      if(cpos >= state.limit)
	return 0; // Must have digits after '-'
      state.c = *cpos;
    } else if(state.c == '+') {
      cpos++;
      if(cpos >= state.limit)
	return 0; // Must have digits after '+'
      state.c = *cpos;
    }

    if(state.c > '9' || state.c < '0')
      return 0; // Must have digits after 'e'
    while(true) {
      cpos++;
      if(cpos < state.limit) {
	state.c = *cpos;
	if(state.c <= '9' && state.c >= '0')
	  continue;
      }
      state.next = cpos;
      return intPartLength;
    }
  }
  unittest
  {
    version(OneParseJsonAtATime) {
    } else {
      JsonParserState stateBufferOnStack;
      state = &stateBufferOnStack;
    }

    void test(Json expected, const(char)[] numString)
    {
      if(printTestInfo) {
	writeln("------------------------------------------------------------");
	writefln("[TEST] %s", numString);
      }
      state.c     = numString[0];
      state.next  = cast(char*)numString.ptr;
      state.limit = cast(char*)numString.ptr + numString.length;
      auto parsedIntLength = tryScanNumber();
      assert(state.next == state.limit);
      auto parsed = Json(numString, parsedIntLength);
      if(!expected.equals(parsed)) {
	writefln("Expected: %s", expected);
	writefln("Actual  : %s", parsed);
	assert(0);
      }
    }

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
  unittest
  {
    char[128] buffer;
    
    void testNumber(string intString, string decimalString, string exponentString)
    {
      size_t offset = 0;
      buffer[offset..offset+intString.length] = intString[];
      offset += intString.length;
      if(decimalString.length > 0) {
	buffer[offset++] = '.';
	buffer[offset..offset+decimalString.length] = decimalString[];
	offset += decimalString.length;
      }

      if(exponentString is null) {

	if(printTestInfo)
	  writefln("[TEST] %s", buffer[0..offset]);

	state.c     = buffer[0];
	state.next  = cast(char*)buffer.ptr;
	state.limit = cast(char*)buffer.ptr + offset;

	auto parsedIntLength = tryScanNumber();
	assert(state.next == state.limit);
	assert(parsedIntLength == intString.length);

      } else {

	auto saveOffset = offset;
	foreach(exponentChar; ['e', 'E']) {
	  foreach(exponentSign; ["", "-", "+"]) {
	    offset = saveOffset;
	    buffer[offset++] = exponentChar;
	    buffer[offset..offset+exponentSign.length] = exponentSign[];
	    offset += exponentSign.length;
	    buffer[offset..offset+exponentString.length] = exponentString[];
	    offset += exponentString.length;
	
	    if(printTestInfo)
	      writefln("[TEST] %s", buffer[0..offset]);

	    state.c     = buffer[0];
	    state.next  = cast(char*)buffer.ptr;
	    state.limit = cast(char*)buffer.ptr + offset;

	    auto parsedIntLength = tryScanNumber();
	    assert(parsedIntLength == intString.length);
	    assert(state.next == state.limit);
	  }
	}
      }
    }
    foreach(intString; ["0", "1", "1234567890", "9000018283", "-1", "-1234567890", "-28392893823983"]) {
      foreach(fracString; ["", "0", "1", "9", "00100"]) {
	foreach(expString; [null, "0", "1", "90009"]) {
	  testNumber(intString, fracString, expString);
	}
      }
    }
  }
  
  /*
Escape Characters
----------------------------------------    
  " 34  0x22
  / 47  0x2F
  \ 92  0x5C
  b 98  0x62
  f 102 0x66
  n 110 0x6E
  r 114 0x72
  t 116 0x74
  u 117 0x75
  */
  immutable ubyte[] highEscapeTable =
    [
     '/', //  92 0x5C "/"
       0, //  93 0x5D
       0, //  94 0x5E
       0, //  95 0x5F
       0, //  96 0x60
       0, //  97 0x61
    '\b', //  98 0x62 "b"
       0, //  99 0x63
       0, // 100 0x64
       0, // 101 0x65
    '\f', // 102 0x66 "f"
       0, // 103 0x67
       0, // 104 0x68
       0, // 105 0x69
       0, // 106 0x6A
       0, // 107 0x6B
       0, // 108 0x6C
       0, // 109 0x6D
    '\n', // 110 0x6E "n"
       0, // 111 0x6F
       0, // 112 0x70
       0, // 113 0x71
    '\r', // 114 0x72 "r"
       0, // 115 0x73
    '\t', // 116 0x74 "t"
       1, // 117 0x75 "u"
     ];
  
  /** ExpectedState: next points to char after string
   *  Returns: true if string ended with quote (next will point to char after quote),
   *           false if reached end-of-input before ending quote (next points to limit)
  */
  bool scanQuotedString()
  {
    while(true) {
      if(state.next >= state.limit) return false;
      state.c = *state.next;

      if(state.c == '"') {
	state.next++;
	return true;
      }

      if(state.c == '\\') {
	state.next++;
	if(state.next >= state.limit) return false;
	state.c = *state.next;
	if(state.c == '"') {
	  state.next++;
	} else if(state.c == '/') {
	  state.next++;
	} else {
	  if(state.c < '\\' || state.c > 'u')
	    throw new JsonException(JsonException.Type.invalidEscapeChar, format("invalid escape char '%s'", state.c));
	    
	  auto escapeValue = highEscapeTable[state.c - '\\'];
	  if(escapeValue == 0) {
	    throw new JsonException(JsonException.Type.invalidEscapeChar, format("invalid escape char '%s'", state.c));
	  }

	  if(state.c == 'u') {
	    throw new Exception("\\u escape sequences not implemented");
	  } else {
	    state.next++;
	  }
	}
      } else if(state.c <= 0x1F) {
	if(state.c == '\n')
	  throw new JsonException(JsonException.Type.tabNewlineCRInsideQuotes, "found newline '\n' inside quote");
	if(state.c == '\t')
	  throw new JsonException(JsonException.Type.tabNewlineCRInsideQuotes, "found tab '\t' inside quote");
	if(state.c == '\r')
	  throw new JsonException(JsonException.Type.tabNewlineCRInsideQuotes, "found carriage return '\r' inside quote");
	
	throw new JsonException(JsonException.Type.controlCharInsideQuotes,
				format("found control char 0x%x inside qoutes", cast(ubyte)state.c));
      } else if(state.c >= JsonCharSetLookupLength) {
	throw new Exception("[DEBUG] non-ascii chars not implemented yet");
      } else {
	state.next++;
      }
    }
  }
  
  void setRootContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &otherRootContext,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &startRootObject,
       JsonCharSet.endObject      : &unexpectedChar,
       JsonCharSet.startArray     : &startRootArray,
       JsonCharSet.endArray       : &unexpectedChar,
       JsonCharSet.nameSeparator  : &unexpectedChar,
       JsonCharSet.valueSeparator : &unexpectedChar,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &quoteRootContext,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "root";
    state.currentContextMap = contextMap;
  }
  void setObjectKeyContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &otherObjectKeyContext,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &unexpectedChar,
       JsonCharSet.endObject      : &endContainerBeforeValue,
       JsonCharSet.startArray     : &unexpectedChar,
       JsonCharSet.endArray       : &unexpectedChar,
       JsonCharSet.nameSeparator  : &unexpectedChar,
       JsonCharSet.valueSeparator : &unexpectedChar,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &quoteObjectKeyContext,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "object_key";
    state.currentContextMap = contextMap;
  }
  void setObjectValueContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &otherObjectValueContext,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &startObject,
       JsonCharSet.endObject      : &unexpectedChar,
       JsonCharSet.startArray     : &startArray,
       JsonCharSet.endArray       : &unexpectedChar,
       JsonCharSet.nameSeparator  : &unexpectedChar,
       JsonCharSet.valueSeparator : &unexpectedChar,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &quoteObjectValueContext,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "object_value";
    state.currentContextMap = contextMap;
  }
  void setArrayValueContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &otherArrayContext,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &startObject,
       JsonCharSet.endObject      : &unexpectedChar,
       JsonCharSet.startArray     : &startArray,
       JsonCharSet.endArray       : &endContainerBeforeValue,
       JsonCharSet.nameSeparator  : &unexpectedChar,
       JsonCharSet.valueSeparator : &unexpectedChar,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &quoteArrayContext,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "array";
    state.currentContextMap = contextMap;
  }
  void setObjectColonContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &unexpectedChar,
       JsonCharSet.notAscii       : &unexpectedChar,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &unexpectedChar,
       JsonCharSet.endObject      : &unexpectedChar,
       JsonCharSet.startArray     : &unexpectedChar,
       JsonCharSet.endArray       : &unexpectedChar,
       JsonCharSet.nameSeparator  : &objectColon,
       JsonCharSet.valueSeparator : &unexpectedChar,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &unexpectedChar,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "object_colon";
    state.currentContextMap = contextMap;
  }
  void setObjectCommaContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &unexpectedChar,
       JsonCharSet.notAscii       : &unexpectedChar,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &unexpectedChar,
       JsonCharSet.endObject      : &endContainerBeforeComma,
       JsonCharSet.startArray     : &unexpectedChar,
       JsonCharSet.endArray       : &unexpectedChar,
       JsonCharSet.nameSeparator  : &unexpectedChar,
       JsonCharSet.valueSeparator : &objectCommaSeparator,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &unexpectedChar,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "object_comma";
    state.currentContextMap = contextMap;
  }
  void setArrayCommaContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &unexpectedChar,
       JsonCharSet.notAscii       : &unexpectedChar,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &unexpectedChar,
       JsonCharSet.endObject      : &unexpectedChar,
       JsonCharSet.startArray     : &unexpectedChar,
       JsonCharSet.endArray       : &endContainerBeforeComma,
       JsonCharSet.nameSeparator  : &unexpectedChar,
       JsonCharSet.valueSeparator : &arrayCommaSeparator,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &unexpectedChar,
       JsonCharSet.asciiControl   : &invalidControlChar
       ];
    state.currentContextDebugName = "array_comma";
    state.currentContextMap = contextMap;
  }
  void ignore()
  {
  }
  void unexpectedChar()
  {
    throw new JsonException(JsonException.Type.unexpectedChar, format("unexpected '%s'", state.c));
  }
  void newline()
  {
    state.lastLineStart = state.next;
    state.lineNumber++;
  }
  void startRootObject()
  {
    // save the state to the stack
    auto saveLimit = state.limit;

    state.currentContext = StructureContext(&ContainerMethods.object);

    setObjectKeyContext();
    parseStateMachine();

    if(state.currentContext.containerEnded) {
      state.rootValues.put(Json(state.currentContext.object.map));

      // restore the previous state
      state.limit = saveLimit;
      state.currentContext.setRootContext();
      setRootContext();
    }
  }
  void startRootArray()
  {
    // save the state to the stack
    auto saveLimit = state.limit;
    
    state.currentContext = StructureContext(&ContainerMethods.array);

    setArrayValueContext();
    parseStateMachine();

    if(state.currentContext.containerEnded) {
      state.rootValues.put(Json(state.currentContext.array.values.data));

      // restore the previous state
      state.limit = saveLimit;
      state.currentContext.setRootContext();
      setRootContext();
    }
  }
  void startObject()
  {
    // save the state to the stack
    auto saveLimit = state.limit;
    auto saveContext = state.currentContext;

    state.currentContext = StructureContext(&ContainerMethods.object);

    setObjectKeyContext();
    parseStateMachine();

    if(state.currentContext.containerEnded) {
      saveContext.vtable.addValue(saveContext, Json(state.currentContext.object.map));

      // restore the previous state
      state.limit = saveLimit;
      state.currentContext = saveContext;
      state.currentContext.vtable.setCommaContext();
    }
  }
  void startArray()
  {
    // save the state to the stack
    auto saveLimit = state.limit;
    auto saveContext = state.currentContext;
    state.currentContext = StructureContext(&ContainerMethods.array);

    setArrayValueContext();
    parseStateMachine();

    if(state.currentContext.containerEnded) {
      saveContext.vtable.addValue(saveContext, Json(state.currentContext.array.values.data));

      // restore the previous state
      state.limit = saveLimit;
      state.currentContext = saveContext;
      state.currentContext.vtable.setCommaContext();
    }
  }
  void endContainerBeforeValue()
  {
    if(!state.options.lenient && !state.currentContext.vtable.isEmpty()) {
      unexpectedChar();
    }
    state.limit = state.next; // Causes the state machine to pop the stack and return
                              // to the function to end the current containers context
    state.currentContext.containerEnded = true;
  }
  void endContainerBeforeComma()
  {
    state.limit = state.next; // Causes the state machine to pop the stack and return
                              // to the function to end the current containers context
    state.currentContext.containerEnded = true;
  }
  void objectColon()
  {
    setObjectValueContext();
  }
  void objectCommaSeparator()
  {
    setObjectKeyContext();
  }
  void arrayCommaSeparator()
  {
    setArrayValueContext();
  }
  void invalidControlChar()
  {
    throw new JsonException(JsonException.Type.controlChar, format("invalid control character 0x%x", state.c));
  }
  void otherRootContext()
  {
    Json value;
    if(state.options.lenient) {
      value = scanNumberOrUnquoted();
    } else {
      value = tryScanKeywordOrNumber();
      if(value.isArray())
	throw new JsonException(JsonException.Type.unexpectedChar, format("unexpected char '%s'", state.c));
    }
    state.rootValues.put(value);
  }
  void otherObjectKeyContext()
  {
    if(!state.options.lenient)
      throw new JsonException(JsonException.Type.unexpectedChar, format("unexpected char '%s'", state.c));

    Json value = scanNumberOrUnquoted();
    if(!value.isString())
      throw new JsonException(JsonException.Type.keywordAsKey, format("expected string but got keyword '%s'", value));
    state.currentContext.vtable.setKey(value.payload.string_);
    setObjectColonContext();
  }

  // TODO: I could combine the next two methods
  void otherObjectValueContext()
  {
    Json value;
    if(state.options.lenient) {
      value = scanNumberOrUnquoted();
    } else {
      value = tryScanKeywordOrNumber();
      if(value.isArray())
	unexpectedChar();
    }
    state.currentContext.vtable.addValue(state.currentContext, value);
    setObjectCommaContext();
  }
  void otherArrayContext()
  {
    Json value;
    if(state.options.lenient) {
      value = scanNumberOrUnquoted();
    } else {
      value = tryScanKeywordOrNumber();
      if(value.isArray())
	unexpectedChar();
    }
    state.currentContext.vtable.addValue(state.currentContext, value);
    setArrayCommaContext();
  }
  void quoteRootContext()
  {
    char* startOfString = state.next;
    bool endedWithQuote = scanQuotedString();
    if(endedWithQuote) {
      state.rootValues.put(Json(cast(string)(startOfString[0..state.next-startOfString - 1])));
    } else {
      throw new Exception("end of input inside quoted string, no implementation for this yet");
    }
  }
  void quoteObjectKeyContext()
  {
    char* startOfString = state.next;
    bool endedWithQuote = scanQuotedString();
    if(endedWithQuote) {
      state.currentContext.vtable.setKey(cast(string)(startOfString[0..state.next-startOfString - 1]));
    } else {
      throw new Exception("end of input inside quoted string, no implementation for this yet");
    }
    setObjectColonContext();
  }
  void quoteObjectValueContext()
  {
    char* startOfString = state.next;
    bool endedWithQuote = scanQuotedString();
    if(endedWithQuote) {
      state.currentContext.vtable.addValue(state.currentContext, Json(cast(string)(startOfString[0..state.next-startOfString - 1])));
    } else {
      throw new Exception("end of input inside quoted string, no implementation for this yet");
    }
    setObjectCommaContext();
  }
  void quoteArrayContext()
  {
    char* startOfString = state.next;
    bool endedWithQuote = scanQuotedString();
    if(endedWithQuote) {
      state.currentContext.vtable.addValue(state.currentContext, Json(cast(string)(startOfString[0..state.next-startOfString - 1])));
    } else {
      throw new Exception("end of input inside quoted string, no implementation for this yet");
    }
    setArrayCommaContext();
  }
  void notImplemented()
  {
    throw new Exception(format("Error: char set '%s' not implemented in '%s' context", state.charSet, state.currentContextDebugName));
  }

  void parseStateMachine()
  {
    while(state.next < state.limit) {
      state.c = *state.next;
      if(state.c >= JsonCharSetLookupLength) {
	state.charSet = JsonCharSet.notAscii;
	//writefln("[DEBUG] c = '%s' (CharSet=%s) (Context=%s)", escape(c), state.charSet, state.currentContextDebugName);
	throw new Exception("[DEBUG] non-ascii chars not implemented yet");
      } else {
	state.charSet = jsonCharSetMap[state.c];
	//if(printTestInfo)
	//writefln("[DEBUG] c = '%s' (CharSet=%s) (Context=%s)", escape(c), state.charSet, state.currentContextDebugName);
	state.next++;
	auto contextFunc = state.currentContextMap[state.charSet];
	contextFunc();
	// state.next now points to state.next characer
      }
    }
  }
}

Json[] parseJsonValues(char* start, const char* limit, JsonOptions options = JsonOptions())
  in { assert(start <= limit); } body
{
  version(OneParseJsonAtATime) {
  } else {
    JsonParserState stateBufferOnStack;
    state = &stateBufferOnStack;
  }

  state.options = options;
  state.next = start;
  state.limit = cast(char*)limit;
  state.lastLineStart = start;
  state.lineNumber = 1;
  state.rootValues = appender!(Json[])();
  state.currentContext.setRootContext();
  
  setRootContext();
  parseStateMachine();
      
  if(!state.currentContext.atRootContext()) {
    throw new JsonException(JsonException.Type.endedInsideStructure, "unexpected end of input");
  }
  if(state.rootValues.data.length == 0) {
    throw new JsonException(JsonException.Type.noJson, "no JSON content found");
  }
  return state.rootValues.data;
}
Json[] parseJsonValues(const(char)[] json, JsonOptions options = JsonOptions())
{
  return parseJsonValues(cast(char*)json.ptr, cast(char*)json.ptr + json.length, options);
}
Json parseJson(char* start, const char* limit, JsonOptions options = JsonOptions())
{
  auto rootValues = parseJsonValues(start, limit, options);
  if(rootValues.length > 1) {
    throw new JsonException(JsonException.Type.multipleRoots, "found multiple root values");
  }
  return rootValues[0];
}
Json parseJson(const(char)[] json, JsonOptions options = JsonOptions())
{
  return parseJson(cast(char*)json.ptr, cast(char*)json.ptr + json.length, options);
}

unittest
{
  JsonOptions options;
  void setLenient()
  {
    if(printTestInfo)
      writeln("[DEBUG] LenientJson: ON");
    options.lenient = true;
  }
  void unsetLenient()
  {
    if(printTestInfo)
      writeln("[DEBUG] LenientJson: OFF");
    options.lenient = false;
  }

  char[16] buffer;
  
  void testError(JsonException.Type expectedError, const(char)[] s, size_t testLine = __LINE__)
  {
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escape(s));
    }
    try {
      auto json = parseJson(cast(char*)s.ptr, s.ptr + s.length, options);
      assert(0, format("Expected exception '%s' but did not get one. (testline %s) JSON='%s'",
		       expectedError, testLine, escape(s)));
    } catch(JsonException e) {
      assert(expectedError == e.type, format("Expected error '%s' but got '%s' (testline %s)",
					     expectedError, e.type, testLine));
      if(printTestInfo) {
	writefln("[TEST-DEBUG] got expected error '%s' from '%s'", e.type, escape(s));
      }
    }
  }
  
  testError(JsonException.Type.noJson, "");
  testError(JsonException.Type.noJson, " \t\r\n");

  for(char c = 0; c < ' '; c++) {
    if(jsonCharSetMap[c] == JsonCharSet.asciiControl) {
      buffer[0] = cast(char)c;
      testError(JsonException.Type.controlChar, buffer[0..1]);
    }
  }

  foreach(i; 0..2) {
    testError(JsonException.Type.endedInsideStructure, "{");
    testError(JsonException.Type.endedInsideStructure, "[");

    testError(JsonException.Type.unexpectedChar, "}");
    testError(JsonException.Type.unexpectedChar, "]");
    testError(JsonException.Type.unexpectedChar, ":");
    testError(JsonException.Type.unexpectedChar, ",");
    testError(JsonException.Type.unexpectedChar, "{]");
    testError(JsonException.Type.unexpectedChar, "[}");
    testError(JsonException.Type.unexpectedChar, "[,");
    testError(JsonException.Type.unexpectedChar, "{,");

    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\t");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\n");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\r");

    testError(JsonException.Type.multipleRoots, "null null");
    testError(JsonException.Type.multipleRoots, "true false");
    testError(JsonException.Type.multipleRoots, `"hey" null`);
    setLenient();
  }
  unsetLenient();

  setLenient();
  testError(JsonException.Type.keywordAsKey, `{null`);
  testError(JsonException.Type.keywordAsKey, `{true`);
  testError(JsonException.Type.keywordAsKey, `{false`);
  unsetLenient();

  void test(const(char)[] s, Json expectedValue)
  {
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escape(s));
    }
    auto json = parseJson(cast(char*)s.ptr, s.ptr + s.length, options);
    if(!expectedValue.equals(json)) {
      writefln("Expected: %s", expectedValue);
      writefln("Actual  : %s", json);
      stdout.flush();
      assert(0);
    }
  }
  void testValues(const(char)[] s, Json[] expectedValues)
  {
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escape(s));
    }
    auto jsonValues = parseJsonValues(cast(char*)s.ptr, s.ptr + s.length, options);
    foreach(i, jsonValue; jsonValues) {
      auto expectedValue = expectedValues[i];
      if(!expectedValue.equals(jsonValue)) {
	writefln("Expected: %s", expectedValues);
	writefln("Actual  : %s", jsonValues);
	stdout.flush();
	assert(0);
      }
    }
  }

  foreach(i; 0..2) {
    // Keywords
    test(`null`, Json.null_);
    test(`true`, Json(true));
    test(`false`, Json(false));
  
    // Numbers
    test(`0`, Json(0));
    test(`-0`, Json(0));
    test(`1`, Json(1));
    test(`-1`, Json(-1));
    test(`0.1234`, Json(0.1234));
    test(`123.4E-3`, Json(0.1234));
    test(`123.4E-3`, Json(0.1234));
    test(`1234567890123456789012345678901234567890`, Json(BigInt("1234567890123456789012345678901234567890")));
    test(`123.4E-9999999999999999999`, Json.hugeNumber(`123.4E-9999999999999999999`));

    // Strings that are Keywords
    test(`"null"`, Json("null"));
    test(`"true"`, Json("true"));
    test(`"false"`, Json("false"));

    // Strings
    test(`""`, Json(""));
    test(`"a"`, Json("a"));
    test(`"ab"`, Json("ab"));
    test(`"hello, world"`, Json("hello, world"));

    // Arrays
    test(`[]`, Json(cast(Json[])[]));
    test(`[null]`, Json([Json.null_]));
    test(`[true]`, Json([Json(true)]));
    test(`[false]`, Json([Json(false)]));
    test(`[""]`, Json([Json("")]));
    test(`["a"]`, Json([Json("a")]));
    test(`["ab"]`, Json([Json("ab")]));

    test(`[null,null]`, Json([Json.null_, Json.null_]));
    test(`[false,true,null,false]`, Json([Json(false), Json(true), Json.null_, Json(false)]));

    test(`["null","false","true"]`, Json([Json("null"),Json("false"),Json("true")]));

    test(`["a","b"]`, Json([Json("a"),Json("b")]));
    test(`["abc",false,"hello"]`, Json([Json("abc"),Json(false),Json("hello")]));

    // Objects
    Json[string] emptyMap;
    test(`{}`, Json(emptyMap));

    test(`{"name":null}`, Json(["name":Json.null_]));
    test(`{"name":true}`, Json(["name":Json(true)]));
    test(`{"name":false}`, Json(["name":Json(false)]));

    test(`{"v":"null"}`, Json(["v":Json("null")]));
    test(`{"v":"true"}`, Json(["v":Json("true")]));
    test(`{"v":"false"}`, Json(["v":Json("false")]));
    test(`{"null":null}`, Json(["null":Json.null_]));
    test(`{"true":false}`, Json(["true":Json(false)]));
    test(`{"false":"hello"}`, Json(["false":Json("hello")]));

    // Nested structures
    test(`[0,[1,2]]`, Json([Json(0),Json([Json(1),Json(2)])]));

    test(`{"1":{"2":"3"}}`, Json(["1":Json(["2":Json("3")])]));

    test(`[
    [1,2,3,4],
    ["a", "b", [1,2,3]]
]`, Json([
	  Json([Json(1),Json(2),Json(3),Json(4)]),
	  Json([Json("a"),Json("b"),Json([Json(1),Json(2),Json(3)])])
	  ]));

    test(`
{
    "key":182993,
    "key2":"value2",
    "key3":null,
    "key4":["hello","is","this","working"],
    "key5":{"another":false}
}`, Json([
	  "key" : Json(182993),
	  "key2" : Json("value2"),
	  "key3" : Json.null_,
	  "key4" : Json([Json("hello"),Json("is"),Json("this"),Json("working")]),
	  "key5" : Json(["another":Json(false)])
	  ]));

    setLenient();
  }
  unsetLenient();
  
  setLenient();
  test(`[a]`, Json([Json("a")]));
  test(`[abc,null_]`, Json([Json("abc"),Json("null_")]));

  unsetLenient();
  testError(JsonException.Type.unexpectedChar, `[a]`);
  testError(JsonException.Type.unexpectedChar, `[abc,null_]`);

  // Unquoted Strings
  {
    auto testStrings = ["a", "ab", "hello", "null_", "true_", "false_",
			"1e", "1.0a", "1a", "4893.0e9_"];
    setLenient();
    foreach(testString; testStrings) {
      test(testString, Json(testString));
    }
    unsetLenient();
    foreach(testString; testStrings) {
      testError(JsonException.Type.unexpectedChar, testString);
    }
  }
  // Trailing Commas
  {
    setLenient();

    test(`[1,]`, Json([Json(1)]));
    test(`[1,2,]`, Json([Json(1),Json(2)]));
    test(`{"a":null,}`, Json(["a":Json.null_]));
    test(`{"a":null,"b":0,}`, Json(["a":Json.null_,"b":Json(0)]));
    
    unsetLenient();

    testError(JsonException.Type.unexpectedChar, "[1,]");
    testError(JsonException.Type.unexpectedChar, "[1,2,]");
    testError(JsonException.Type.unexpectedChar, `{"a":null,}`);
    testError(JsonException.Type.unexpectedChar, `{"a":null,"b":0,}`);
  }
  // Multiple Roots
  {
    testValues(`null true false`, [Json.null_, Json(true), Json(false)]);
    testValues(`1 2 3 {}[]"hello"`, [Json(1),Json(2),Json(3),Json.emptyObject,Json.emptyArray,Json("hello")]);
  }
}



version(unittest) {
immutable string[] escapeTable =
  [
   "\\0"  ,
   "\\x01",
   "\\x02",
   "\\x03",
   "\\x04",
   "\\x05",
   "\\x06",
   "\\a",  // Bell
   "\\b",  // Backspace
   "\\t",
   "\\n",
   "\\v",  // Vertical tab
   "\\f",  // Form feed
   "\\r",
   "\\x0E",
   "\\x0F",
   "\\x10",
   "\\x11",
   "\\x12",
   "\\x13",
   "\\x14",
   "\\x15",
   "\\x16",
   "\\x17",
   "\\x18",
   "\\x19",
   "\\x1A",
   "\\x1B",
   "\\x1C",
   "\\x1D",
   "\\x1E",
   "\\x1F",
   " ", //
   "!", //
   "\"", //
   "#", //
   "$", //
   "%", //
   "&", //
   "'", //
   "(", //
   ")", //
   "*", //
   "+", //
   ",", //
   "-", //
   ".", //
   "/", //
   "0", //
   "1", //
   "2", //
   "3", //
   "4", //
   "5", //
   "6", //
   "7", //
   "8", //
   "9", //
   ":", //
   ";", //
   "<", //
   "=", //
   ">", //
   "?", //
   "@", //
   "A", //
   "B", //
   "C", //
   "D", //
   "E", //
   "F", //
   "G", //
   "H", //
   "I", //
   "J", //
   "K", //
   "L", //
   "M", //
   "N", //
   "O", //
   "P", //
   "Q", //
   "R", //
   "S", //
   "T", //
   "U", //
   "V", //
   "W", //
   "X", //
   "Y", //
   "Z", //
   "[", //
   "\\", //
   "]", //
   "^", //
   "_", //
   "`", //
   "a", //
   "b", //
   "c", //
   "d", //
   "e", //
   "f", //
   "g", //
   "h", //
   "i", //
   "j", //
   "k", //
   "l", //
   "m", //
   "n", //
   "o", //
   "p", //
   "q", //
   "r", //
   "s", //
   "t", //
   "u", //
   "v", //
   "w", //
   "x", //
   "y", //
   "z", //
   "{", //
   "|", //
   "}", //
   "~", //
   "\x7F", //
   "\x80", "\x81", "\x82", "\x83", "\x84", "\x85", "\x86", "\x87", "\x88", "\x89", "\x8A", "\x8B", "\x8C", "\x8D", "\x8E", "\x8F",
   "\x90", "\x91", "\x92", "\x93", "\x94", "\x95", "\x96", "\x97", "\x98", "\x99", "\x9A", "\x9B", "\x9C", "\x9D", "\x9E", "\x9F",
   "\xA0", "\xA1", "\xA2", "\xA3", "\xA4", "\xA5", "\xA6", "\xA7", "\xA8", "\xA9", "\xAA", "\xAB", "\xAC", "\xAD", "\xAE", "\xAF",
   "\xB0", "\xB1", "\xB2", "\xB3", "\xB4", "\xB5", "\xB6", "\xB7", "\xB8", "\xB9", "\xBA", "\xBB", "\xBC", "\xBD", "\xBE", "\xBF",
   "\xC0", "\xC1", "\xC2", "\xC3", "\xC4", "\xC5", "\xC6", "\xC7", "\xC8", "\xC9", "\xCA", "\xCB", "\xCC", "\xCD", "\xCE", "\xCF",
   "\xD0", "\xD1", "\xD2", "\xD3", "\xD4", "\xD5", "\xD6", "\xD7", "\xD8", "\xD9", "\xDA", "\xDB", "\xDC", "\xDD", "\xDE", "\xDF",
   "\xE0", "\xE1", "\xE2", "\xE3", "\xE4", "\xE5", "\xE6", "\xE7", "\xE8", "\xE9", "\xEA", "\xEB", "\xEC", "\xED", "\xEE", "\xEF",
   "\xF0", "\xF1", "\xF2", "\xF3", "\xF4", "\xF5", "\xF6", "\xF7", "\xF8", "\xF9", "\xFA", "\xFB", "\xFC", "\xFD", "\xFE", "\xFF",
   ];
string escape(char c) pure {
  return escapeTable[c];
}
string escape(dchar c) pure {
  import std.conv : to;
  return (c < escapeTable.length) ? escapeTable[c] : to!string(c);
}
inout(char)[] escape(inout(char)[] str) pure {
  size_t newLength = 0;

  foreach(c; str) {
    auto escapedChar = escape(c);
    newLength += escapedChar.length;
  }

  if(newLength == str.length)
    return str;

  char[] newString = new char[newLength];
  char* ptr = newString.ptr;
  foreach(c; str) {
    auto escapedChar = escape(c);
    ptr[0..escapedChar.length] = escapedChar[];
    ptr += escapedChar.length;
  }

  return cast(inout(char)[])newString;
}
}
