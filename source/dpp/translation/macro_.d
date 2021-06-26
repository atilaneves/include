module dpp.translation.macro_;


import dpp.from;


string[] translateMacro(in from!"clang".Cursor cursor,
                        ref from!"dpp.runtime.context".Context context)
    @safe
    in(cursor.kind == from!"clang".Cursor.Kind.MacroDefinition)
{
    import dpp.translation.dlang: maybeRename;
    import clang: Cursor;
    import std.file: exists;
    import std.algorithm: startsWith, canFind;
    import std.conv: text;

    // we want non-built-in macro definitions to be defined and then preprocessed
    // again

    if(isBuiltinMacro(cursor)) return [];

    const tokens = cursor.tokens;

    // the only sane way for us to be able to see a macro definition
    // for a macro that has already been defined is if an #undef happened
    // in the meanwhile. Unfortunately, libclang has no way of passing
    // that information to us
    string maybeUndef;
    if(context.macroAlreadyDefined(cursor))
        maybeUndef = "#undef " ~ cursor.spelling ~ "\n";

    context.rememberMacro(cursor);
    const spelling = maybeRename(cursor, context);
    const dbody = translateToD(cursor, context, tokens);

    // We try here to make it so that literal macros can be imported from
    // another D module. We also try and make non-function-like macros
    // that aren't a literal constant but an expression can be imported
    // as well. To that end we check that we can mixin a declaration of
    // an enum with the same name of the macro with the original C code.
    // If so, we mix it in.
    // Below that, we declare the macro so the the #including .dpp file
    // uses the preprocessor.
    if(!cursor.isMacroFunction && tokens.length > 1) {
        const defineEnum = `enum ` ~ spelling ~ ` = ` ~ dbody ~ `;`;
        const enumVarName = `enumMixinStr_` ~ spelling;
        return [
            `#ifdef ` ~ spelling,
            `#    undef ` ~ spelling,
            `#endif`,
            `static if(!is(typeof(` ~ spelling ~ `))) {`,
            "    private enum " ~ enumVarName ~ " = `" ~ defineEnum ~ "`;",
            `    static if(is(typeof({ mixin(` ~ enumVarName ~ `); }))) {`,
            `        mixin(`  ~ enumVarName ~ `);`,
            `    }`,
            `}`,
            `#define ` ~ spelling ~ ` ` ~ dbody,
        ];
    }

    const maybeSpace = cursor.isMacroFunction ? "" : " ";
    return [maybeUndef ~ "#define " ~ spelling ~ maybeSpace ~ dbody ~ "\n"];
}


bool isBuiltinMacro(in from!"clang".Cursor cursor)
    @safe
{
    import clang: Cursor;
    import std.file: exists;
    import std.algorithm: startsWith;

    if(cursor.kind != Cursor.Kind.MacroDefinition) return false;

    return
        cursor.sourceRange.path == ""
        || !cursor.sourceRange.path.exists
        || cursor.isPredefined
        || cursor.spelling.startsWith("__STDC_")
        ;
}


private bool isLiteralMacro(in from!"clang".Token[] tokens) @safe @nogc pure nothrow {
    import clang: Token;

    return
        tokens.length == 2
        && tokens[0].kind == Token.Kind.Identifier
        && tokens[1].kind == Token.Kind.Literal
        ;
}


private string translateToD(
    in from!"clang".Cursor cursor,
    ref from!"dpp.runtime.context".Context context,
    in from!"clang".Token[] tokens,
    )
    @safe
{
    import dpp.translation.type: translateElaborated;
    if(isLiteralMacro(tokens)) return fixLiteral(tokens[1]);
    if(tokens.length == 1) return ""; // e.g. `#define FOO`

    return tokens
        .fixSizeof(cursor)
        .fixCasts(cursor, context)
        .fixArrow
        .fixNull
        .toString
        .translateElaborated(context)
        ;
}


private string toString(R)(R tokens) {
    import clang: Token;
    import std.algorithm: map;
    import std.array: join;

    // skip the identifier because of DPP_ENUM_
    return tokens[1..$]
        .map!(t => t.spelling)
        .join(" ");
}

private string fixLiteral(in from!"clang".Token token)
    @safe pure
    in(token.kind == from!"clang".Token.Kind.Literal)
    do
{
    return token.spelling
        .fixLowercaseSuffix
        .fixMultiCharacterLiterals
        .fixWideCharStrings
        .fixOctal
        .fixMicrosoftSuffixes
        .fixLongLong
        ;
}


private auto fixArrow(R)(R tokens) {
    import clang: Token;
    import std.algorithm: map;

    static const(Token) replace(in Token token) {
        return token == Token(Token.Kind.Punctuation, "->")
            ? Token(Token.Kind.Punctuation, ".")
            : token;
    }

    return tokens
        .map!replace
        ;
}

private auto fixNull(R)(R tokens)
{
    import clang: Token;
    import std.algorithm: map;
    import std.array: array;

    static const(Token) replace(in Token token) {
        return token == Token(Token.Kind.Identifier, "NULL")
            ? Token(Token.Kind.Identifier, "null")
            : token;
    }

    return tokens
        .map!replace
        ;
}

version(Windows)
private string fixMicrosoftSuffixes(in string str) @safe pure nothrow {
    import std.algorithm: endsWith;

    if(str.endsWith("i64"))
        return str[0 .. $-3] ~ "L";
    else if(str.endsWith("i32"))
        return str[0 .. $-3];
    else if(str.endsWith("i16"))
        return str[0 .. $-3];
    else if(str.endsWith("i8"))
        return str[0 .. $-3];
    return str;
}
else
private string fixMicrosoftSuffixes(in string str) @safe pure nothrow {
    return str;
}

private string fixWideCharStrings(in string str) @safe pure nothrow {
    if(str.length >=3 && str[0] == 'L' && str[1] == '"' && str[$-1] == '"') {
        return str[1 .. $] ~ "w";
    }

    return str;
}

private string fixMultiCharacterLiterals(in string str) @safe pure nothrow {
    // multi-character literals are implementation-defined, but allowed,
    // in C I aim to identify them and then distinguish them from a
    // non-ASCII character, which I'll just forward to D assuming utf-8 source
    // moreover, the '\uxxx' or other escape sequences should be forwarded
    if(str.length > 3 && str[0] == '\'' && str[$-1] == '\'' && str[1] != '\\') {
        // apparently a multi-char literal, let's translate to int
        // the way this is typically done in common compilers, e.g.
        // https://gcc.gnu.org/onlinedocs/cpp/Implementation-defined-behavior.html
        int result;
        foreach(char ch; str[1 .. $-1]) {
            // any multi-byte character I'm going to assume
            // is just a single UTF-8 char and punt on it.
            if(ch > 127) return str;
            result <<= 8;
            result |= cast(ubyte) ch;
        }
        import std.conv;
        return to!string(result);
    }
    return str; // not one of these, don't touch
}

private string fixLowercaseSuffix(in string str) @safe pure nothrow {
    import std.algorithm: endsWith;

    if(str.endsWith("ll"))
        return str[0 .. $-2] ~ "LL";
    if(str.endsWith("l"))
        return str[0 .. $-1] ~ "L";
    return str;
}

private string fixLongLong(in string str) @safe pure {
    import std.uni : toUpper;
    const suffix = str.length < 3 ? "" : str[$-3 .. $].toUpper;

    if (suffix.length > 0) {
        if (suffix == "LLU" || suffix == "ULL")
            return str[0 .. $-3] ~ "LU";

        if (suffix[1 .. $] == "LL")
            return str[0 .. $-2] ~ "L";
    }

    return str;
}


private string fixOctal(in string spelling) @safe pure {
    import clang: Token;
    import std.algorithm: countUntil;
    import std.uni: isNumber;
    import std.conv : text;

    const isOctal =
        spelling.length > 1
        && spelling[0] == '0'
        && spelling[1].isNumber
        ;

    if(!isOctal) return spelling;

    const firstNonZero = spelling.countUntil!(a => a != '0');
    if(firstNonZero == -1) return "0";

    const base8_representation = spelling[firstNonZero .. $];
    const base8_length = base8_representation.length;
    int base10_number = 0;
    foreach(i, c; base8_representation)
    {
        const power = base8_length - i - 1;
        const digit = c - '0';
        base10_number += digit * 8 ^^ power;
    }

    return "/+converted from octal '" ~ base8_representation ~ "'+/ " ~ base10_number.text;
}


private auto fixSizeof(R)(R tokens, in from !"clang".Cursor cursor)
{
    import clang: Token;
    import std.conv: text;
    import std.algorithm: countUntil;

    // find the closing paren for the function-like macro's argument list
    size_t lastIndex = 0;
    if(cursor.isMacroFunction) {
        lastIndex = tokens
            .countUntil!(t => t == Token(Token.Kind.Punctuation, ")"))
            +1; // skip the right paren

        if(lastIndex == 0)  // given the +1 above, -1 becomes 0
            throw new Exception(text("Can't fix sizeof in function-like macro with tokens: ", tokens));
    }

    const beginning = tokens[0 .. lastIndex];
    const(Token)[] middle;

    for(size_t i = lastIndex; i < tokens.length - 1; ++i) {
        if(tokens[i] == Token(Token.Kind.Keyword, "sizeof")
           && tokens[i + 1] == Token(Token.Kind.Punctuation, "("))
        {
            // find closing paren
            long open = 1;
            size_t scanIndex = i + 2;  // skip i + 1 since that's the open paren

            while(open != 0) {
                if(tokens[scanIndex] == Token(Token.Kind.Punctuation, "("))
                    ++open;
                if(tokens[scanIndex] == Token(Token.Kind.Punctuation, ")"))
                    --open;

                ++scanIndex;
            }

            middle ~= tokens[lastIndex .. i] ~ tokens[i + 1 .. scanIndex] ~ Token(Token.Kind.Keyword, ".sizeof");
            lastIndex = scanIndex;
            // advance i past the sizeof. -1 because of ++i in the for loop
            i = lastIndex - 1;
        }
    }

    // can't chain here due to fixCasts appending to const(Token)[]
    return beginning ~ middle ~ tokens[lastIndex .. $];
}


private auto fixCasts(R)(
    R tokens,
    in from !"clang".Cursor cursor,
    in from!"dpp.runtime.context".Context context,
    )
{
    import dpp.translation.exception: UntranslatableException;
    import clang: Token;
    import std.conv: text;
    import std.algorithm: countUntil, count;
    import std.range: chain;

    // if the token array is a built-in or user-defined type
    bool isType(in Token[] tokens) {

        if( // fundamental type
            tokens.length == 1
            && tokens[0].kind == Token.Kind.Keyword
            && tokens[0].spelling != "sizeof"
            && tokens[0].spelling != "alignof"
            )
            return true;

        if( // user defined type
            tokens.length == 1
            && tokens[0].kind == Token.Kind.Identifier
            && context.isUserDefinedType(tokens[0].spelling)
            )
            return true;

        if(  // pointer to a type
            tokens.length >= 2
            && tokens[$-1] == Token(Token.Kind.Punctuation, "*")
            && isType(tokens[0 .. $-1])
            )
            return true;

        if( // const type
            tokens.length >= 2
            && tokens[0] == Token(Token.Kind.Keyword, "const")
            && isType(tokens[1..$])
            )
            return true;

        if( // typeof
            tokens.length >= 2
            && tokens[0] == Token(Token.Kind.Keyword, "typeof")
            )
            return true;

        if ( // macro attribute (e.g. __force) + type
            tokens.length >= 2
            && tokens[0].kind == Token.Kind.Identifier
            && isType(tokens[1..$])
            )
            return true;

        return false;
    }

    size_t lastIndex = 0;
    // find the closing paren for the function-like macro's argument list
    if(cursor.isMacroFunction) {
        lastIndex = tokens
            .countUntil!(t => t == Token(Token.Kind.Punctuation, ")"))
            +1; // skip the right paren
        if(lastIndex == 0)
            throw new Exception(text("Can't fix casts in function-like macro with tokens: ", tokens));
    }

    const beginning = tokens[0 .. lastIndex];
    const(Token)[] middle;

    // See #244 - macros can have unbalanced parentheses
    // Apparently libclang tokenises `\\n)` as including the backslash and the newline
    const numLeftParens  = tokens.count!(a => a == Token(Token.Kind.Punctuation, "(") ||
                                         a == Token(Token.Kind.Punctuation, "\\\n("));
    const numRightParens = tokens.count!(a => a == Token(Token.Kind.Punctuation, ")") ||
                                         a == Token(Token.Kind.Punctuation, "\\\n)"));

    if(numLeftParens != numRightParens)
        throw new UntranslatableException("Unbalanced parentheses in macro `" ~ cursor.spelling ~ "`");

    for(size_t i = lastIndex; i < tokens.length - 1; ++i) {
        if(tokens[i] == Token(Token.Kind.Punctuation, "(")) {
            // find closing paren
            long open = 1;
            size_t scanIndex = i + 1;  // skip i + 1 since that's the open paren

            while(open != 0) {
                if(tokens[scanIndex] == Token(Token.Kind.Punctuation, "("))
                    ++open;
                // for the 2nd condition, esee it.c.compile.preprocessor.multiline
                if(tokens[scanIndex] == Token(Token.Kind.Punctuation, ")") ||
                   tokens[scanIndex] == Token(Token.Kind.Punctuation, "\\\n)"))
                    --open;

                ++scanIndex;
            }
            // at this point scanIndex is the 1 + index of closing paren

            // we want to ignore e.g. `(int)(foo).sizeof` even if `foo` is a type
            const followedByDot =
                tokens.length > scanIndex
                && tokens[scanIndex].spelling[0] == '.'
                ;

	    // make sure this is not a function call (look before the open paren)
	    const isFunctionParam =
                i > 0
                && tokens[i - 1].kind == Token.Kind.Identifier;

            if(isType(tokens[i + 1 .. scanIndex - 1])
                    && !followedByDot
                    && !isFunctionParam) {
                middle ~= tokens[lastIndex .. i] ~
                    Token(Token.Kind.Punctuation, "cast(") ~
                    tokens[i + 1 .. scanIndex]; // includes closing paren
                lastIndex = scanIndex;
                // advance i past the sizeof. -1 because of ++i in the for loop
                i = lastIndex - 1;
            }
        }
    }

    return chain(beginning, middle, tokens[lastIndex .. $]);
}
