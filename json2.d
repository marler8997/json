import std.stdio  : write, writeln, writefln, stdout;
import std.string : format;
import std.array  : Appender, appender;
import std.bigint;

alias LineNumber = uint;
version(unittest)
{
  //__gshared bool printTestInfo = true;
  __gshared bool printTestInfo = false;
}

enum JsonType : ubyte { bool_ = 0, number = 1, string_ = 2, array = 3, object = 4}

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

  /+
  void opAssign(Json rhs)
  {
    this.info = rhs.info;
    this.payload = rhs.payload;
  }
  +/
  void assign(Json rhs) nothrow
  {
    this.info = rhs.info;
    final switch(rhs.info & 0b111) {
    case JsonType.bool_:
      this.payload.bool_ = rhs.payload.bool_;
      return;
    case JsonType.number:
      final switch((rhs.info >> 3) & 0b111) {
      case NumberType.long_:
	this.payload.long_ = rhs.payload.long_;
	return;
      case NumberType.double_:
	this.payload.double_ = rhs.payload.double_;
	return;
      case NumberType.bigInt:
	this.payload.bigInt = rhs.payload.bigInt;
	return;
      case NumberType.string_:
	this.payload.string_ = rhs.payload.string_;
	return;
      }
    case JsonType.string_:
      this.payload.string_ = rhs.payload.string_;
      return;
    case JsonType.array:
      this.payload.array = rhs.payload.array;
      return;
    case JsonType.object:
      this.payload.object = rhs.payload.object;
      return;
    }
  }

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
  void setString(string value) nothrow
  {
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
  void set(Json[] value) nothrow
  {
    this.info = JsonType.array;
    this.payload.array = value;
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
class JsonException : Exception
{
  enum Type {
    notImplemented,
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

struct JsonOptions
{
  ubyte flags;
  //JsonAllocator allocator;
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
struct JsonExceptionPayload
{
  bool throwing; // set to true when throwing an exception
  JsonException.Type type;
  JsonExceptionMessage message;
  string file;
  size_t line;
  Throwable next;

  void throwIfNeeded()
  {
    if(throwing)
      throw new JsonException(type, message.create(),
			      file, line, next);
  }
}
struct JsonParserState
{
  //JsonOptions options;
  //char* next;
  //char c;
  //char* limit;

  //JsonCharSet charSet;
  //debug {
  //string currentContextDebugName;
  //}
  //immutable(void function())[] currentContextMap;


  //ContainerContext containerContext;
}

Json parseJson(char[] json, JsonOptions options = JsonOptions())
{
  return parseJson(json.ptr, json.ptr + json.length, options);
}
Json parseJson(char* start, char* limit, JsonOptions options = JsonOptions())
{
  ParseJsonValueData parserData;
  parserData.options = options;
  parserData.e.throwing = false;

  parserData.lastLineStart = start;
  parserData.lineNumber = 1;

  parserData.startContext = ParserContext.root;
  parserData.currentContainer.setRootContext();
  
  auto next = parseJsonValue(start, limit, parserData);

  parserData.e.throwIfNeeded();

  return parserData.value;
}
/+
Json[] parseJsonValues(char[] str, JsonOptions options = JsonOptions())
{
  return parseJsonValues(str.ptr, str.ptr + str.length, options);
}
+/

struct JsonContainer
{
  immutable(ContainerMethods)* vtable;
  bool ended;

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
struct ContainerMethods
{
  void function(ref JsonContainer this_, string key) nothrow setKey;
  void function(ref JsonContainer this_, Json value) nothrow addValue;
  bool function(ref JsonContainer this_) nothrow isEmpty;
  //void function(ref JsonContainer this_) setCommaContext;
}
void setObjectKey(ref JsonContainer this_, string key) nothrow @nogc
{
  assert(this_.object.currentKey is null);
  this_.object.currentKey = key;
}
void invalidSetKey(ref JsonContainer this_, string key) pure nothrow @safe @nogc
{
  assert(0, "code bug: cannot call setKey on a non-object container");
}
void addObjectValue(ref JsonContainer this_, Json value) nothrow
{
  assert(this_.object.currentKey !is null);
  this_.object.map[this_.object.currentKey].assign(value);
/+
  try {
    this_.object.map[this_.object.currentKey] = value;
  } catch(Exception) {
    assert(0, "exception thrown while adding object value");
  }
+/
  this_.object.currentKey = null; // NOTE: only for debugging purposes
}
void addArrayValue(ref JsonContainer this_, Json value) nothrow {
  this_.array.values.put(value);
}
void invalidAddValue(ref JsonContainer this_, Json value) nothrow {
  assert(0, "code bug: cannot call addValue on a non-object/array value");
}
bool objectIsEmpty(ref JsonContainer this_) nothrow {
  return this_.object.map.length == 0;
}
bool arrayIsEmpty(ref JsonContainer this_) nothrow {
  return this_.array.values.data.length == 0;
}
bool invalidIsEmpty(ref JsonContainer this_) nothrow {
  assert(0, "code bug: cannot call isEmpty on a non-object/array value");;
}
void invalidSetCommaContext(ref JsonContainer this_) {
  assert(0, "code bug: cannot call setCommmaContext on a non-object/array value");;
}
immutable ContainerMethods objectContainerVtable =
  ContainerMethods(&setObjectKey, &addObjectValue, &objectIsEmpty);//, &setObjectCommaContext);
immutable ContainerMethods arrayContainerVtable =
  ContainerMethods(&invalidSetKey, &addArrayValue, &arrayIsEmpty);//, &setArrayCommaContext);
immutable ContainerMethods valueContainerVtable =
  ContainerMethods(&invalidSetKey, &invalidAddValue, &invalidIsEmpty);//, &invalidSetCommaContext);


enum ParserContext {
  root,
  objectKey,
  objectColon,
  objectValue,
  objectComma,
  arrayValue,
  arrayComma,
  exception
}
struct ParseJsonValueData
{
  JsonOptions options = void;
  Json value = void;
  JsonExceptionPayload e = void;

  char* lastLineStart = void;
  LineNumber lineNumber = void;

  ParserContext startContext;
  JsonContainer currentContainer;
}

/**
   Parses 1 Json value and returns immediately when it finishes.
   It returns a pointer to the next character after the value.
   Returns: The next character after the Json value.  It returns
            errors by setting the exception up in the parserData struct.
	    If no error occurs, then the json value will be in the
	    parserData struct.
 */
char* parseJsonValue(char* next, char* limit, ref ParseJsonValueData parserData) nothrow
{
  ParserContext context = parserData.startContext;

  void setupJsonError(JsonException.Type type, string messageFormat, string file = __FILE__, size_t line = __LINE__, Throwable nextException = null) nothrow
  {
    parserData.e.throwing = true;
    parserData.e.type = type;
    parserData.e.message.format = messageFormat;
    parserData.e.file = file;
    parserData.e.line = line;
    parserData.e.next = nextException;
    limit = next; // Stop the state machine
    context = ParserContext.exception;
  }

  
  Json[] parseArray() nothrow
  {
    // Save the current context
    auto saveContainer = parserData.currentContainer;
    // Setup array container
    parserData.currentContainer = JsonContainer(&arrayContainerVtable, false);
    parserData.startContext = ParserContext.arrayValue;
    
    next = parseJsonValue(next, limit, parserData);

    if(parserData.e.throwing)
      return null;
    if(!parserData.currentContainer.ended) {
      setupJsonError(JsonException.Type.endedInsideStructure, "input ended inside an array");
      return null;
    }
    auto parsedArray = parserData.currentContainer.array;
    // restore context
    parserData.currentContainer = saveContainer;

    return parsedArray.values.data.length == 0 ?
      Json.emptyArray.payload.array : parsedArray.values.data;
  }

  char c = void;

  // ExpectedState: c is the first char, next points to c
  // Returns: length of the integer part of the string
  //          next points to the character after the number (no change if not a number)
  // Note: if the character after the number can be part of an unquoted
  //       string, then it is an error for strict json, and an unquoted string
  //       for lenient json.
  size_t tryScanNumber() nothrow
  {
    size_t intPartLength;
    char* cpos = next + 1;

    if(c == '-') {
      if(cpos >= limit)
       	return 0; // '-' is not a number
      c = *cpos;
      cpos++;
    }

    if(c == '0') {
      intPartLength = cpos-next;
      if(cpos < limit) {
	c = *cpos;
	if(c == '.')
	  goto FRAC;
	if(c == 'e' || c == 'E')
	  goto EXPONENT;
      }
      next += intPartLength;
      return intPartLength;
    }

    if(c > '9' || c < '1')
      return 0; // can't be a number

    while(true) {
      if(cpos < limit) {
	c = *cpos;
	if(c <= '9' && c >= '0') {
	  cpos++;
	  continue;
	}
	if(c == '.') {
	  intPartLength = cpos-next;
	  goto FRAC;
	}
	if(c == 'e' || c == 'E') {
	  intPartLength = cpos-next;
	  goto EXPONENT;
	}
      }
      intPartLength = cpos-next;
      next += intPartLength;
      return intPartLength;
    }

  FRAC:
    // cpos points to '.'
    cpos++;
    if(cpos >= limit)
      return 0; // Must have digits after decimal point but got end of input
    c = *cpos;
    if(c > '9' || c < '0')
      return 0; // Must have digits after decimal point but got something else
    //number.decimalOffset = cpos-next;
    while(true) {
      cpos++;
      if(cpos < limit) {
	c = *cpos;
	if(c <= '9' && c >= '0')
	  continue;
	if(c == 'e' || c == 'E')
	  goto EXPONENT;
      }
      next = cpos;
      return intPartLength;
    }

  EXPONENT:
    // cpos points to 'e' or 'E'
    cpos++;
    if(cpos >= limit)
      return 0; // Must have - / + /digits after 'e' but got end of input
    //number.exponentOffset = cpos-next;
    c = *cpos;
    if(c == '-') {
      //number.exponentNegative = true;
      cpos++;
      if(cpos >= limit)
	return 0; // Must have digits after '-'
      c = *cpos;
    } else if(c == '+') {
      cpos++;
      if(cpos >= limit)
	return 0; // Must have digits after '+'
      c = *cpos;
    }

    if(c > '9' || c < '0')
      return 0; // Must have digits after 'e'
    while(true) {
      cpos++;
      if(cpos < limit) {
	c = *cpos;
	if(c <= '9' && c >= '0')
	  continue;
      }
      next = cpos;
      return intPartLength;
    }
  }
  /** ExpectedState: next points to char after string
   *  Returns: check state.throwing for error
   *           if no error, next will point to char after quote
   */
  void scanQuotedString() nothrow
  {
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
    static immutable ubyte[] highEscapeTable =
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

    while(true) {
      if(next >= limit) {
	setupJsonError(JsonException.Type.endedInsideQuote, "json ended inside a quoted string");
	return;
      }
      c = *next;

      if(c == '"') {
	next++;
	return;
      }

      if(c == '\\') {
	next++;
	if(next >= limit)
	  return;
	c = *next;
	if(c == '"') {
	  next++;
	} else if(c == '/') {
	  next++;
	} else {
	  if(c < '\\' || c > 'u') {
	    parserData.e.message.c0 = c;
	    setupJsonError(JsonException.Type.invalidEscapeChar, "invalid escape char '%c0'");
	    return;
	  }
	    
	  auto escapeValue = highEscapeTable[c - '\\'];
	  if(escapeValue == 0) {
	    parserData.e.message.c0 = c;
	    setupJsonError(JsonException.Type.invalidEscapeChar, "invalid escape char '%c0'");
	    return;
	  }

	  if(c == 'u') {
	    setupJsonError(JsonException.Type.notImplemented, "\\u escape sequences not implemented");
	    return;
	  } else {
	    next++;
	  }
	}
      } else if(c <= 0x1F) {
	if(c == '\n') {
	  setupJsonError(JsonException.Type.tabNewlineCRInsideQuotes, "found newline '\n' inside quote");
	  return;
	}
	if(c == '\t') {
	  setupJsonError(JsonException.Type.tabNewlineCRInsideQuotes, "found tab '\t' inside quote");
	  return;
	}
	if(c == '\r') {
	  setupJsonError(JsonException.Type.tabNewlineCRInsideQuotes, "found carriage return '\r' inside quote");
	  return;
	}
	
	parserData.e.message.c0 = c;
	setupJsonError(JsonException.Type.controlCharInsideQuotes, "found control char '%c0' inside qoutes");
	return;
	
      } else if(c >= JsonCharSetLookupLength) {
	setupJsonError(JsonException.Type.notImplemented, "[DEBUG] non-ascii chars not implemented yet");
	return;
      } else {
	next++;
      }
    }
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
  bool nextCouldBePartOfUnquotedString() nothrow
  {
    if(next >= limit) return false;
    c = *next;
    if(c >= JsonCharSetLookupLength)
      return true;
    JsonCharSet charSet = jsonCharSetMap[c];
    return charSet == JsonCharSet.other;
  }
  //
  // ExpectedState: c is first letter, next points to char after first letter
  // ReturnState: check if state.throwing is true
  Json tryScanKeywordOrNumberStrictJson() nothrow
  {
    if(c == 'n') {
      // must be 'null'
      if(next + 3 <= limit && next[0..3] == "ull") {
	next += 3;
	if(!nextCouldBePartOfUnquotedString())
	  return Json.null_;
      }
    } else if(c == 't') {
      // must be 'true'
      if(next + 3 <= limit && next[0..3] == "rue") {
	next += 3;
	if(!nextCouldBePartOfUnquotedString())
	  return Json(true);
      }
    } else if(c == 'f') {
      // must be 'false'
      if(next + 4 <= limit && next[0..4] == "alse") {
	next += 4;
	if(!nextCouldBePartOfUnquotedString())
	  return Json(false);
      }
    } else {
      next--;
      char* startNum = next;
      auto intPartLength = tryScanNumber();
      if(intPartLength > 0) {
	// TODO: remove this try/catch later
	try {
	  return Json(startNum[0..next-startNum], intPartLength);
	} catch(Exception e) {
	  setupJsonError(JsonException.Type.unknown, e.msg);
	  return Json.null_;
	}
      }
      next++; // restore next
    }

    parserData.e.message.s0 = "<insert-string-here>";
    setupJsonError(JsonException.Type.notAKeywordOrNumber, "expected a null,true,false,NUM but got '%s0'");
    return Json.null_; // Should be ignored by caller
  }


  while(next < limit) {
    c = *next;
    if(c >= JsonCharSetLookupLength) {
      //writefln("[DEBUG] c = '%s' (CharSet=%s) (ParserContext=%s)", escape(c), state.charSet, state.currentContextDebugName);
      setupJsonError(JsonException.Type.notImplemented, "non-ascii chars not implemented yet");
      return next;
    } else {
      JsonCharSet charSet = jsonCharSetMap[c];
      //if(printTestInfo)
      //try {writefln("[DEBUG] c = '%s' (0x%x) (CharSet=%s) (Context=%s)", c, cast(ubyte)c, charSet, context);}catch(Exception) { }
      next++;

      final switch(context) {
      case ParserContext.root:
	final switch(charSet) {
	case JsonCharSet.other          : goto OTHER_ROOT_CONTEXT;
	case JsonCharSet.notAscii       : goto NOT_IMPLEMENTED;
	case JsonCharSet.spaceTabCR     : goto IGNORE;
	case JsonCharSet.newline        : goto NEWLINE;
	case JsonCharSet.startObject    : goto START_ROOT_OBJECT;
	case JsonCharSet.endObject      : goto UNEXPECTED_CHAR;
	case JsonCharSet.startArray     : goto START_ROOT_ARRAY;
	case JsonCharSet.endArray       : goto UNEXPECTED_CHAR;
	case JsonCharSet.nameSeparator  : goto UNEXPECTED_CHAR;
	case JsonCharSet.valueSeparator : goto UNEXPECTED_CHAR;
	case JsonCharSet.slash          : goto NOT_IMPLEMENTED;
	case JsonCharSet.hash           : goto NOT_IMPLEMENTED;
	case JsonCharSet.quote          : goto QUOTE_ROOT_CONTEXT;
	case JsonCharSet.asciiControl   : goto INVALID_CONTROL_CHAR;
	}
      case ParserContext.objectKey:
	setupJsonError(JsonException.Type.notImplemented, "objectKey context not implemented");
	return next;
	break;
      case ParserContext.objectColon:
	setupJsonError(JsonException.Type.notImplemented, "objectColon context not implemented");
	return next;
	break;
      case ParserContext.objectValue:
	setupJsonError(JsonException.Type.notImplemented, "objectValue context not implemented");
	return next;
	break;
      case ParserContext.objectComma:
	setupJsonError(JsonException.Type.notImplemented, "objectComma context not implemented");
	return next;
	break;
      case ParserContext.arrayValue:
	final switch(charSet) {
	case JsonCharSet.other          : goto OTHER_ARRAY_CONTEXT;
	case JsonCharSet.notAscii       : goto UNEXPECTED_CHAR;
	case JsonCharSet.spaceTabCR     : goto IGNORE;
	case JsonCharSet.newline        : goto NEWLINE;
	case JsonCharSet.startObject    : goto START_OBJECT_INSIDE_ARRAY;
	case JsonCharSet.endObject      : goto UNEXPECTED_CHAR;
	case JsonCharSet.startArray     : goto START_ARRAY_INSIDE_ARRAY;
	case JsonCharSet.endArray       : goto END_CONTAINER_BEFORE_VALUE;
	case JsonCharSet.nameSeparator  : goto UNEXPECTED_CHAR;
	case JsonCharSet.valueSeparator : goto UNEXPECTED_CHAR;
	case JsonCharSet.slash          : goto NOT_IMPLEMENTED;
	case JsonCharSet.hash           : goto NOT_IMPLEMENTED;
	case JsonCharSet.quote          : goto QUOTE_ARRAY_CONTEXT;
	case JsonCharSet.asciiControl   : goto INVALID_CONTROL_CHAR;
	}
      case ParserContext.arrayComma:
	final switch(charSet) {
	case JsonCharSet.other          : goto UNEXPECTED_CHAR;
	case JsonCharSet.notAscii       : goto UNEXPECTED_CHAR;
	case JsonCharSet.spaceTabCR     : goto IGNORE;
	case JsonCharSet.newline        : goto NEWLINE;
	case JsonCharSet.startObject    : goto UNEXPECTED_CHAR;
	case JsonCharSet.endObject      : goto UNEXPECTED_CHAR;
	case JsonCharSet.startArray     : goto UNEXPECTED_CHAR;
	case JsonCharSet.endArray       : goto END_CONTAINER_BEFORE_COMMA;
	case JsonCharSet.nameSeparator  : goto UNEXPECTED_CHAR;
	case JsonCharSet.valueSeparator : goto ARRAY_COMMA_SEPARATOR;
	case JsonCharSet.slash          : goto NOT_IMPLEMENTED;
	case JsonCharSet.hash           : goto NOT_IMPLEMENTED;
	case JsonCharSet.quote          : goto UNEXPECTED_CHAR;
	case JsonCharSet.asciiControl   : goto INVALID_CONTROL_CHAR;
	}
      case ParserContext.exception:
	setupJsonError(JsonException.Type.notImplemented, "exception context not implemented");
	return next;
	break;
      }

    IGNORE:
      continue;
    NOT_IMPLEMENTED:
      setupJsonError(JsonException.Type.notImplemented, "not implemented (context=?,charset=?)");
      return next;
    UNEXPECTED_CHAR:
      parserData.e.message.c0 = c;
      setupJsonError(JsonException.Type.unexpectedChar, "unexpected char '%c0'");
      return next;
    INVALID_CONTROL_CHAR:
      parserData.e.message.c0 = c;
      setupJsonError(JsonException.Type.controlChar, "invalid control char '%c0'");
      return next;
    NEWLINE:
      parserData.lastLineStart = next;
      parserData.lineNumber++;
      continue;
    START_ROOT_OBJECT:
      setupJsonError(JsonException.Type.notImplemented, "START_ROOT_OBJECT not implemented");
      return next;
    START_OBJECT_INSIDE_ARRAY:
      setupJsonError(JsonException.Type.notImplemented, "START_OBJECT_INSIDE_ARRAY not implemented");
      return next;
    START_ROOT_ARRAY:
      parserData.value.set(parseArray());
      return next;
    START_ARRAY_INSIDE_ARRAY:
      setupJsonError(JsonException.Type.notImplemented, "START_ARRAY_INSIDE_ARRAYnot implemented");
      return next;
    END_CONTAINER_BEFORE_VALUE:
      if(!parserData.options.lenient && !parserData.currentContainer.vtable.isEmpty(parserData.currentContainer)) {
	parserData.e.message.c0 = c;
	setupJsonError(JsonException.Type.unexpectedChar, "expected quoted string but got '%c0'");
	return next;
      }
      //goto END_CONTAINER_BEFORE_COMMA;
    END_CONTAINER_BEFORE_COMMA:
      parserData.currentContainer.ended = true;
      return next;
    ARRAY_COMMA_SEPARATOR:
      context = ParserContext.arrayValue;
      continue;
    OTHER_ROOT_CONTEXT:
      if(parserData.options.lenient) {
	//parserData.value = scanNumberOrUnquoted();
	setupJsonError(JsonException.Type.notImplemented, "OTHER_ROOT_CONTEXT not implemented");
      } else {
	//parserData.value = tryScanKeywordOrNumberStrictJson();
	parserData.value.assign(tryScanKeywordOrNumberStrictJson());
      }
      return next;
    OTHER_ARRAY_CONTEXT:
      {
	Json value;
	if(parserData.options.lenient) {
	  //parserData.value = scanNumberOrUnquoted();
	  setupJsonError(JsonException.Type.notImplemented, "OTHER_ARRAY_CONTEXT not implemented");
	} else {
	  value.assign(tryScanKeywordOrNumberStrictJson());
	}
	parserData.currentContainer.vtable.addValue(parserData.currentContainer, value);
      }
      context = ParserContext.arrayComma;
      continue;
    QUOTE_ROOT_CONTEXT:
      {
	char* startOfString = next;
	scanQuotedString();
	parserData.value.setString(cast(string)(startOfString[0..next-startOfString - 1]));
      }
      return next;
    QUOTE_ARRAY_CONTEXT:
      {
	char* startOfString = next;
	scanQuotedString();
	parserData.currentContainer.vtable.addValue(parserData.currentContainer, Json(cast(string)(startOfString[0..next-startOfString - 1])));
      }
      context = ParserContext.arrayComma;
      continue;
    }
  }

  // No json was found
  if(parserData.currentContainer.atRootContext()) {
    setupJsonError(JsonException.Type.noJson, "no JSON content found");
  }

  return next;

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

      Json expected = Json(buffer[0..offset], intString.length);
      Json actual = parseJson(buffer[0..offset]);
      
      assert(expected.equals(actual));

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

	  Json expected = Json(buffer[0..offset], intString.length);
	  Json actual = parseJson(buffer[0..offset]);
      
	  assert(expected.equals(actual));
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
      auto json = parseJson(cast(char[])s, options);
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
  //printTestInfo = true;
  foreach(i; 0..2) {
    testError(JsonException.Type.noJson, "");
    testError(JsonException.Type.noJson, " \t\r\n");
    for(char c = 0; c < ' '; c++) {
      if(jsonCharSetMap[c] == JsonCharSet.asciiControl) {
	buffer[0] = cast(char)c;
	testError(JsonException.Type.controlChar, buffer[0..1]);
      }
    }
    testError(JsonException.Type.unexpectedChar, "}");
    testError(JsonException.Type.unexpectedChar, "]");
    testError(JsonException.Type.unexpectedChar, ":");
    testError(JsonException.Type.unexpectedChar, ",");
    //testError(JsonException.Type.unexpectedChar, "{]");
    testError(JsonException.Type.unexpectedChar, "[}");
    testError(JsonException.Type.unexpectedChar, "[,");
    //testError(JsonException.Type.unexpectedChar, "{,");

    //testError(JsonException.Type.endedInsideStructure, "{");
    testError(JsonException.Type.endedInsideStructure, "[");

    testError(JsonException.Type.endedInsideQuote, "\"");
    //testError(JsonException.Type.endedInsideQuote, "{\"");
    //testError(JsonException.Type.endedInsideQuote, "[\"");
    /+
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
    +/
    setLenient();
  }
  unsetLenient();
/+
  setLenient();
  testError(JsonException.Type.invalidKey, `{null`);
  testError(JsonException.Type.invalidKey, `{true`);
  testError(JsonException.Type.invalidKey, `{false`);
  testError(JsonException.Type.invalidKey, `{0`);
  testError(JsonException.Type.invalidKey, `{1.0`);
  testError(JsonException.Type.invalidKey, `{-0.018e-40`);
  unsetLenient();
+/
  void test(const(char)[] s, Json expectedValue, size_t testLine = __LINE__)
  {
    import std.conv : to;
    
    Json json;
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escapeForTest(s));
    }
    json = parseJson(cast(char[])s, options);
    if(!expectedValue.equals(json)) {
      writefln("Expected: %s", expectedValue);
      writefln("Actual  : %s", json);
      stdout.flush();
      assert(0);
    }

    // Generate the JSON using toString and parse it again!
    string gen = to!string(json);
    json = parseJson(cast(char[])gen, options);
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
/+
  void testValues(const(char)[] s, Json[] expectedValues)
  {
    if(printTestInfo) {
      writeln("--------------------------------------------------------------");
      writefln("[TEST] %s", escapeForTest(s));
    }
    auto jsonValues = parseJsonValues(cast(char[])s, options);
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
+/
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
    /+
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
    +/
  }
  unsetLenient();
  

/+
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
  +/
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
