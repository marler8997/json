module json;

// Compile Options
alias ColumnNumber = uint;
alias LineNumber = uint;
version = PassJsonParserByValue;

import std.stdio  : write, writeln, writefln;
import std.string : format;

import more.utf8;

//
// The JSON Specification is defined in RFC4627
//
enum JsonType : ubyte { bool_, number, string_, array, object}

//
// Lenient JSON
// 1. Ignores end-of-line comments starting with // or #
// 2. Ignores multiline comments /* till */ (cannot be nested)
// 3. Unquoted or Single quoted strings
// 4. Allows a trailing comma after the last array element or object name/value pair
//

class JsonException : Exception
{
  enum Type {
    unknown,    
    noJson,
    multipleRoots,
    // TODO: the invalid char could be a multibyte UTF-8 char, make sure the error message handles this
    invalidChar, // Encountered an invalid character (not inside a string)
    controlChar, // Encountered non-whitespace control char (ascii=0x00-0x1F)
    //missingEndObject, // Object missing close brace
    endedInsideStructure, // The JSON ended inside an object or an array
    unexpectedChar, // Encountered a char unexpectedly
    unexpectedCloseBrace, // Encountered a close brace but not inside an object
    tabNewlineCRInsideQuotes,
    controlCharInsideQuotes,
    invalidEscapeChar
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
*/

/*
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

struct JsonOptions
{
  ubyte flags;

  @property bool lenient() pure nothrow @safe @nogc const { return (flags & 0x01) != 0;}
  @property void lenient(bool v) pure nothrow @safe @nogc { if (v) flags |= 0x01;else flags &= ~0x01;}
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
*/


/*
Character Sets

Chars          | ID           | Description
------------------------------------------------------------
' ' '\t' '\r'  | ws           | Whitespace
'\n'           |
------------------------------------------------------------
0x00-0x1F minus| cc           | ControlCharacter
Whitespace     |              | Always an error!
------------------------------------------------------------
'{'            | '{'          | StartObject
------------------------------------------------------------
'}'            | '}'          | EndObject
------------------------------------------------------------
'['            | '['          | StartArray
------------------------------------------------------------
']'            | ']'          | EndArray
------------------------------------------------------------
':'            | ':'          | NameSeparator
------------------------------------------------------------
','            | ','          | ValueSeparator
------------------------------------------------------------
'/'            | '/'          | Slash (comment start)
------------------------------------------------------------
'#'            | '#'          | EndOfLineComment
------------------------------------------------------------
'"'            | '"'          | Quote
------------------------------------------------------------
ELSE '!' '$'   | othe         | Everything else
'%' '&' ''' '('|              |
')' '*' '+' '-'|              |
'.' or Unicode |              |
------------------------------------------------------------
*/
enum JsonCharSet : ubyte {
  other          = 0,
  notAscii       = 1,
  spaceTabCR     = 2,
  newline        = 3,
  startObject    = 4,
  endObject      = 5,
  startArray     = 6,
  endArray       = 7,
  nameSeparator  = 8,
  valueSeparator = 9,
  slash          = 10,
  hash           = 11,
  quote          = 12,
  cc             = 13,
}
/+
ubyte lookupCharSet(char c)
{
  if(c >= JsonCharSetLookupLength) return JsonCharSet.notAscii;
  return jsonCharSetMap[c];
}
+/
enum JsonCharSetLookupLength = 128;
mixin("private __gshared JsonCharSet[JsonCharSetLookupLength] jsonCharSetMap = "~rangeInitializers
      (
       `'\0'`   , "JsonCharSet.cc",
       `'\x01'` , "JsonCharSet.cc",
       `'\x02'` , "JsonCharSet.cc",
       `'\x03'` , "JsonCharSet.cc",
       `'\x04'` , "JsonCharSet.cc",
       `'\x05'` , "JsonCharSet.cc",
       `'\x06'` , "JsonCharSet.cc",
       `'\x07'` , "JsonCharSet.cc",
       `'\x08'` , "JsonCharSet.cc",

       `'\x0B'` , "JsonCharSet.cc",
       `'\x0C'` , "JsonCharSet.cc",

       `'\x0E'` , "JsonCharSet.cc",
       `'\x0F'` , "JsonCharSet.cc",
       `'\x10'` , "JsonCharSet.cc",
       `'\x11'` , "JsonCharSet.cc",
       `'\x12'` , "JsonCharSet.cc",
       `'\x13'` , "JsonCharSet.cc",
       `'\x14'` , "JsonCharSet.cc",
       `'\x15'` , "JsonCharSet.cc",
       `'\x16'` , "JsonCharSet.cc",
       `'\x17'` , "JsonCharSet.cc",
       `'\x18'` , "JsonCharSet.cc",
       `'\x19'` , "JsonCharSet.cc",
       `'\x1A'` , "JsonCharSet.cc",
       `'\x1B'` , "JsonCharSet.cc",
       `'\x1C'` , "JsonCharSet.cc",
       `'\x1D'` , "JsonCharSet.cc",
       `'\x1E'` , "JsonCharSet.cc",
       `'\x1F'` , "JsonCharSet.cc",

       `'\t'`   , "JsonCharSet.spaceTabCR",
       `'\n'`   , "JsonCharSet.newline",
       `'\r'`   , "JsonCharSet.spaceTabCR",
       `' '`    , "JsonCharSet.spaceTabCR",

       `'{'`    , "JsonCharSet.startObject",
       `'}'`    , "JsonCharSet.endObject",
       `'['`    , "JsonCharSet.startArray",
       `']'`    , "JsonCharSet.endArray",

       `':'`    , "JsonCharSet.nameSeparator",
       `','`    , "JsonCharSet.valueSeparator",

       `'/'`    , "JsonCharSet.slash",
       `'#'`    , "JsonCharSet.hash",

       `'"'`    , "JsonCharSet.quote",

       )~";");
/+
unittest
{
  foreach(i; 0..jsonCharSetMap.length-1) {
    writefln("['%s'] %s", escape(cast(char)i), jsonCharSetMap[i]);
  }
}
+/




/*
InitialContext (3 bits)
'{' -> InitialObjectContext
'[' -> InitialArrayContext
WS  -> (NoContextChange)
(LJSON) '/' -> SlashCommentContext
(LJSON) '#' -> EndOfLineComment
(LJSON) 0x00-0x1F '}' ']' ':' ',' -> Error: invalidChar
'"' -> QuotedStringContext
ELSE '!' '$' '%' '&' ''' '(' ')' '*' '+' '-' '.' ... -> UnquotedStringContext

Note: An unquoted string should keep track if it is a valid number

*/

struct Location
{
  LineNumber lineNumber;
  ColumnNumber columnNumber;
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
  //@safe:
  import std.bigint;

  enum NumberType : ubyte { long_, ulong_, double_, bigInt }

  union Payload {
    bool bool_;
    long long_;
    ulong ulong_;
    double double_;
    BigInt bigInt;
    string string_;
    Json[] array;
    Json[string] object;
  }

  private ubyte info;
  Payload payload;
  //alias payload this;

  //@disable this();

/+
  static Json createObject()
  {
    return Json(JsonType.object);
  }
+/
  static Json null_() {
    return Json(cast(Json[string])null);
  }

  /// ditto
  this(bool value) {
    this.info = JsonType.bool_;
    this.payload.bool_ = value;
  }
  this(int value) {
    this.info = NumberType.long_ << 3 & JsonType.number;
    this.payload.long_ = value;
  }
  this(uint value) {
    this.info = NumberType.ulong_ << 3 & JsonType.number;
    this.payload.ulong_ = value;
  }
  /// ditto
  this(long value) {
    this.info = NumberType.long_ << 3 & JsonType.number;
    this.payload.long_ = value;
  }
  this(ulong value) {
    this.info = NumberType.ulong_ << 3 & JsonType.number;
    this.payload.ulong_ = value;
  }
  /// ditto
  this(double value) {
    this.info = NumberType.double_ << 3 & JsonType.number;
    this.payload.double_ = value;
  }
  /// ditto
  this(BigInt value) {
    this.info = NumberType.bigInt << 3 & JsonType.number;
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

  void setupAsObject()
  {
    this.info = JsonType.object;
  }
  void setupAsArray()
  {
    this.info = JsonType.array;
  }

/+
  Json[] array()
  {
    return payload.get!(Json[]);
  }
  Json opIndex(size_t i)
  {
    return payload.get!(Json[])[i];
  }

  Json[string] map()
  {
    return payload.get!(Json[string]);
  }
  Json opIndex(string key)
  {
    return payload.get!(Json[string])[key];
  }
+/

  bool equals(Json other) {
    final switch(info & 0b111) {
    case JsonType.bool_:
      return other.info == JsonType.bool_ && this.payload.bool_ == other.payload.bool_;
    case JsonType.number:
      //return other.info == JsonType.number_ && this.payload.bool_ == other.payload.bool_;
      throw new Exception("equals(number) not implemented");
    case JsonType.string_:
      return other.info == JsonType.string_ && this.payload.string_ == other.payload.string_;
    case JsonType.array:
      return other.info == JsonType.array && this.payload.array == other.payload.array;
    case JsonType.object:
      return other.info == JsonType.object && this.payload.object == other.payload.object;
    }
  }

  void toString(scope void delegate(const(char)[]) sink) const
  {
    final switch(info & 0b111) {
    case JsonType.bool_:
      sink(payload.bool_ ? "true" : "false");
      return;
    case JsonType.number:
      //return other.info == JsonType.number_ && this.payload.bool_ == other.payload.bool_;
      throw new Exception("toString(number) not implemented");
      return;
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
	foreach(value; payload.array) {
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
	throw new Exception("Json.object toString not implemented");
	/+
	payload.object[0].toString(sink);
	foreach(value; payload.object) {
	  sink(",");
	  value.toString(sink);
	}
	+/
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


struct JsonParser
{
static:
  alias func = void function();

  static JsonOptions options;
  static char* next;
  static char c;
  static char* limit;

  JsonCharSet charSet;
  string currentContextDebugName;
  immutable(func)[] currentContextMap;

  char* lastLineStart;
  LineNumber lineNumber;

  struct JsonListNode
  {
    Json json;
    JsonListNode* previous;
    this(JsonListNode* previous) {
      this.previous = previous;
    }
  }
  JsonListNode* currentRoot;
  JsonListNode* currentContainer;
  
  bool outsideAllStructures()
  {
    return currentContainer is null;
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

  static ubyte[] highEscapeTable =
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
      if(next >= limit) return false;
      c = *next;

      if(c == '"') {
	next++;
	return true;
      }

      if(c == '\\') {
	next++;
	if(next >= limit) return false;
	c = *next;
	if(c == '"') {
	  next++;
	} else if(c == '/') {
	  next++;
	} else {
	  if(c < '\\' || c > 'u')
	    throw new JsonException(JsonException.Type.invalidEscapeChar, format("invalid escape char '%s'", c));
	    
	  auto escapeValue = highEscapeTable[c - '\\'];
	  if(escapeValue == 0) {
	    throw new JsonException(JsonException.Type.invalidEscapeChar, format("invalid escape char '%s'", c));
	  }

	  if(c == 'u') {
	    throw new Exception("\\u escape sequences not implemented");
	  } else {
	    next++;
	  }
	}
      } else if(c <= 0x1F) {
	if(c == '\n')
	  throw new JsonException(JsonException.Type.tabNewlineCRInsideQuotes, "found newline '\n' inside quote");
	if(c == '\t')
	  throw new JsonException(JsonException.Type.tabNewlineCRInsideQuotes, "found tab '\t' inside quote");
	if(c == '\r')
	  throw new JsonException(JsonException.Type.tabNewlineCRInsideQuotes, "found carriage return '\r' inside quote");
	
	throw new JsonException(JsonException.Type.controlCharInsideQuotes,
				format("found control char 0x%x inside qoutes", cast(ubyte)c));
      } else if(c >= JsonCharSetLookupLength) {
	throw new Exception("[DEBUG] non-ascii chars not implemented yet");
      } else {
	next++;
      }
    }
  }
  
  private static immutable func[] rootContextMap =
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
     JsonCharSet.cc             : &invalidControlChar
     ];
  void setRootContext()
  {
    currentContextDebugName = "root";
    currentContextMap = rootContextMap;
  }
  void setObjectContext()
  {
    immutable func[] objectContextMap =
      [
       JsonCharSet.other          : &notImplemented,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &notImplemented,
       JsonCharSet.endObject      : &endObject,
       JsonCharSet.startArray     : &notImplemented,
       JsonCharSet.endArray       : &notImplemented,
       JsonCharSet.nameSeparator  : &notImplemented,
       JsonCharSet.valueSeparator : &notImplemented,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &notImplemented,
       JsonCharSet.cc             : &invalidControlChar
       ];
    currentContextDebugName = "object";
    currentContextMap = objectContextMap;
  }
  void setArrayContext()
  {
    immutable func[] arrayContextMap =
      [
       JsonCharSet.other          : &notImplemented,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newline,
       JsonCharSet.startObject    : &startObject,
       JsonCharSet.endObject      : &endObject,
       JsonCharSet.startArray     : &startArray,
       JsonCharSet.endArray       : &notImplemented,
       JsonCharSet.nameSeparator  : &notImplemented,
       JsonCharSet.valueSeparator : &notImplemented,
       JsonCharSet.slash          : &notImplemented,
       JsonCharSet.hash           : &notImplemented,
       JsonCharSet.quote          : &notImplemented,
       JsonCharSet.cc             : &invalidControlChar
       ];
    currentContextDebugName = "array";
    currentContextMap = arrayContextMap;
  }
/+
  void setQuoteContext()
  {
    immutable func[] contextMap =
      [
       JsonCharSet.other          : &ignore,
       JsonCharSet.notAscii       : &notImplemented,
       JsonCharSet.spaceTabCR     : &ignore,
       JsonCharSet.newline        : &newlineInsideQuotes,
       JsonCharSet.startObject    : &ignore,
       JsonCharSet.endObject      : &ignore,
       JsonCharSet.startArray     : &ignore,
       JsonCharSet.endArray       : &ignore,
       JsonCharSet.nameSeparator  : &ignore,
       JsonCharSet.valueSeparator : &ignore,
       JsonCharSet.slash          : &ignore,
       JsonCharSet.hash           : &ignore,
       JsonCharSet.quote          : &endQuote,
       JsonCharSet.cc             : &invalidControlChar
       ];
    currentContextDebugName = "quote";
    currentContextMap = contextMap;
  }
  +/
  void ignore()
  {
  }
  void unexpectedChar()
  {
    throw new JsonException(JsonException.Type.unexpectedChar, format("unexpected '%s'", c));
  }
  void newline()
  {
    lastLineStart = next;
    lineNumber++;
  }
  void startRootObject()
  {
    currentRoot = new JsonListNode(currentRoot);
    currentRoot.json.setupAsObject();
    currentContainer = new JsonListNode(null);
    currentContainer.json.payload.object = currentRoot.json.payload.object;
    setObjectContext();
  }
  void startRootArray()
  {
    currentRoot = new JsonListNode(currentRoot);
    currentRoot.json.setupAsArray();
    currentContainer = new JsonListNode(null);
    currentContainer.json.payload.array = currentRoot.json.payload.array;
    setArrayContext();
  }
  void startObject()
  {
    currentContainer = new JsonListNode(currentContainer);
    currentContainer.json.setupAsObject();
    setObjectContext();
  }
  void startArray()
  {
    currentContainer = new JsonListNode(currentContainer);
    currentContainer.json.setupAsArray();
    setArrayContext();
  }
  void endObject()
  {
    if(currentContainer is null) {
      throw new JsonException(JsonException.Type.unexpectedCloseBrace, "found '}' outside any object");
    } else if(currentContainer.previous is null) {
      currentContainer = null;
      setRootContext();
    } else {
      currentContainer = currentContainer.previous;
    }
  }
  void invalidControlChar()
  {
    throw new JsonException(JsonException.Type.controlChar, format("invalid control character 0x%x", c));
  }
  void otherRootContext()
  {
    auto startOfWord = next - 1;

    if(startOfWord + 4 <= limit) {
      if(startOfWord[0..4] == "null") {
	// TODO: need to verify that the next character does not create an unquoted string
	next += 3;
	currentRoot = new JsonListNode(currentRoot);
	currentRoot.json = Json.null_;
	return;
	
      } else if(startOfWord[0..4] == "true") {

	next += 3;
	currentRoot = new JsonListNode(currentRoot);
	currentRoot.json = Json(true);
	return;
	
      } else if(startOfWord + 5 <= limit && startOfWord[0..5] == "false") {

	next += 4;
	currentRoot = new JsonListNode(currentRoot);
	currentRoot.json = Json(false);
	return;
      }
    }
    throw new Exception("unquoted strings not implemented yet");
  }

  void quoteRootContext()
  {
    char* startOfString = next;
    bool endedWithQuote = scanQuotedString();
    if(endedWithQuote) {
      currentRoot = new JsonListNode(currentRoot);
      currentRoot.json = Json(cast(string)(startOfString[0..next-startOfString - 1]));
    } else {
      throw new Exception("end of input inside quoted string, no implementation for this yet");
    }
  }
  void endQuote()
  {
    throw new Exception("not implemented");
    
  }
  void notImplemented()
  {
    throw new Exception(format("Error: char set '%s' not implemented", charSet));
  }
  void parse()
  {
    while(next < limit) {
      c = *next;
      if(c >= JsonCharSetLookupLength) {
	charSet = JsonCharSet.notAscii;
	writefln("[DEBUG] c = '%s' (CharSet=%s) (Context=%s)", escape(c), charSet, currentContextDebugName);
	throw new Exception("[DEBUG] non-ascii chars not implemented yet");
      } else {
	charSet = jsonCharSetMap[c];
	writefln("[DEBUG] c = '%s' (CharSet=%s) (Context=%s)", escape(c), charSet, currentContextDebugName);
	next++;
	auto contextFunc = currentContextMap[charSet];
	contextFunc();
	// next now points to next characer
      }
    }
  }
}
Json parseJson(JsonOptions options, const(char)[] json)
{
  return parseJson(options, cast(char*)json.ptr, cast(char*)json.ptr + json.length);
}
Json parseJson(JsonOptions options, char* start, const char* limit)
  in { assert(start <= limit); } body
{
  JsonParser.options = options;
  JsonParser.next = start;
  JsonParser.limit = cast(char*)limit;
  JsonParser.lastLineStart = start;
  JsonParser.lineNumber = 1;
  JsonParser.currentRoot = null;
  JsonParser.currentContainer = null;
  
  JsonParser.setRootContext();
  JsonParser.parse();

  if(!JsonParser.outsideAllStructures())
    throw new JsonException(JsonException.Type.endedInsideStructure, "unexpected end of input");
  if(JsonParser.currentRoot is null)
    throw new JsonException(JsonException.Type.noJson, "no JSON content found");
  if(JsonParser.currentRoot.previous !is null)
    throw new JsonException(JsonException.Type.multipleRoots, "found multiple root values");

  return JsonParser.currentRoot.json;
}

unittest
{
  JsonOptions options;

  char[16] buffer;
  
  {
    void testError(JsonException.Type expectedError, const(char)[] s, size_t testLine = __LINE__)
    {
      try {
	auto json = parseJson(options, cast(char*)s.ptr, s.ptr + s.length);
	assert(0, format("Expected exception '%s' but did not get one. (testline %s) JSON='%s'",
			 expectedError, testLine, escape(s)));
      } catch(JsonException e) {
	assert(expectedError == e.type, format("Expected error '%s' but got '%s' (testline %s)",
					       expectedError, e.type, testLine));
	//writefln("[TEST-DEBUG] got expected error '%s' from '%s'", e.type, escape(s));
      }
    }

    testError(JsonException.Type.noJson, "");
    testError(JsonException.Type.noJson, " \t\r\n");

    for(char c = 0; c < ' '; c++) {
      if(jsonCharSetMap[c] == JsonCharSet.cc) {
	buffer[0] = cast(char)c;
	testError(JsonException.Type.controlChar, buffer[0..1]);
      }
    }

    testError(JsonException.Type.endedInsideStructure, "{");
    testError(JsonException.Type.endedInsideStructure, "[");

    testError(JsonException.Type.unexpectedChar, "}");
    testError(JsonException.Type.unexpectedChar, "]");
    testError(JsonException.Type.unexpectedChar, ":");
    testError(JsonException.Type.unexpectedChar, ",");

    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\t");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\n");
    testError(JsonException.Type.tabNewlineCRInsideQuotes, "\"\r");

    //testError(JsonException.Type.multipleRoots, "nullnull");
    //testError(JsonException.Type.multipleRoots, "truetrue");
    //testError(JsonException.Type.multipleRoots, "falsefalse");
    
  }
  
  void test(const(char)[] s, Json expectedValue)
  {
    auto json = parseJson(options, cast(char*)s.ptr, s.ptr + s.length);
    assert(expectedValue.equals(json));
    //writefln("Expected: %s", expectedValue);
    //writefln("Actual  : %s", json);
  }

  // Keywords
  test("null", Json.null_);
  test("true", Json(true));
  test("false", Json(false));

  // Strings that are Keywords
  test(`"null"`, Json("null"));
  test(`"true"`, Json("true"));
  test(`"false"`, Json("false"));

  // Strings
  test(`""`, Json(""));
  test(`"a"`, Json("a"));
  test(`"ab"`, Json("ab"));
  test(`"hello, world"`, Json("hello, world"));

  // Unquoted Strings
  //test("nullnull");
  //test("truetrue");
  //test("falsefalse");


}

















string arrayRange(char min, char max, string initializer) {
  string initializers = "";
  for(char c = min; c < max; c++) {
    initializers ~= "'"~c~"': "~initializer~",\n";
  }
  initializers ~= "'"~max~"': "~initializer;
  return initializers;
}
string rangeInitializers(string[] s...) {
  if(s.length % 2 != 0) assert(0, "must supply an even number of arguments to rangeInitializers");
  string code = "["~rangeInitializersCurrent(s);
  //assert(0, code); // uncomment to see the code
  return code;
}
string rangeInitializersCurrent(string[] s) {
  import std.string : countchars;
  string range = s[0];
  if(range[0] == '\'') {
    if(countchars(range, "'") == 2) {
      if(range[$-1] != '\'') throw new Exception(format("a single-character range %s started with an apostrophe (') but did not end with one", range));
      return range ~ ":" ~ s[1] ~ rangeInitializersNext(s);
    }
  } else {
    throw new Exception(format("range '%s' not supported", range));
  }
  char min = range[1];
  char max = range[5];
  return arrayRange(min, max, s[1]) ~ rangeInitializersNext(s);
}
string rangeInitializersNext(string[] s...) {
  if(s.length <= 2) return "]";
  return ",\n"~rangeInitializersCurrent(s[2..$]);
}

version(unittest)
{
  import std.conv : to;
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
  string escape(char c) {
    return escapeTable[c];
  }
  string escape(dchar c) {
    return (c < escapeTable.length) ? escapeTable[c] : to!string(c);
  }
  inout(char)[] escape(inout(char)[] str) pure {
    size_t extra = 0;
    foreach(c; str) {
      if(c == '\r' || c == '\t' || c == '\n' || c == '\\') {
	extra++;
      }
    }

    if(extra == 0) return str;

    char[] newString = new char[str.length + extra];
    size_t oldIndex, newIndex = 0;
    for(oldIndex = 0; oldIndex < str.length; oldIndex++) {
      auto c = str[oldIndex];
      switch(c) {
      case '\r':
	newString[newIndex++] = '\\';
	newString[newIndex++] = 'r';
	break;
      case '\t':
	newString[newIndex++] = '\\';
	newString[newIndex++] = 't';
	break;
      case '\n':
	newString[newIndex++] = '\\';
	newString[newIndex++] = 'n';
	break;
      case '\\':
	newString[newIndex++] = '\\';
	newString[newIndex++] = '\\';
	break;
      default:
	newString[newIndex++] = c;
      }
    }

    assert(newIndex == newString.length);

    return cast(inout(char)[])newString;
  }
}
