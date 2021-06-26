/**
   The context the translation happens in, to avoid global variables
 */
module dpp.runtime.context;

alias LineNumber = size_t;

// A function or global variable
struct Linkable {
    LineNumber lineNumber;
    string mangling;
}

enum Language {
    C,
    Cpp,
}


/**
   Context for the current translation, to avoid global variables
 */
struct Context {

    import dpp.runtime.options: Options;
    import clang: Cursor, Type, AccessSpecifier;
    import std.array: Appender;

    alias SeenCursors = bool[CursorId];

    /**
       The lines of output so far. This is needed in order to fix
       any name collisions between functions or variables with aggregates
       such as structs, unions and enums.
     */
    private string[] _lines;

    /**
       Structs can be anonymous in C, and it's even common
       to typedef them to a name. We come up with new names
       that we track here so as to be able to properly translate
       those typedefs.
    */
    private string[Cursor.Hash] _nickNames;

    /**
       Remembers the seen struct pointers so that if any are undeclared in C,
       we do so in D at the end.
     */
    private bool[string] _fieldStructSpellings;

    /**
       Remembers the field spellings in aggregates in case we need to change any
       of them.
     */
    private LineNumber[][string] _fieldDeclarations;

    /**
       All the aggregates that have been declared
     */
    private bool[string] _aggregateDeclarations;

    /**
      Mapping between the original aggregate spelling and the renamed one,
      if renaming was necessary.
     */
    private string[string] _aggregateSpelling;

    /**
      Mapping between a child aggregate's name and its parent aggregate's
      name.
     */
    private string[string] _aggregateParents;

    /**
      Mapping between a line number and an array of strings representing all
      the aggregate types' names contained at that index.
     */
    private string[][LineNumber] _aggregateTypeLines;

    /**
       A linkable is a function or a global variable.  We remember all
       the ones we saw here so that if there's a name clash we can
       come back and fix the declarations after the fact with
       pragma(mangle).
     */
    private Linkable[string] _linkableDeclarations;

    /**
       All the function-like macros that have been declared
     */
    private bool[string] _functionMacroDeclarations;

    /**
       Remember all the macros already defined
     */
    private bool[string] _macros;

    /**
       All previously seen cursors
     */
    private SeenCursors _seenCursors;

    AccessSpecifier accessSpecifier = AccessSpecifier.Public;

    /// Command-line options
    Options options;

    /*
      Remember all declared types so that C-style casts can be recognised
     */
    private string[] _types;

    /// to generate unique names
    private int _anonymousIndex;

    private string[] _namespaces;

    Language language;

    this(Options options, in Language language) @safe pure {
        this.options = options;
        this.language = language;
    }

    ref Context indent() @safe pure return {
        options.indent;
        return this;
    }

    auto indentation() @safe @nogc pure const {
        return options.indentation;
    }

    void setIndentation(in int indentation) @safe pure {
        options.indentation = indentation;
    }

    void log(A...)(auto ref A args) const {
        import std.functional: forward;
        options.log(forward!args);
    }

    bool debugOutput() @safe @nogc pure nothrow const {
        return options.debugOutput;
    }

    bool hasSeen(in Cursor cursor) @safe pure nothrow const {
        return cast(bool)(CursorId(cursor) in _seenCursors);
    }

    void rememberCursor(in Cursor cursor) @safe pure nothrow {
        // EnumDecl can have no spelling but end up defining an enum anyway
        // See "it.compile.projects.double enum typedef"
        if(cursor.spelling != "" || cursor.kind == Cursor.Kind.EnumDecl)
            _seenCursors[CursorId(cursor)] = true;
    }

    string translation() @safe pure nothrow const {
        import std.array: join;
        return _lines.join("\n");
    }

    /**
       Writes a line of translation.
     */
    void writeln(in string line) @safe pure nothrow {
        _lines ~= line;
    }

    /**
       Writes lines of translation.
    */
    void writeln(in string[] lines) @safe pure nothrow {
        _lines ~= lines;
    }

    // remember a function or variable declaration
    string rememberLinkable(in Cursor cursor) @safe pure nothrow {
        import dpp.translation.dlang: maybeRename;

        const spelling = maybeRename(cursor, this);
        // since linkables produce one-line translations, the next
        // will be the linkable
        _linkableDeclarations[spelling] = Linkable(_lines.length, cursor.mangling);

        return spelling;
    }

    void fixNames() @safe {
        declareUnknownStructs;
        fixLinkables;
        if (language == Language.C)
            fixAggregateTypes;
        fixFields;
    }

    void fixLinkables() @safe pure {
        foreach(declarations; [_aggregateDeclarations, _functionMacroDeclarations]) {
            foreach(name, _; declarations) {
                // if there's a name clash, fix it
                auto clashingLinkable = name in _linkableDeclarations;
                if(clashingLinkable) {
                    resolveClash(_lines[clashingLinkable.lineNumber], name, clashingLinkable.mangling);
                }
            }
        }
    }

    void fixFields() @safe pure {

        import dpp.translation.dlang: pragmaMangle, rename;
        import std.string: replace;

        foreach(spelling, lineNumbers; _fieldDeclarations) {
            if(spelling in _aggregateDeclarations || spelling in _aggregateSpelling) {
                const actual = spelling in _aggregateSpelling
                                            ? _aggregateSpelling[spelling]
                                            : spelling;
                const renamed = rename(actual, this);
                foreach (lineNumber; lineNumbers) {
                    _lines[lineNumber] = _lines[lineNumber]
                        // Member declaration
                        .replace(" " ~ actual ~ `;`, " " ~ renamed ~ `;`)
                        // Pointer declaration
                        .replace(" *" ~ actual ~ `;`, " *" ~ renamed ~ `;`)
                        // Accessing member in getter (C11 anon records)
                        .replace("." ~ actual ~ ";", "." ~ renamed ~ ";")
                        // Accessing member in setter (C11 anon records)
                        .replace("." ~ actual ~ " =", "." ~ renamed ~ " =")
                        // Getter function name (C11 anon records)
                        .replace("auto " ~ actual ~ "()", "auto " ~ renamed ~ "()")
                        // Setter function name (C11 anon records)
                        .replace("void " ~ actual ~ "(_T_)", "void " ~ renamed ~ "(_T_)");
                }
            }
        }
    }

    void fixAggregateTypes() @safe pure {
        import dpp.translation.type : removeDppDecorators;
        import std.array : join;
        import std.algorithm : reverse;
        import std.string : replace;

        string aggregateTypeName(in string spelling) @safe pure {
            if (spelling !in _aggregateParents)
                return spelling;

            string[] elems;
            elems ~= spelling;
            string curr = _aggregateParents[spelling];

            while (curr in _aggregateParents) {
                elems ~= curr ~ ".";
                curr = _aggregateParents[curr];
            }

            elems ~= curr ~ ".";

            return elems.reverse.join;
        }

        foreach (elem; _aggregateTypeLines.byKeyValue) {
            LineNumber lineNumber = elem.key;
            string[] aggregateTypeNames = elem.value;

            foreach (name; aggregateTypeNames) {
                const actualName = aggregateTypeName(name);
                lines[lineNumber] = lines[lineNumber]
                    .replace("__dpp_aggregate__ " ~ name, actualName);
            }
        }
    }

    /**
       Tells the context to remember a struct type encountered in an aggregate field.
       Typically this will be a pointer to a structure but it could also be the return
       type or parameter types of a function pointer field. This is (surprisingly!)
       perfectly valid C code, even though `Foo` is never declared anywhere:
       ----------------------
       struct Foo* fun(void);
       ----------------------
       See issues #22 and #24
     */
    void rememberFieldStruct(in string typeSpelling) @safe pure {
        _fieldStructSpellings[typeSpelling] = true;
    }

    /**
       In C it's possible for a struct field name to have the same name as a struct
       because of elaborated names. We remember them here in case we need to fix them.
     */
    void rememberField(scope const string spelling) @safe pure {
        _fieldDeclarations[spelling] ~= _lines.length;
    }

    /**
       Remember this aggregate cursor
     */
    void rememberAggregate(in Cursor cursor) @safe pure {
        const spelling = resolveSpelling(cursor);
        rememberType(spelling);
    }

    void rememberAggregateParent(in Cursor child, in Cursor parent) @safe pure {
        const parentSpelling = spelling(parent.spelling);
        const childSpelling = resolveSpelling(child);
        _aggregateParents[childSpelling] = parentSpelling;
    }

    void rememberAggregateTypeLine(in string typeName) @safe pure {
        _aggregateTypeLines[lines.length] ~= typeName;
    }

    private string resolveSpelling(in Cursor cursor) @safe pure {
        const spelling = spellingOrNickname(cursor);
        _aggregateDeclarations[spelling] = true;
        rememberSpelling(cursor.spelling, spelling);
        return spelling;
    }

    void rememberSpelling(scope const string original, in string spelling) @safe pure {
        if (original != "" && original != spelling)
            _aggregateSpelling[original] = spelling;
    }

    bool isUnknownStruct(in string name) @safe pure const {
        return name !in _aggregateDeclarations
            && (name !in _aggregateSpelling
                || _aggregateSpelling[name] !in _aggregateDeclarations);
    }

    /**
       If unknown structs show up in functions or fields (as a pointer),
        define them now so the D file can compile
        See `it.c.compile.delayed`.
    */
    void declareUnknownStructs() @safe {
        import dpp.translation.type : removeDppDecorators;

        foreach(name, _; _fieldStructSpellings) {
            name = name.removeDppDecorators;
            if(isUnknownStruct(name)) {
                log("Could not find '", name, "' in aggregate declarations, defining it");
                const spelling = name in _aggregateSpelling ? _aggregateSpelling[name]
                                                            : name;
                writeln("struct " ~ spelling ~ ";");
                _aggregateDeclarations[spelling] = true;
            }
        }
    }

    const(typeof(_aggregateDeclarations)) aggregateDeclarations() @safe pure nothrow const {
        return _aggregateDeclarations;
    }

    /// return the spelling if it exists, or our made-up nickname for it if not
    string spellingOrNickname(in Cursor cursor) @safe pure {
        if (cursor.spelling == "" || cursor.isAnonymous)
            return nickName(cursor);

        return spelling(cursor.spelling);
    }

    string spelling(scope const string cursorSpelling) @safe pure {
        import dpp.translation.dlang: rename, isKeyword;

        if (cursorSpelling in _aggregateSpelling)
            return _aggregateSpelling[cursorSpelling];

        return cursorSpelling.isKeyword ? rename(cursorSpelling, this)
                                        : cursorSpelling.idup;
    }

    private string nickName(in Cursor cursor) @safe pure {
        if(cursor.hash !in _nickNames) {
            auto nick = newAnonymousTypeName;
            _nickNames[cursor.hash] = nick;
        }

        return _nickNames[cursor.hash];
    }

    private string newAnonymousTypeName() @safe pure {
        import std.conv: text;
        return text("_Anonymous_", _anonymousIndex++);
    }

    string newAnonymousMemberName() @safe pure {
        import std.string: replace;
        return newAnonymousTypeName.replace("_A", "_a");
    }

    private void resolveClash(ref string line, in string spelling, in string mangling) @safe pure const {
        import dpp.translation.dlang: pragmaMangle;
        line = `    ` ~ pragmaMangle(mangling) ~ replaceSpelling(line, spelling);
    }

    private string replaceSpelling(in string line, in string spelling) @safe pure const {
        import dpp.translation.dlang: rename;
        import std.array: replace;
        return line
            .replace(spelling ~ `;`, rename(spelling, this) ~ `;`)
            .replace(spelling ~ `(`, rename(spelling, this) ~ `(`)
            ;
    }

    void rememberType(in string type) @safe pure nothrow {
        _types ~= type;
    }

    bool isUserDefinedType(in string spelling) @safe pure const {
        import std.algorithm: canFind;
        return _types.canFind(spelling);
    }

    void rememberMacro(in Cursor cursor) @safe pure {
        _macros[cursor.spelling.idup] = true;
        if(cursor.isMacroFunction)
            _functionMacroDeclarations[cursor.spelling.idup] = true;
    }

    bool macroAlreadyDefined(in Cursor cursor) @safe pure const {
        return cast(bool) (cursor.spelling in _macros);
    }

    void pushNamespace(in string ns) @safe pure nothrow {
        _namespaces ~= ns;
    }

    void popNamespace(in string ns) @safe pure nothrow {
        _namespaces = _namespaces[0 .. $-1];
    }

    // returns the current namespace so it can be deleted
    // from translated names
    string namespace() @safe pure nothrow const {
        import std.array: join;
        return _namespaces.join("::");
    }

    /// If this cursor is from one of the ignored namespaces
    bool isFromIgnoredNs(in Type type) @safe const {
        import std.algorithm: canFind, any;
        return options.ignoredNamespaces.any!(a => type.spelling.canFind(a ~ "::"));
    }

    /// Is the file from an ignored path? Note it uses file globbing
    bool isFromIgnoredPath(in Cursor cursor) @safe const {
        import std.path: globMatch;
        import std.algorithm: any;
        string sourcePath = cursor.sourceRange.path;
        return options.ignoredPaths.any!(a => sourcePath.globMatch(a));
    }
}


// to identify a cursor
private struct CursorId {
    import clang: Cursor, Type;

    string cursorSpelling;
    Cursor.Kind cursorKind;
    string typeSpelling;
    Type.Kind typeKind;

    this(in Cursor cursor) @safe pure nothrow {
        cursorSpelling = cursor.spelling.idup;
        cursorKind = cursor.kind;
        typeSpelling = cursor.type.spelling.idup;
        typeKind = cursor.type.kind;
    }
}
