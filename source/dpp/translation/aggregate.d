/**
   Translate aggregates
 */
module dpp.translation.aggregate;

import dpp.from;
import std.range: isInputRange;


enum MAX_BITFIELD_WIDTH = 64;


string[] translateStruct(in from!"dpp.ast.node".ClangCursor node,
                         ref from!"dpp.runtime.context".Context context)
    @safe
{
    return translateStrass(node, context, "struct");
}

string[] translateClass(in from!"dpp.ast.node".ClangCursor node,
                        ref from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Token;
    import std.algorithm: canFind;

    const cKeyword = node.tokens.canFind(Token(Token.Kind.Keyword, "class"))
        ? "class"
        : "struct";

    return translateStrass(node, context, cKeyword);
}

// "strass" is a struct or class
private string[] translateStrass(in from!"dpp.ast.node".ClangCursor node,
                                 ref from!"dpp.runtime.context".Context context,
                                 in string cKeyword)
    @safe
    in(
        node.kind == from!"clang".Cursor.Kind.StructDecl ||
        node.kind == from!"clang".Cursor.Kind.ClassDecl ||
        node.kind == from!"clang".Cursor.Kind.ClassTemplate ||
        node.kind == from!"clang".Cursor.Kind.ClassTemplatePartialSpecialization
    )
  do
{
    import dpp.translation.template_: templateSpelling, translateTemplateParams,
        translateSpecialisedTemplateParams;
    import clang: Cursor;
    import std.typecons: Nullable, nullable;
    import std.array: join;
    import std.conv: text;

    Nullable!string spelling() {

        // full template
        if(node.kind == Cursor.Kind.ClassTemplate)
            return nullable(templateSpelling(node, translateTemplateParams(node, context)));

        // partial or full template specialisation
        if(node.type.numTemplateArguments != -1)
            return nullable(templateSpelling(node, translateSpecialisedTemplateParams(node, context)));

        // non-template class/struct
        return Nullable!string();
    }

    const dKeyword = "struct";

    return translateAggregate(context, node, cKeyword, dKeyword, spelling);
}


string[] translateUnion(in from!"dpp.ast.node".ClangCursor node,
                        ref from!"dpp.runtime.context".Context context)
    @safe
    in(node.kind == from!"clang".Cursor.Kind.UnionDecl)
    do
{
    import clang: Cursor;
    return translateAggregate(context, node, "union");
}


string[] translateEnum(in from!"dpp.ast.node".ClangCursor cursor,
                       ref from!"dpp.runtime.context".Context context)
    @safe
    in(cursor.kind == from!"clang".Cursor.Kind.EnumDecl)
    do
{
    import dpp.translation.dlang: maybeRename;
    import dpp.ast.node: Node, ClangCursor;
    import clang: Cursor, Token;
    import std.typecons: nullable;
    import std.algorithm: canFind;

    const enumName = context.spellingOrNickname(const Node(cursor.spelling, const Node.Declaration(cursor)));
    string[] lines;

    const isEnumClass = cursor.tokens.canFind(Token(Token.Kind.Keyword, "class"));

    if(!isEnumClass && !context.options.alwaysScopedEnums) {
        // Translate it twice so that C semantics are the same (global names)
        // but also have a named version for optional type correctness and
        // reflection capabilities.
        // This means that `enum Foo { foo, bar }` in C will become:
        // `enum Foo { foo, bar }` _and_
        // `enum foo = Foo.foo; enum bar = Foo.bar;` in D.

        foreach(member; cursor) {
            if(!member.isDefinition) continue;
            auto memName = maybeRename(ClangCursor(member), context);
            lines ~= `enum ` ~ memName ~ ` = ` ~ enumName ~ `.` ~ memName ~ `;`;
        }
    }

    return
        translateAggregate(context, cursor, "enum", nullable(enumName)) ~
        lines;
}


// not pure due to Cursor.opApply not being pure
string[] translateAggregate(
    ref from!"dpp.runtime.context".Context context,
    in from!"dpp.ast.node".ClangCursor node,
    in string keyword,
    in from!"std.typecons".Nullable!string spelling = from!"std.typecons".Nullable!string()
)
    @safe
{
    return translateAggregate(context, node, keyword, keyword, spelling);
}


// not pure due to Cursor.opApply not being pure
string[] translateAggregate(
    ref from!"dpp.runtime.context".Context context,
    in from!"dpp.ast.node".ClangCursor node,
    in string cKeyword,
    in string dKeyword,
    in from!"std.typecons".Nullable!string spelling = from!"std.typecons".Nullable!string()
)
    @safe
{
    import dpp.translation.translation: translate;
    import dpp.ast.node: Node, ClangCursor;
    import clang: Cursor, Type, AccessSpecifier;
    import std.algorithm: map;
    import std.array: array;

    // remember all aggregate declarations
    context.rememberAggregate(node);

    const name = spelling.isNull
        ? context.spellingOrNickname(const Node(node.spelling, const Node.Declaration(node)))
        : spelling.get;
    const realDlangKeyword = node.semanticParent.type.canonical.kind == Type.Kind.Record
        ? "static " ~ dKeyword
        : dKeyword;
    const firstLine = realDlangKeyword ~ ` ` ~ name;

    if(!node.isDefinition) return [firstLine ~ `;`];

    string[] lines;
    lines ~= firstLine;
    lines ~= `{`;

    // In C++ classes have private access as default
    if(cKeyword == "class") {
        lines ~= "private:";
        context.accessSpecifier = AccessSpecifier.Private;
    } else
        context.accessSpecifier = AccessSpecifier.Public;

    BitFieldInfo bitFieldInfo;

    lines ~= bitFieldInfo.header(node);

    context.log("Children: ", node.children);

    foreach(i, child; node.children) {

        if(child.kind == Cursor.Kind.PackedAttr) {
            lines ~= "align(1):";
            continue;
        }

        lines ~= bitFieldInfo.handle(child);

        if(skipMember(child)) continue;

        const childTranslation = () {

            if(isPrivateField(child, context))
                return translatePrivateMember(child);

            if(child.kind == Cursor.Kind.CXXBaseSpecifier)
                return translateBase(i, child, context);

            return translate(const Node(child.spelling, const Node.Declaration(const ClangCursor(child))), context);
        }();

        lines ~= childTranslation.map!(a => "    " ~ a).array;

        // Possibly deal with C11 anonymous structs/unions. See issue #29.
        lines ~= maybeC11AnonymousRecords(node, child, context);

        bitFieldInfo.update(child);
    }

    lines ~= bitFieldInfo.finish;
    lines ~= maybeOperators(node, name);
    lines ~= maybeDisableDefaultCtor(node, dKeyword);

    lines ~= `}`;

    return lines;
}

private struct BitFieldInfo {

    import dpp.runtime.context: Context;
    import clang: Cursor;

    /// if the last seen member was a bitfield
    private bool lastMemberWasBitField;
    /// the combined (summed) bitwidths of the bitfields members seen so far
    private int totalBitWidth;
    /// to generate new names
    private int paddingNameIndex;

    string[] header(in Cursor cursor) @safe nothrow {
        import std.algorithm: any;

        if(cursor.children.any!(a => a.isBitField)) {
            // The align(4) is to mimic C. There, `struct Foo { int f1: 2; int f2: 3}`
            // would have sizeof 4, where as the corresponding bit fields in D would have
            // size 1. So we correct here. See issue #7.
            return [`    import std.bitmanip: bitfields;`, ``, `    align(4):`];
        } else
            return [];

    }

    string[] handle(in Cursor member) @safe pure nothrow {

        string[] lines;

        if(member.isBitField && !lastMemberWasBitField)
            lines ~= `    mixin(bitfields!(`;

        if(!member.isBitField && lastMemberWasBitField) lines ~= finishBitFields;

        if(member.isBitField && totalBitWidth + member.bitWidth > MAX_BITFIELD_WIDTH) {
            lines ~= finishBitFields;
            lines ~= `    mixin(bitfields!(`;
        }

        return lines;
    }

    void update(in Cursor member) @safe pure nothrow {
        lastMemberWasBitField = member.isBitField;
        if(member.isBitField) totalBitWidth += member.bitWidth;
    }

    string[] finish() @safe pure nothrow {
        return lastMemberWasBitField ? finishBitFields : [];
    }

    private string[] finishBitFields() @safe pure nothrow {
        import std.conv: text;


        int padding(in int totalBitWidth) {

            for(int powerOfTwo = 8; powerOfTwo <= MAX_BITFIELD_WIDTH; powerOfTwo *= 2) {
                if(powerOfTwo >= totalBitWidth) return powerOfTwo - totalBitWidth;
            }

            assert(0, text("Could not find powerOfTwo for width ", totalBitWidth));
        }

        const paddingBits = padding(totalBitWidth);

        string[] lines;

        if(paddingBits)
            lines ~= text(`        uint, "`, newPaddingName, `", `, padding(totalBitWidth));

        lines ~= `    ));`;

        totalBitWidth = 0;

        return lines;
    }

    private string newPaddingName() @safe pure nothrow {
        import std.conv: text;
        return text("_padding_", paddingNameIndex++);
    }
}

private bool isPrivateField(in from!"clang".Cursor cursor,
                            in from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Cursor, AccessSpecifier;

    const isField =
        cursor.kind == Cursor.Kind.FieldDecl ||
        cursor.kind == Cursor.Kind.VarDecl;

    return
        context.accessSpecifier == AccessSpecifier.Private
        && isField
        // The reason for this is templated types have negative sizes according
        // to libclang, even if they're fully instantiated...
        // So even though they're private, they can't be declared as opaque
        // binary blobs because we don't know how large they are.
        && cursor.type.getSizeof > 0
        ;

}

// Since one can't access private members anyway, why bother translating?
// Declare an array of equivalent size in D, helps with the untranslatable
// parts of C++
private string[] translatePrivateMember(in from!"clang".Cursor cursor) @safe {
    import std.conv: text;
    return cursor.type.getSizeof > 0
        ? [text(`void[`, cursor.type.getSizeof, `] `, cursor.spelling, `;`)]
        : [];
}


private bool skipMember(in from!"clang".Cursor member) @safe @nogc pure nothrow {
    import clang: Cursor;
    return
        !member.isDefinition
        && member.kind != Cursor.Kind.CXXMethod
        && member.kind != Cursor.Kind.Constructor
        && member.kind != Cursor.Kind.Destructor
        && member.kind != Cursor.Kind.VarDecl
        && member.kind != Cursor.Kind.CXXBaseSpecifier
        && member.kind != Cursor.Kind.ConversionFunction
        && member.kind != Cursor.Kind.FunctionTemplate
    ;
}


string[] translateField(in from!"dpp.ast.node".ClangCursor node,
                        ref from!"dpp.runtime.context".Context context)
    @safe
{

    import dpp.translation.dlang: maybeRename;
    import dpp.translation.type: translate;
    import clang: Cursor, Type;
    import std.conv: text;
    import std.typecons: No;
    import std.array: replace;

    assert(node.kind == Cursor.Kind.FieldDecl, text("Field of wrong kind: ", node.cursor));

    // The field could be a pointer to an undeclared struct or a function pointer with parameter
    // or return types that are a pointer to an undeclared struct. We have to remember these
    // so as to be able to declare the structs for D consumption after the fact.
    if(node.type.kind == Type.Kind.Pointer) maybeRememberStructsFromType(node.type, context);

    // Remember the field name in case it ends up clashing with a type.
    context.rememberField(node.spelling);

    const type = translate(node.type, context, No.translatingFunction);

    return node.isBitField
        ? translateBitField(node, context, type)
        : [text(type, " ", maybeRename(node, context), ";")];
}

string[] translateBitField(in from!"dpp.ast.node".ClangCursor node,
                           ref from!"dpp.runtime.context".Context context,
                           in string type)
    @safe
{
    import dpp.translation.dlang: maybeRename;
    import std.conv: text;

    auto spelling = maybeRename(node, context);
    // std.bitmanip.bitfield can't handle successive mixins with
    // no name. See issue #35.
    if(spelling == "") spelling = context.newAnonymousMemberName;

    return [text("    ", type, `, "`, spelling, `", `, node.bitWidth, `,`)];
}

// C allows elaborated types to appear in function parameters and member declarations
// if they're pointers and doesn't require a declaration for the referenced type.
private void maybeRememberStructsFromType(in from!"clang".Type type,
                                          ref from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Type;
    import std.range: only, chain;

    const pointeeType = type.pointee.canonical;
    const isFunction =
        pointeeType.kind == Type.Kind.FunctionProto ||
        pointeeType.kind == Type.Kind.FunctionNoProto;

    if(pointeeType.kind == Type.Kind.Record)
        // can't use `only` with `const` for some reason
        maybeRememberStructs([type], context);
    else if(isFunction)
        maybeRememberStructs(chain(only(pointeeType.returnType), pointeeType.paramTypes),
                             context);
}


// C allows elaborated types to appear in function parameters and member declarations
// if they're pointers and doesn't require a declaration for the referenced type.
void maybeRememberStructs(R)(R types, ref from!"dpp.runtime.context".Context context)
    @safe if(isInputRange!R)
{
    import dpp.translation.type: translate;
    import clang: Type;
    import std.algorithm: map, filter;

    auto structTypes = types
        .filter!(a => a.kind == Type.Kind.Pointer && a.pointee.canonical.kind == Type.Kind.Record)
        .map!(a => a.pointee.canonical);

    void rememberStruct(in Type pointeeCanonicalType) {
        import dpp.translation.type: translateElaborated;
        import std.array: replace;
        import std.algorithm: canFind;

        // If it's not a C elaborated type, we don't need to do anything.
        // The only reason this code exists is because elaborated types
        // can be used in function signatures or member declarations
        // without a declaration for the struct itself as long as it's
        // a pointer.
        if(!pointeeCanonicalType.spelling.canFind("struct ") &&
           !pointeeCanonicalType.spelling.canFind("union ") &&
           !pointeeCanonicalType.spelling.canFind("enum "))
            return;

        const removeConst = pointeeCanonicalType.isConstQualified
            ? pointeeCanonicalType.spelling.replace("const ", "")
            : pointeeCanonicalType.spelling;
        const removeVolatile = pointeeCanonicalType.isVolatileQualified
            ? removeConst.replace("volatile ", "")
            : removeConst;

        context.rememberFieldStruct(translateElaborated(removeVolatile));
    }

    foreach(structType; structTypes)
        rememberStruct(structType);
}

// if the cursor is an aggregate in C, i.e. struct, union or enum
package bool isAggregateC(in from!"clang".Cursor cursor) @safe @nogc pure nothrow {
    import clang: Cursor;
    return
        cursor.kind == Cursor.Kind.StructDecl ||
        cursor.kind == Cursor.Kind.UnionDecl ||
        cursor.kind == Cursor.Kind.EnumDecl;
}


private string[] maybeC11AnonymousRecords(in from!"clang".Cursor cursor,
                                          in from!"clang".Cursor member,
                                          ref from!"dpp.runtime.context".Context context)
    @safe

{
    import dpp.translation.type: translate, hasAnonymousSpelling;
    import clang: Cursor, Type;
    import std.algorithm: any, filter;

    if(member.type.kind != Type.Kind.Record || member.spelling != "") return [];

    // Either a field or an array of the type we expect
    bool isFieldOfRightType(in Cursor member, in Cursor child) {
        const isField =
            child.kind == Cursor.Kind.FieldDecl &&
            child.type.canonical == member.type.canonical;

        const isArrayOf = child.type.elementType.canonical == member.type.canonical;
        return isField || isArrayOf;
    }

    // Check if the parent cursor has any fields have this type.
    // If so, we don't need to declare a dummy variable.
    const anyFields = cursor.children.any!(a => isFieldOfRightType(member, a));
    if(anyFields) return [];

    string[] lines;
    const varName = context.newAnonymousMemberName;

    //lines ~= "    " ~ translate(member.type, context) ~ " " ~  varName ~ ";";
    const dtype = translate(member.type, context);
    lines ~= "    " ~ dtype ~ " " ~  varName ~ ";";

    foreach(subMember; member.children) {
        if(subMember.kind == Cursor.Kind.FieldDecl)
            lines ~= innerFieldAccessors(varName, subMember);
        else if(subMember.type.canonical.kind == Type.Kind.Record &&
                hasAnonymousSpelling(subMember.type.canonical) &&
                !member.children.any!(a => isFieldOfRightType(subMember, a))) {
            foreach(subSubMember; subMember) {
                lines ~= "        " ~ innerFieldAccessors(varName, subSubMember);
            }
        }
    }

    return lines;
}


// functions to emulate C11 anonymous structs/unions
private string[] innerFieldAccessors(in string varName, in from !"clang".Cursor subMember) @safe {
    import std.format: format;
    import std.algorithm: map;
    import std.array: array;

    string[] lines;

    const fieldAccess = varName ~ "." ~ subMember.spelling;
    const funcName = subMember.spelling;

    lines ~= q{auto %s() @property @nogc pure nothrow { return %s; }}
        .format(funcName, fieldAccess);

    lines ~= q{void %s(_T_)(auto ref _T_ val) @property @nogc pure nothrow { %s = val; }}
        .format(funcName, fieldAccess);

    return lines.map!(a => "    " ~ a).array;
}

// emit a D opCmp if the cursor has operator<, operator> and operator==
private string[] maybeOperators(in from!"clang".Cursor cursor, in string name)
    @safe
{
    import dpp.translation.function_: OPERATOR_PREFIX;
    import std.algorithm: map, any;
    import std.array: array, replace;

    string[] lines;

    bool hasOperator(in string op) {
        return cursor.children.any!(a => a.spelling == OPERATOR_PREFIX ~ op);
    }

    // if the aggregate has a parenthesis in its name it's because it's a templated
    // struct/class, in which case the parameter has to have an exclamation mark.
    const typeName = name.replace("(", "!(");

    if(hasOperator(">") && hasOperator("<") && hasOperator("==")) {
        lines ~=  [
            `int opCmp()(` ~ typeName ~ ` other) const`,
            `{`,
            `    if(this.opCppLess(other)) return -1;`,
            `    if(this.opCppMore(other)) return  1;`,
            `    return 0;`,
            `}`,
        ].map!(a => `    ` ~ a).array;
    }

    if(hasOperator("!")) {
        lines ~= [
            `bool opCast(T: bool)() const`,
            `{`,
            `    return !this.opCppBang();`,
            `}`,
        ].map!(a => `    ` ~ a).array;
    }

    return lines;
}

private string[] maybeDisableDefaultCtor(in from!"clang".Cursor cursor, in string dKeyword)
    @safe
{
    import dpp.translation.function_: numParams;
    import clang: Cursor;
    import std.algorithm: any;

    bool hasNoArgsCtor(in Cursor child) {
        return child.kind == Cursor.Kind.Constructor &&
            numParams(child) == 0;
    }

    if(dKeyword == "struct" &&
       cursor.children.any!hasNoArgsCtor) {
        return [`    @disable this();`];
    }

    return [];
}


private string[] translateBase(size_t index,
                               in from!"clang".Cursor cursor,
                               ref from!"dpp.runtime.context".Context context)
    @safe
    in(cursor.kind == from!"clang".Cursor.Kind.CXXBaseSpecifier)
do
{
    import dpp.translation.type: translate;
    import std.typecons: No;
    import std.algorithm: canFind;
    import std.conv: text;

    const type = translate(cursor.type, context, No.translatingFunction);

    // FIXME - see it.cpp.templates.__or_
    // Not only would that test fail if this weren't here, but the spelling of
    // the type parameters would be completely wrong as well.
    if(type.canFind("...")) return [];

    // FIXME - type traits failures due to inheritance
    if(type.canFind("&")) return [];

    const fieldName = text("_base", index);
    auto fieldDecl = type ~ " " ~ fieldName ~ ";";
    auto maybeAliasThis = index == 0
        ? [`alias ` ~ fieldName ~ ` this;`]
        : [];

    return fieldDecl ~ maybeAliasThis;
}
