/* TODO
--------------------------------------------------------------------------------
* !!!! Handle overflows for long doubles when converting string to number in Json constructor
* Implement JsonExceptionMessage.create
* Implement non-ascii chars
* Implement error messages with line/col numbers and filenames
   - Already setup to do this, the linenumber is kept track of and the column
     number can be calculated by subtracting the next pointer from lineStart
* Implement comments
* Implement UTF16 & UTF32
   - Also handle the BOM (ByteOrderMark)
* Implement JSON encoding (mostly just escaping strings)
* json.reflection module?
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
module json_firsttry;

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
--------------------------------------------------------------------------------
The "ParseJsonNoGC" version adds the @nogc attribute to the parseJson functions

*/
import std.stdio  : write, writeln, writefln, stdout;
import std.string : format;
import std.bigint;
import std.array : appender, Appender;

public import std.typecons : Flag;

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
    endedInsideQuote,
    unexpectedChar, // Encountered a char unexpectedly
    tabNewlineCRInsideQuotes,
    controlCharInsideQuotes,
    invalidEscapeChar,
    invalidKey, // A non-string was used as an object key
    notAKeywordOrNumber // For strict json, found an unquoted string that isn't a keyword or number
  }
  Type type;
  this(Type type, string msg, string file = __FILE__, size_t line = __LINE__,
       Throwable next = null) pure nothrow @safe
  {
    this.type = type;
    super(msg, file, line, next);
  }
}
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

  void toString(scope void delegate(const(char)[]) sink) const
  {
    import std.format : formattedWrite;
    
    final switch(info & 0b111) {
    case JsonType.bool_:
      sink(payload.bool_ ? "true" : "false");
      return;
    case JsonType.number:
      final switch((info >> 3) & 0b111) {
      case NumberType.long_:
	sink.formattedWrite("%s", payload.long_);
	return;
      case NumberType.double_:
	sink.formattedWrite("%s", payload.double_);
	// TODO: make this better
	if(payload.double_ % 1 == 0) {
	  sink(".0");
	}
	return;
      case NumberType.bigInt:
	sink.formattedWrite("%s", payload.bigInt);
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
  this(const(char[]) numberString, size_t intPartLength) pure
  {
    import std.conv : to, ConvException;

    static immutable maxNegativeLongString  =  "-9223372036854775808";
    static immutable maxLongString          =   "9223372036854775807";

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
  // todo: find out why can't you iterate over a map with nothrow?
  bool equals(Json other) const pure @nogc
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
      if(this.payload.array is null)
	return other.payload.array is null;
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
	auto otherValuePtr = key in other.payload.object;
	if(otherValuePtr is null || !value.equals(*otherValuePtr))
	  return false;
      }
      return true;
    }
  }
  this(BigInt value) pure nothrow {
    this.info = NumberType.bigInt << 3 | JsonType.number;
    this.payload.bigInt = value;
  }
  this(ulong value) pure nothrow {
    this.info = NumberType.bigInt << 3 | JsonType.number;
    this.payload.bigInt = value;
  }
  @property static Json emptyArray() pure nothrow @nogc {
    // The unusual cast of a value to a pointer
    // differentiates a null array from an empty array without
    // having to allocate a new array
    return Json((cast(Json*)1)[0..0]);
  }
  @property static Json null_() pure nothrow @nogc @safe {
    return Json(cast(Json[string])null);
  }
  @property static Json emptyObject() pure nothrow @nogc @safe {
    Json[string] map;
    return Json(map);
  }
  /// ditto
  this(bool value) pure nothrow @nogc @safe {
    this.info = JsonType.bool_;
    this.payload.bool_ = value;
  }
  /// ditto
  this(int value) pure nothrow @nogc @safe {
    this.info = NumberType.long_ << 3 | JsonType.number;
    this.payload.long_ = value;
  }
  /// ditto
  this(uint value) pure nothrow @nogc @safe {
    this.info = NumberType.long_ << 3 | JsonType.number;
    this.payload.long_ = value;
  }
  /// ditto
  this(long value) pure nothrow @nogc @safe {
    this.info = NumberType.long_ << 3 | JsonType.number;
    this.payload.long_ = value;
  }
  /// ditto
  this(double value) pure nothrow @nogc @safe {
    this.info = NumberType.double_ << 3 | JsonType.number;
    this.payload.double_ = value;
  }
  /// ditto
  this(string value) pure nothrow @nogc @safe {
    this.info = JsonType.string_;
    this.payload.string_ = value;
  }
  /// ditto
  this(Json[] value) pure nothrow @nogc @safe {
    this.info = JsonType.array;
    this.payload.array = value;
  }
  this(Appender!(Json[]) value) pure nothrow @nogc {
    this.info = JsonType.array;
    this.payload.array = (value.data.length == 0) ?
      (cast(Json*)1)[0..0] : // This differentates a null array from an
                             // empty array without allocating memory
      value.data;
  }
  /// ditto
  this(Json[string] value) pure nothrow @nogc @safe {
    this.info = JsonType.object;
    this.payload.object = value;
  }
  private this (ubyte info, Payload payload) pure nothrow @nogc @safe {
    this.info = info;
    this.payload = payload;
  }
  static Json hugeNumber(string number) pure nothrow @nogc @safe
  {
    //return Json(cast(ubyte)(Json.NumberType.string_ << 3 | JsonType.number), Payload(cast(string)number));
    Json json;
    json.setupAsHugeNumber(number);
    return json;
  }
  void setupAsHugeNumber(string number) pure nothrow @nogc @safe
  {
    info = Json.NumberType.string_ << 3 | JsonType.number;
    payload.string_ = cast(string)number;
  }
  bool isObject() const pure nothrow @nogc @safe
  {
    return this.info == JsonType.object;
  }
  void setupAsObject() pure nothrow @nogc @safe
  {
    this.info = JsonType.object;
  }
  bool isArray() const pure nothrow @nogc @safe
  {
    return this.info == JsonType.array;
  }
  void setupAsArray() pure nothrow @nogc @safe
  {
    this.info = JsonType.array;
  }
  bool isString() const pure nothrow @nogc @safe
  {
    return this.info == JsonType.string_;
  }
  bool opEquals(ref Json other) const pure nothrow @nogc @safe
  {
    assert(0, "Do not compare Json values using '==', instead, use value.equals(otherValue)");
  }
  @property string typeString() const pure nothrow @nogc @safe
  {
    final switch(info & 0b111) {
    case JsonType.bool_:       return "bool";
    case JsonType.number:
      final switch((info >> 3) & 0b111) {
      case NumberType.long_  : return "number:long";
      case NumberType.double_: return "number:double";
      case NumberType.bigInt : return "number:bigint";
      case NumberType.string_: return "number:string";
      }
    case JsonType.string_:     return "string";
    case JsonType.array:       return "array";
    case JsonType.object:      return "object";
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

/**
Given a raw memory area $(D chunk), constructs an object of $(D class)
type $(D T) at that address. The constructor is passed the arguments
$(D Args). The $(D chunk) must be as least as large as $(D T) needs
and should have an alignment multiple of $(D T)'s alignment. (The size
of a $(D class) instance is obtained by using $(D
__traits(classInstanceSize, T))).

This function can be $(D @trusted) if the corresponding constructor of
$(D T) is $(D @safe).

Returns: A pointer to the newly constructed object.
 */
T emplace(T, Args...)(void* chunk, auto ref Args args) pure nothrow @nogc
  if (is(T == class)) in { assert((cast(size_t)chunk) % classInstanceAlignment!T == 0); } body
{
  enum classSize = __traits(classInstanceSize, T);
  
  // Initialize the object in its pre-ctor state
  (cast(byte*)chunk)[0 .. classSize] = typeid(T).init[];

  // Call the ctor if any
  static if (is(typeof((cast(T)chunk).__ctor(args)))) {
    // T defines a genuine constructor accepting args
    // Go the classic route: write .init first, then call ctor
    (cast(T)chunk).__ctor(args);
  } else static assert(args.length == 0 && !is(typeof(&T.__ctor)),
		  "Don't know how to initialize an object of type "
		  ~ T.stringof ~ " with arguments " ~ Args.stringof);
  
  return cast(T)chunk;
}

struct MemoryInfo
{
  ubyte alignment;
  ushort instanceSize;
}
import std.traits : classInstanceAlignment;
template memoryInfo(T)
{
  enum MemoryInfo memoryInfo = MemoryInfo
    (classInstanceAlignment!T, __traits(classInstanceSize, T));
}

//alias AllowGC = Flag!"AllowGC";
alias OnlyUtf8 = Flag!"OnlyUtf8";

interface JsonAllocator
{
  // Used so the parser can create memory for the allocator on the stack
  MemoryInfo objectAllocatorInfo() pure nothrow @safe @nogc;
  MemoryInfo arrayAllocatorInfo() pure nothrow @safe @nogc;

  JsonObjectBuilder newObject(void* classMemory) @nogc;
  JsonArrayBuilder newArray(void* classMemory) @nogc;
}
interface JsonObjectBuilder
{
  version(ParseJsonNoGC) {
    void add(string key, Json value) @nogc;
    Json[string] finishObject() @nogc;
  } else {
    void add(string key, Json value);
    Json[string] finishObject();
  }
}
interface JsonArrayBuilder
{
  void add(Json value);
  Json[] finishArray();
}

version(ParseJsonNoGC) {
  class MallocJsonAllocator : JsonAllocator
  {
    MemoryInfo objectAllocatorInfo() pure nothrow @safe @nogc {
      return memoryInfo!MallocJsonObjectBuilder;
    }
    MemoryInfo arrayAllocatorInfo() pure nothrow @safe @nogc {
      return memoryInfo!MallocJsonArrayBuilder;
    }
    JsonObjectBuilder newObject(void* classMemory) @nogc {
      return emplace!MallocJsonObjectBuilder(classMemory);
    }
    JsonArrayBuilder newArray(void* classMemory) @nogc {
      return emplace!MallocJsonArrayBuilder(classMemory);
    }
  }
  class MallocJsonArrayBuilder : JsonArrayBuilder
  {
    void add(Json value) @nogc {
      assert(0, "MallocJsonArrayBuilder not implemented");
    }
    Json[] finishArray() @nogc {
      assert(0, "MallocJsonArrayBuilder not implemented");
    }
  }
  class MallocJsonObjectBuilder : JsonObjectBuilder
  {
    Json[string] map;
    void add(string key, Json value) @nogc {
      assert(0, "MallocJsonObjectBuilder not implemented");
    }
    Json[string] finishObject() @nogc {
      assert(0, "MallocJsonObjectBuilder not implemented");
    }
  }
} else {
  class GCJsonAllocator : JsonAllocator
  {
    MemoryInfo objectAllocatorInfo() pure nothrow @safe @nogc {
      return memoryInfo!GCJsonObjectBuilder;
    }
    MemoryInfo arrayAllocatorInfo() pure nothrow @safe @nogc {
      return memoryInfo!GCJsonArrayBuilder;
    }
    JsonObjectBuilder newObject(void* classMemory) @nogc {
      return emplace!GCJsonObjectBuilder(classMemory);
    }
    JsonArrayBuilder newArray(void* classMemory) @nogc {
      return emplace!GCJsonArrayBuilder(classMemory);
    }
  }
  class GCJsonArrayBuilder : JsonArrayBuilder
  {
    Appender!(Json[]) builder = appender!(Json[]);
    void add(Json value) {
      builder.put(value);
    }
    Json[] finishArray() {
      return builder.data;
    }
  }
  class GCJsonObjectBuilder : JsonObjectBuilder
  {
    Json[string] map;
    void add(string key, Json value) {
      map[key] = value;
    }
    Json[string] finishObject() {
      return map;
    }
  }
}
struct JsonOptions
{
  ubyte flags;
  JsonAllocator allocator;
  @property bool lenient() const pure nothrow @safe @nogc { return (flags & 0x01) != 0;}
  @property void lenient(bool v) pure nothrow @safe @nogc { if (v) flags |= 0x01;else flags &= ~0x01;}
}

struct JsonExceptionMessage
{
  string format;
  char c0;
  string s0;
  Json j0;
  // TODO: implement this
  // Replaces %c0 with this.c0
  //          %s0 with this.s0
  //          %j0 with this.j0.toString()
  string create()
  {
    return format;
  }
}

//
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TRY MAKING OneParseJsonAtATime version use static variables
// and make the other version use instance variables
// This means removing state.<var> from every state variable
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
struct JsonParserState
{
  JsonOptions options;

  char* next;
  char c;
  char* limit;

  JsonCharSet charSet;
  debug {
    string currentContextDebugName;
  }
  immutable(void function())[] currentContextMap;

  char* lastLineStart;
  LineNumber lineNumber;

  //-------------------------------
  bool throwing; // set to true when throwing an exception
  JsonException.Type exceptionType;
  JsonExceptionMessage exceptionMessage;
  string exceptionFile;
  size_t exceptionLine;
  Throwable exceptionNext;
  //-------------------------------

  Appender!(Json[]) rootValues;
  ContainerContext containerContext;
}
private
{
  struct ContainerContext
  {
    immutable(ContainerMethods)* vtable;
    bool containerEnded;

    union Structure {
      ObjectContext object;
      ArrayContext array;
    }
    Structure structure;
    alias structure this;

    void setRootContext() pure nothrow @safe @nogc {
      vtable = null;
    }
    bool atRootContext() const pure nothrow @safe @nogc {
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
    private __gshared JsonParserState state;
  } else {
    private JsonParserState* state;
  }
  
  struct ContainerMethods
  {
    void function(string key) setKey;
    void function(ref ContainerContext context, Json value) addValue;
    bool function() isEmpty;
    void function() setCommaContext;
  }
  void setObjectKey(string key) nothrow @nogc
  {
    assert(state.containerContext.object.currentKey is null);
    state.containerContext.object.currentKey = key;
  }
  void invalidSetKey(string key) pure nothrow @safe @nogc
  {
    assert(0, "code bug: cannot call setKey on a non-object container");
  }
  void addObjectValue(ref ContainerContext context, Json value) pure
  {
    assert(context.object.currentKey !is null);
    context.object.map[context.object.currentKey] = value;
    context.object.currentKey = null; // NOTE: only for debugging purposes
  }
  void addArrayValue(ref ContainerContext context, Json value) {
    context.array.values.put(value);
  }
  void invalidAddValue(ref ContainerContext context, Json value) {
    assert(0, "code bug: cannot call addValue on a non-object/array value");
  }
  bool objectIsEmpty() {
    return state.containerContext.object.map.length == 0;
  }
  bool arrayIsEmpty() {
    return state.containerContext.array.values.data.length == 0;
  }
  bool invalidIsEmpty() {
    assert(0, "code bug: cannot call isEmpty on a non-object/array value");;
  }
  void invalidSetCommaContext() {
    assert(0, "code bug: cannot call setCommmaContext on a non-object/array value");;
  }
  enum JsonCharSet : ubyte {
    other          =  0, // (default) Any ascii character that is not in another set 
    notAscii       =  1, // Any character larger then 127 (> 0x7F)
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
  immutable JsonCharSet[JsonCharSetLookupLength] jsonCharSetMap =
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
}

/**
   Replaces any character within the given string by the string in the given escapeTable.
   If quoted is true, it will also replace " and \ with \" and \\ respectively.
   TODO: support non-ascii chars by skipping multibyte utf8 characters
*/
inout(char)[] escapeStringImpl(immutable string[] escapeTable, bool quoted)(inout(char*) start, const char* limit) pure
{
  char c;
  char* next = cast(char*)start;

  size_t extra = 0;

  //debug writefln("escape '%s'", next[0..limit-next]);
  while(next < limit) {
    c = *next;
    if(c > 127) {
      assert(0, "non-ascii character are not implemented");
    } else {
      if(c < escapeTable.length) {
	extra += escapeTable[c].length - 1;
      } else {
	static if(quoted) {
	  if(c == '"' || c == '\\') {
	    extra += 1;
	  }
	}
      }
      next++;
    }
  }

  if(extra == 0) return start[0..limit-start];
  char[] newString = new char[limit-start + extra];
  
  next = cast(char*)start;
  char* newStringPtr = newString.ptr;

  while(true) {
    c = *next;
    if(c > 127) {
      assert(0, "non-ascii character are not implemented");
    } else {
      if(c < escapeTable.length) {
	auto escapeString = escapeTable[c];
	newStringPtr[0..escapeString.length] = escapeString[];
	newStringPtr += escapeString.length;
      } else{
	static if(quoted) {
	  if(c == '"' || c == '\\') {
	    *newStringPtr = '\\';
	    newStringPtr++;
	  }
	}
	*newStringPtr = c;
	newStringPtr++;
      }
      next++;
      if(next >= limit)
	break;
    }
  }

  assert(newStringPtr == newString.ptr + newString.length,
	 format("off by %s", (cast(ptrdiff_t)(newStringPtr - newString.ptr)) - cast(ptrdiff_t)newString.length));
  
  return newString;
}
/// ditto
inout(char)[] escapeString(immutable string[] escapeTable,bool quoted)(inout(char)[] str)
{
  return escapeStringImpl!(escapeTable,quoted)(str.ptr, str.ptr + str.length);
}

static immutable string[] asciiControlJsonEscape =
  [
   `\u0000`,`\u0001`,`\u0002`,`\u0003`,`\u0004`,`\u0005`,
   `\u0006`,`\u0007`,`\b`    ,`\t`    ,`\n`    ,`\u000B`,
   `\f`    ,`\r`    ,`\u000E`,`\u000F`,`\u0010`,`\u0011`,
   `\u0012`,`\u0013`,`\u0014`,`\u0015`,`\u0016`,`\u0017`,
   `\u0018`,`\u0019`,`\u001A`,`\u001B`,`\u001C`,`\u001D`,
   `\u001E`,`\u001F`];
alias jsonEscapeString = escapeString!(asciiControlJsonEscape,true);

///
unittest
{
  assert("" == jsonEscapeString(""));
  assert("a" == jsonEscapeString("a"));
  assert("hello" == jsonEscapeString("hello"));

  assert(`\\\"` == jsonEscapeString(`\"`));
  assert(`hello\nnextline` == jsonEscapeString("hello\nnextline"));

  assert(`\u0000\b\f\n\r\t` == jsonEscapeString("\0\b\f\n\r\t"));
}
unittest
{
  assert(`\u0001` == jsonEscapeString("\x01"));
  assert(`\u0002` == jsonEscapeString("\x02"));
  assert(`\u0003` == jsonEscapeString("\x03"));
  assert(`\u0004` == jsonEscapeString("\x04"));
  assert(`\u0005` == jsonEscapeString("\x05"));
  assert(`\u0006` == jsonEscapeString("\x06"));
  assert(`\u0007` == jsonEscapeString("\x07"));
  assert(`\b`     == jsonEscapeString("\x08"));
  assert(`\t`     == jsonEscapeString("\x09"));
  assert(`\n`     == jsonEscapeString("\x0A"));
  assert(`\u000B` == jsonEscapeString("\x0B"));
  assert(`\f`     == jsonEscapeString("\x0C"));
  assert(`\r`     == jsonEscapeString("\x0D"));
  assert(`\u000E` == jsonEscapeString("\x0E"));
  assert(`\u000F` == jsonEscapeString("\x0F"));
  assert(`\u0010` == jsonEscapeString("\x10"));
  assert(`\u0011` == jsonEscapeString("\x11"));
  assert(`\u0012` == jsonEscapeString("\x12"));
  assert(`\u0013` == jsonEscapeString("\x13"));
  assert(`\u0014` == jsonEscapeString("\x14"));
  assert(`\u0015` == jsonEscapeString("\x15"));
  assert(`\u0016` == jsonEscapeString("\x16"));
  assert(`\u0017` == jsonEscapeString("\x17"));
  assert(`\u0018` == jsonEscapeString("\x18"));
  assert(`\u0019` == jsonEscapeString("\x19"));
  assert(`\u001A` == jsonEscapeString("\x1A"));
  assert(`\u001B` == jsonEscapeString("\x1B"));
  assert(`\u001C` == jsonEscapeString("\x1C"));
  assert(`\u001D` == jsonEscapeString("\x1D"));
  assert(`\u001E` == jsonEscapeString("\x1E"));
  assert(`\u001F` == jsonEscapeString("\x1F"));
}

version(unittest)
{
  static immutable string[] asciiControlDefaultEscape =
    [
     `\0`  ,`\x01`,`\x02`,`\x03`,`\x04`,`\x05`,
     `\x06`,`\x07`,`\b`  ,`\t`  ,`\n`  ,`\x0B`,
     `\f`  ,`\r`  ,`\x0E`,`\x0F`,`\x10`,`\x11`,
     `\x12`,`\x13`,`\x14`,`\x15`,`\x16`,`\x17`,
     `\x18`,`\x19`,`\x1A`,`\x1B`,`\x1C`,`\x1D`,
     `\x1E`,`\x1F`];
  alias escapeForTest = escapeString!(asciiControlDefaultEscape,false);
}

private template JsonParser(OnlyUtf8 onlyUtf8 = OnlyUtf8.yes)
{
  immutable ContainerMethods objectContainerMethods =
    ContainerMethods(&setObjectKey, &addObjectValue, &objectIsEmpty, &setObjectCommaContext);
  immutable ContainerMethods arrayContainerMethods =
    ContainerMethods(&invalidSetKey, &addArrayValue, &arrayIsEmpty, &setArrayCommaContext);
  immutable ContainerMethods valueContainerMethods =
    ContainerMethods(&invalidSetKey, &invalidAddValue, &invalidIsEmpty, &invalidSetCommaContext);

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
  // ReturnState: check if state.throwing is true
  Json tryScanKeywordOrNumberStrictJson()
  {
    if(state.c == 'n') {
      // must be 'null'
      if(state.next + 3 <= state.limit && state.next[0..3] == "ull") {
	state.next += 3;
	if(!nextCouldBePartOfUnquotedString())
	  return Json.null_;
      }
    } else if(state.c == 't') {
      // must be 'true'
      if(state.next + 3 <= state.limit && state.next[0..3] == "rue") {
	state.next += 3;
	if(!nextCouldBePartOfUnquotedString())
	  return Json(true);
      }
    } else if(state.c == 'f') {
      // must be 'false'
      if(state.next + 4 <= state.limit && state.next[0..4] == "alse") {
	state.next += 4;
	if(!nextCouldBePartOfUnquotedString())
	  return Json(false);
      }
    } else {
      state.next--;
      char* startNum = state.next;
      auto intPartLength = tryScanNumber();
      if(intPartLength > 0) {
	return Json(startNum[0..state.next-startNum], intPartLength);
      }
      state.next++; // restore next
    }

    state.exceptionMessage.s0 = "<insert-string-here>";
    setupJsonError(JsonException.Type.notAKeywordOrNumber, "expected a null,true,false,NUM but got '%s0'");
    return Json.null_; // Should be ignored by caller
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
   *  Returns: check state.throwing for error
   *           if no error, next will point to char after quote
   */
  void scanQuotedString()
  {
    while(true) {
      if(state.next >= state.limit) {
	setupJsonError(JsonException.Type.endedInsideQuote, "json ended inside a quoted string");
	return;
      }
      state.c = *state.next;

      if(state.c == '"') {
	state.next++;
	return;
      }

      if(state.c == '\\') {
	state.next++;
	if(state.next >= state.limit)
	  return;
	state.c = *state.next;
	if(state.c == '"') {
	  state.next++;
	} else if(state.c == '/') {
	  state.next++;
	} else {
	  if(state.c < '\\' || state.c > 'u') {
	    state.exceptionMessage.c0 = state.c;
	    setupJsonError(JsonException.Type.invalidEscapeChar, "invalid escape char '%c0'");
	    return;
	  }
	    
	  auto escapeValue = highEscapeTable[state.c - '\\'];
	  if(escapeValue == 0) {
	    state.exceptionMessage.c0 = state.c;
	    setupJsonError(JsonException.Type.invalidEscapeChar, "invalid escape char '%c0'");
	    return;
	  }

	  if(state.c == 'u') {
	    throw new Exception("\\u escape sequences not implemented");
	  } else {
	    state.next++;
	  }
	}
      } else if(state.c <= 0x1F) {
	if(state.c == '\n') {
	  setupJsonError(JsonException.Type.tabNewlineCRInsideQuotes, "found newline '\n' inside quote");
	  return;
	}
	if(state.c == '\t') {
	  setupJsonError(JsonException.Type.tabNewlineCRInsideQuotes, "found tab '\t' inside quote");
	  return;
	}
	if(state.c == '\r') {
	  setupJsonError(JsonException.Type.tabNewlineCRInsideQuotes, "found carriage return '\r' inside quote");
	  return;
	}
	
	state.exceptionMessage.c0 = state.c;
	setupJsonError(JsonException.Type.controlCharInsideQuotes, "found control char '%c0' inside qoutes");
	return;
	
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
    debug state.currentContextDebugName = "root";
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
    debug state.currentContextDebugName = "object_key";
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
    debug state.currentContextDebugName = "object_value";
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
    debug state.currentContextDebugName = "array";
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
    debug state.currentContextDebugName = "object_colon";
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
    debug state.currentContextDebugName = "object_comma";
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
    debug state.currentContextDebugName = "array_comma";
    state.currentContextMap = contextMap;
  }
  void setExceptionContext()
  {
    static immutable void function()[] contextMap =
      [
       JsonCharSet.other          : &stop,
       JsonCharSet.notAscii       : &stop,
       JsonCharSet.spaceTabCR     : &stop,
       JsonCharSet.newline        : &stop,
       JsonCharSet.startObject    : &stop,
       JsonCharSet.endObject      : &stop,
       JsonCharSet.startArray     : &stop,
       JsonCharSet.endArray       : &stop,
       JsonCharSet.nameSeparator  : &stop,
       JsonCharSet.valueSeparator : &stop,
       JsonCharSet.slash          : &stop,
       JsonCharSet.hash           : &stop,
       JsonCharSet.quote          : &stop,
       JsonCharSet.asciiControl   : &stop
       ];
    debug state.currentContextDebugName = "exception";
    state.currentContextMap = contextMap;
  }
  void ignore()
  {
  }
  void stop()
  {
    state.limit = state.next;
  }
  void unexpectedChar()
  {
    state.exceptionMessage.c0 = state.c;
    setupJsonError(JsonException.Type.unexpectedChar, "unexpected char '%c0'");
  }
  void invalidControlChar()
  {
    state.exceptionMessage.c0 = state.c;
    setupJsonError(JsonException.Type.controlChar, "invalid control character '%c0'");
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

    state.containerContext = ContainerContext(&objectContainerMethods);

    setObjectKeyContext();
    parseStateMachine();
    if(state.throwing)
      return;
    if(state.containerContext.containerEnded) {
      state.rootValues.put(Json(state.containerContext.object.map));

      // restore the previous state
      state.limit = saveLimit;
      state.containerContext.setRootContext();
      setRootContext();
    }
  }
  void startRootArray()
  {
    // save the state to the stack
    auto saveLimit = state.limit;
    
    state.containerContext = ContainerContext(&arrayContainerMethods);

    setArrayValueContext();
    parseStateMachine();
    if(state.throwing)
      return;
    if(state.containerContext.containerEnded) {
      state.rootValues.put(Json(state.containerContext.array.values));

      // restore the previous state
      state.limit = saveLimit;
      state.containerContext.setRootContext();
      setRootContext();
    }
  }
  void startObject()
  {
    // save the state to the stack
    auto saveLimit = state.limit;
    auto saveContext = state.containerContext;

    state.containerContext = ContainerContext(&objectContainerMethods);

    setObjectKeyContext();
    parseStateMachine();
    if(state.throwing)
      return;
    if(state.containerContext.containerEnded) {
      saveContext.vtable.addValue(saveContext, Json(state.containerContext.object.map));

      // restore the previous state
      state.limit = saveLimit;
      state.containerContext = saveContext;
      state.containerContext.vtable.setCommaContext();
    }
  }
  void startArray()
  {
    // save the state to the stack
    auto saveLimit = state.limit;
    auto saveContext = state.containerContext;
    state.containerContext = ContainerContext(&arrayContainerMethods);

    setArrayValueContext();
    parseStateMachine();
    if(state.throwing)
      return;
    if(state.containerContext.containerEnded) {
      saveContext.vtable.addValue(saveContext, Json(state.containerContext.array.values));

      // restore the previous state
      state.limit = saveLimit;
      state.containerContext = saveContext;
      state.containerContext.vtable.setCommaContext();
    }
  }
  void endContainerBeforeValue()
  {
    if(!state.options.lenient && !state.containerContext.vtable.isEmpty()) {
      unexpectedChar();
      return;
    }
    state.limit = state.next; // Causes the state machine to pop the stack and return
                              // to the function to end the current containers context
    state.containerContext.containerEnded = true;
  }
  void endContainerBeforeComma()
  {
    state.limit = state.next; // Causes the state machine to pop the stack and return
                              // to the function to end the current containers context
    state.containerContext.containerEnded = true;
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
  void otherRootContext()
  {
    Json value;
    if(state.options.lenient) {
      value = scanNumberOrUnquoted();
    } else {
      value = tryScanKeywordOrNumberStrictJson();
      if(state.throwing)
	return;
    }
    state.rootValues.put(value);
  }
  void otherObjectKeyContext()
  {
    if(!state.options.lenient) {
      unexpectedChar();
      return;
    }

    Json value = scanNumberOrUnquoted();
    if(!value.isString()) {
      state.exceptionMessage.j0 = value;
      state.exceptionMessage.s0 = value.typeString;
      setupJsonError(JsonException.Type.invalidKey, "expected string but got %s0 '%j0'");
      return;
    }
    state.containerContext.vtable.setKey(value.payload.string_);
    setObjectColonContext();
  }

  // TODO: I could combine the next two methods
  void otherObjectValueContext()
  {
    Json value;
    if(state.options.lenient) {
      value = scanNumberOrUnquoted();
    } else {
      value = tryScanKeywordOrNumberStrictJson();
      if(state.throwing)
	return;
    }
    state.containerContext.vtable.addValue(state.containerContext, value);
    setObjectCommaContext();
  }
  void otherArrayContext()
  {
    Json value;
    if(state.options.lenient) {
      value = scanNumberOrUnquoted();
    } else {
      value = tryScanKeywordOrNumberStrictJson();
      if(state.throwing)
	return;
    }
    state.containerContext.vtable.addValue(state.containerContext, value);
    setArrayCommaContext();
  }
  void quoteRootContext()
  {
    char* startOfString = state.next;
    scanQuotedString();
    if(state.throwing)
      return;
    state.rootValues.put(Json(cast(string)(startOfString[0..state.next-startOfString - 1])));
  }
  void quoteObjectKeyContext()
  {
    char* startOfString = state.next;
    scanQuotedString();
    if(state.throwing)
      return;
    state.containerContext.vtable.setKey(cast(string)(startOfString[0..state.next-startOfString - 1]));
    setObjectColonContext();
  }
  void quoteObjectValueContext()
  {
    char* startOfString = state.next;
    scanQuotedString();
    if(state.throwing)
      return;
    state.containerContext.vtable.addValue(state.containerContext, Json(cast(string)(startOfString[0..state.next-startOfString - 1])));
    setObjectCommaContext();
  }
  void quoteArrayContext()
  {
    char* startOfString = state.next;
    scanQuotedString();
    if(state.throwing)
      return;
    state.containerContext.vtable.addValue(state.containerContext, Json(cast(string)(startOfString[0..state.next-startOfString - 1])));
    setArrayCommaContext();
  }
  void notImplemented()
  {
    debug {
      throw new Exception(format("Error: char set '%s' not implemented in '%s' context", state.charSet, state.currentContextDebugName));
    } else {
      throw new Exception(format("Error: char set '%s' not implemented in the current context", state.charSet));
    }
  }
  void setupJsonError(JsonException.Type type, string messageFormat, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
  {
    state.throwing = true;
    state.exceptionType = type;
    state.exceptionMessage.format = messageFormat;
    state.exceptionFile = file;
    state.exceptionLine = line;
    state.exceptionNext = next;
    state.limit = state.next; // Stop the state machine
    setExceptionContext();
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

enum Encoding { utf8, utf16le, utf16be, utf32le, utf32be }
Encoding getEncoding(const char[] data)
{
  return getEncoding(data.ptr, data.ptr + data.length);
}
Encoding getEncoding(const char* start, const char* limit)
{
  // todo: handle BOM
  /*
  Note: that you can tell the encoding of a json file by looking at the first 2 characters.  This is because the first 2 characters must be ascii characters so you can tell if it is UTF-8, UTF-16 or UTF-32
  -----------------------------------
  00 00 00 xx  UTF-32BE
  00 xx 00 xx  UTF-16BE
  xx 00 00 00  UTF-32LE
  xx 00 xx 00  UTF-16LE
  xx xx        UTF-8
  */
  if(limit >= start + 2) {
    if(*start == 0) {
      if(*(start + 1) == 0) {
	// Must be utf32be
	if(limit < start + 4)
	  throw new Exception("unknown encoding, appears to be utf32be but there's less than 4 bytes");
	if(*(start + 2) != 0)
	  throw new Exception("unknown encoding, appeared to be utf32be but then there was a non-zero in the third byte");
	if(*(start + 3) == 0)
	  throw new Exception("unknown encoding, appeared to be utf32be but the fourth byte was zero");
	return Encoding.utf32be;
      }
      // Must be utf16BE
      return Encoding.utf16be;
    }
    if(*(start+1) == 0) {
      if(limit >= start + 4) {
	if(*(start+2) == 0) {
	  // Must be utf32le
	  if(*(start+3) != 0)
	    throw new Exception("unknown encoding, appeared to be utf32le but the fourth byte was not zero");
	  return Encoding.utf32le;
	}
      }
      return Encoding.utf16le;
    }
  }
  return Encoding.utf8;
}
// Examples of how getEncoding works
unittest
{
  assert(Encoding.utf8    == getEncoding("xx"));
  assert(Encoding.utf16le == getEncoding("x\0"));
  assert(Encoding.utf16le == getEncoding("x\0x\0"));
  assert(Encoding.utf32le == getEncoding("x\0\0\0"));
  assert(Encoding.utf16be == getEncoding("\0x"));
  assert(Encoding.utf16be == getEncoding("\0x\0x"));
  assert(Encoding.utf32be == getEncoding("\0\0\0x"));
}

version(ParseJsonNoGC)
{
  @nogc:
}

Json[] parseJsonValues(OnlyUtf8 onlyUtf8 = OnlyUtf8.yes)(char* start, const char* limit, JsonOptions options = JsonOptions())
  in { assert(start <= limit); } body
{
  version(OneParseJsonAtATime) {
  } else {
    JsonParserState stateBufferOnStack;
    state = &stateBufferOnStack;
  }

  // Check encoding
  static if(onlyUtf8 == OnlyUtf8.no) {
    auto encoding = getEncoding(start, limit);
    if(encoding != Encoding.utf8) {
      assert(0, format("%s encoding not supported yet", encoding));
    }
  }

  state.options = options;
  //if(state.options.allocator
  
  state.next = start;
  state.limit = cast(char*)limit;
  state.lastLineStart = start;
  state.lineNumber = 1;
  state.rootValues = appender!(Json[])();
  state.containerContext.setRootContext();

  state.throwing = false;
  
  JsonParser!onlyUtf8.setRootContext();

  JsonParser!onlyUtf8.parseStateMachine();

  if(state.throwing) {
    // throw the exception
    throw new JsonException(state.exceptionType, state.exceptionMessage.create());
  }    
  if(!state.containerContext.atRootContext()) {
    throw new JsonException(JsonException.Type.endedInsideStructure, "unexpected end of input");
  }
  if(state.rootValues.data.length == 0) {
    throw new JsonException(JsonException.Type.noJson, "no JSON content found");
  }
  return state.rootValues.data;
}
Json[] parseJsonValues(OnlyUtf8 onlyUtf8 = OnlyUtf8.yes)(const(char)[] json, JsonOptions options = JsonOptions())
{
  return parseJsonValues!(onlyUtf8)(cast(char*)json.ptr, cast(char*)json.ptr + json.length, options);
}
Json parseJson(OnlyUtf8 onlyUtf8 = OnlyUtf8.yes)(char* start, const char* limit, JsonOptions options = JsonOptions())
{
  auto rootValues = parseJsonValues!(onlyUtf8)(start, limit, options);
  if(rootValues.length > 1) {
    throw new JsonException(JsonException.Type.multipleRoots, "found multiple root values");
  }
  return rootValues[0];
}
Json parseJson(OnlyUtf8 onlyUtf8 = OnlyUtf8.yes)(const(char)[] json, JsonOptions options = JsonOptions())
{
  return parseJson!(onlyUtf8)(cast(char*)json.ptr, cast(char*)json.ptr + json.length, options);
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
  wchar[256] utf16Buffer;
  dchar[256] utf32Buffer;

  void testError(JsonException.Type expectedError, const(char)[] s, size_t testLine = __LINE__)
  {
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escapeForTest(s));
    }
    //UTF8
    try {
      auto json = parseJson(cast(char*)s.ptr, s.ptr + s.length, options);
      assert(0, format("Expected exception '%s' but did not get one. (testline %s) JSON='%s'",
		       expectedError, testLine, escapeForTest(s)));
    } catch(JsonException e) {
      assert(expectedError == e.type, format("Expected error '%s' but got '%s' (testline %s)",
					     expectedError, e.type, testLine));
      if(printTestInfo) {
	writefln("[TEST-DEBUG] got expected error '%s' from '%s'. message '%s'", e.type, escapeForTest(s), e.msg);
      }
    }
    // TODO: Convert to UTF(16/32)(LE/BE) and test again
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

    testError(JsonException.Type.endedInsideQuote, "\"");
    testError(JsonException.Type.endedInsideQuote, "{\"");
    testError(JsonException.Type.endedInsideQuote, "[\"");

    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\t");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\n");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\r");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "{\"\t");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "{\"\n");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "{\"\r");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "[\"\t");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "[\"\n");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "[\"\r");

    
    testError(JsonException.Type.multipleRoots, "null null");
    testError(JsonException.Type.multipleRoots, "true false");
    testError(JsonException.Type.multipleRoots, `"hey" null`);
    setLenient();
  }
  unsetLenient();

  setLenient();
  testError(JsonException.Type.invalidKey, `{null`);
  testError(JsonException.Type.invalidKey, `{true`);
  testError(JsonException.Type.invalidKey, `{false`);
  testError(JsonException.Type.invalidKey, `{0`);
  testError(JsonException.Type.invalidKey, `{1.0`);
  testError(JsonException.Type.invalidKey, `{-0.018e-40`);
  unsetLenient();

  void test(const(char)[] s, Json expectedValue, size_t testLine = __LINE__)
  {
    import std.conv : to;
    
    Json json;
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escapeForTest(s));
    }
    json = parseJson(cast(char*)s.ptr, s.ptr + s.length, options);
    if(!expectedValue.equals(json)) {
      writefln("Expected: %s", expectedValue);
      writefln("Actual  : %s", json);
      stdout.flush();
      assert(0);
    }

    // Generate the JSON using toString and parse it again!
    string gen = to!string(json);
    json = parseJson(cast(char*)gen.ptr, gen.ptr + gen.length, options);
    if(!expectedValue.equals(json)) {
      writefln("OriginalJSON : %s", escapeForTest(s));
      writefln("GeneratedJSON: %s", escapeForTest(gen));
      writefln("Expected: %s", expectedValue);
      writefln("Actual  : %s", json);
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
    //assert(expectedValue.equals(json));
    json = parseJson!(OnlyUtf8.no)(cast(char*)utf16Buffer.ptr, cast(char*)(utf16Buffer.ptr + s.length), options);
    assert(expectedValue.equals(json));
    +/
  }
  void testValues(const(char)[] s, Json[] expectedValues)
  {
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escapeForTest(s));
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
    test(`[]`, Json.emptyArray);
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

    // Multiple Roots
    testValues(`null true false`, [Json.null_, Json(true), Json(false)]);
    testValues(`1 2 3 {}[]"hello"`, [Json(1),Json(2),Json(3),Json.emptyObject,Json.emptyArray,Json("hello")]);

    setLenient();
  }
  unsetLenient();
  
  setLenient();
  test(`[a]`, Json([Json("a")]));
  test(`[null_]`, Json([Json("null_")]));
  test(`[abc,null_]`, Json([Json("abc"),Json("null_")]));

  unsetLenient();
  testError(JsonException.Type.notAKeywordOrNumber, `[a]`);
  testError(JsonException.Type.notAKeywordOrNumber, `[null_]`);
  testError(JsonException.Type.notAKeywordOrNumber, `[abc,null_]`);

  void testValidLenientOnly(string jsonString, Json expectedLenient, JsonException.Type strictError, size_t testLine = __LINE__)
  {
    setLenient();
    test(jsonString, expectedLenient, testLine);
    unsetLenient();
    testError(strictError, jsonString, testLine);
  }

  // Unquoted Strings
  {
    foreach(testString; ["a", "ab", "hello", "null_", "true_", "false_",
			 "1e", "1.0a", "1a", "4893.0e9_"]) {
      testValidLenientOnly(testString, Json(testString), JsonException.Type.notAKeywordOrNumber);
    }
  }

  // Trailing Commas
  {
    testValidLenientOnly(`[1,]`, Json([Json(1)]), JsonException.Type.unexpectedChar);
    testValidLenientOnly(`[1,2,]`, Json([Json(1),Json(2)]), JsonException.Type.unexpectedChar);
    testValidLenientOnly(`{"a":null,}`, Json(["a":Json.null_]), JsonException.Type.unexpectedChar);
    testValidLenientOnly(`{"a":null,"b":0,}`, Json(["a":Json.null_,"b":Json(0)]), JsonException.Type.unexpectedChar);
    testValidLenientOnly(`{"a":null,"b":null,}`, Json(["a":Json.null_,"b":Json.null_]), JsonException.Type.unexpectedChar);
    testValidLenientOnly(`[{"a":null,"b":null,},]`, Json([Json(["a":Json.null_,"b":Json.null_])]), JsonException.Type.unexpectedChar);
  }
}
