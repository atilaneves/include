module dpp.translation.docs;

import dpp.from;

/** Get the attached comments at the location of the cursor */
string getComment(in from!"clang".Cursor cursor) @safe {
    import std.typecons: Nullable;
    string docStr = "";
    Nullable!string nullableComment = cursor.raw_comment();
    if(!nullableComment.isNull) {
        docStr = nullableComment.get();
    }
    return docStr;
}
