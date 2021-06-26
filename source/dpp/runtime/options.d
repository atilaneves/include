/**
   Command-line options
 */
module dpp.runtime.options;

@safe:

version(Windows)
    enum exeExtension = ".exe";
else
    enum exeExtension = "";


struct Options {

    enum usage = "Usage: d++ [options] [D compiler options] <filename.dpp> [D compiler args]";

    string[] dppFileNames;
    int indentation;
    bool debugOutput;
    string[] includePaths;
    bool keepPreCppFiles;
    bool keepDlangFiles;
    bool parseAsCpp;
    bool preprocessOnly;
    string dlangCompiler = "dmd";
    string[] dlangCompilerArgs;
    string[] defines;
    bool earlyExit;
    bool hardFail;
    string mscrtlib;
    bool cppStdLib;
    bool ignoreMacros;
    string[] ignoredMacros;
    bool detailedUntranslatable;
    string[] ignoredNamespaces;
    string[] ignoredCursors;
    bool ignoreSystemPaths;
    string[] ignoredPaths;
    string[string] prebuiltHeaders;
    bool alwaysScopedEnums;
    string cppStandard = "c++17";
    string[] clangOptions;
    bool noSystemHeaders;
    string cppPath;
    string srcOutputPath;

    this(string[] args) {

        import clang: systemPaths;
        import std.exception: enforce;
        import std.path: stripExtension, extension, buildPath, absolutePath;
        import std.file: tempDir;
        import std.algorithm: map, filter, canFind, startsWith;
        import std.array: array;
        import std.conv: text;

        parseArgs(args);
        if(earlyExit) return;

        if(preprocessOnly)
            keepDlangFiles = true;

        dppFileNames = args.filter!(a => a.extension == ".dpp").array;
        enforce(dppFileNames.length != 0, "No .dpp input file specified\n" ~ usage);

        // Remove the name of this binary and the name of the .dpp input file from args
        // so that a D compiler can use the remaining entries.
        dlangCompilerArgs =
            args[1..$].filter!(a => a.extension != ".dpp").array ~
            dFileNames;

        // use msvcrtd.lib if no other libc is specified
        bool addNODEFAULTLIB = false;
        version(Windows) {
            if(mscrtlib) {
                if(dlangCompiler == "dmd") {
                    dlangCompilerArgs ~= mscrtlib ~ ".lib";
                    addNODEFAULTLIB = true;
                } else if (dlangCompiler == "ldc2") {
                    dlangCompilerArgs ~= "--mscrtlib=" ~ mscrtlib;
                }
            }
        } else {
            assert(mscrtlib == "", "Using --mscrtlib flag on a non-windows platform is not allowed.");
        }

        // if no -of option is given, default to the name of the .dpp file
        if(!dlangCompilerArgs.canFind!(a => a.startsWith("-of")) && !dlangCompilerArgs.canFind("-c")) {
            dlangCompilerArgs ~= ((dlangCompiler == "ldc2") ? "--of=" : "-of=") ~
                args.
                filter!(a => a.extension == ".dpp" || a.extension == ".d")
                .front
                .stripExtension
                ~ exeExtension;
        }

        version(Windows) {
            // append the arch flag if not provided manually
            if(!dlangCompilerArgs.canFind!(a => a == "-m64" || a == "-m32" || a == "-m32mscoff")) {
                version(X86_64) {
                    dlangCompilerArgs ~= "-m64";
                }
                version(x86) {
                    dlangCompilerArgs ~= (dlangCompiler == "dmd") ? "-m32mscoff" : "-m32";
                }
            }
            if(addNODEFAULTLIB) {
                dlangCompilerArgs ~= "-L=\"/NODEFAULTLIB:libcmt\"";
            }
            assert(!cppStdLib, "C++ std lib functionality not implemented yet for Windows");
        }

        if(cppStdLib) {
            dlangCompilerArgs ~= "-L-lstdc++";
            parseAsCpp = true;
        }

        if (!noSystemHeaders)
            includePaths = systemPaths ~ includePaths;
    }

    string[] dFileNames() @safe pure const {
        import std.algorithm: map;
        import std.array: array;
        return dppFileNames.map!(a => toDFileName(a)).array;
    }

    string toDFileName(in string dppFileName) @safe pure nothrow const {
        import std.path: stripExtension, dirName, isAbsolute, buildPath, baseName;

        const outputPath = srcOutputPath == ""
            ? dppFileName.dirName
            : srcOutputPath;
        const fileName = dppFileName.baseName.stripExtension ~ ".d";

        return buildPath(outputPath, fileName);
    }

    private void parseArgs(ref string[] args) {
        import std.getopt: getopt, defaultGetoptPrinter, config;
        import std.algorithm : map;
        import std.array : split, join;
        auto helpInfo =
            getopt(
                args,
                config.passThrough,
                "print-cursors", "Print debug information", &debugOutput,
                "include-path", "Include paths", &includePaths,
                "keep-pre-cpp-files", "Do not delete the temporary pre-preprocessed file", &keepPreCppFiles,
                "keep-d-files", "Do not delete the temporary D file to be compiled", &keepDlangFiles,
                "preprocess-only", "Only transform the .dpp file into a .d file, don't compile", &preprocessOnly,
                "compiler", "D compiler to use", &dlangCompiler,
                "parse-as-cpp", "Parse header as C++", &parseAsCpp,
                "define", "C Preprocessor macro", &defines,
                "hard-fail", "Translate nothing if any part fails", &hardFail,
                "mscrtlib",
                    "MS C runtime library to link (e.g. use `--mscrtlib=msvcrtd`, if there are missing references)",
                     &mscrtlib,
                "c++-std-lib", "Link to the C++ standard library", &cppStdLib,
                "ignore-macros", "Ignore preprocessor macros", &ignoreMacros,
                "ignore-specified-macros", "Ignore the specified preprocessor macros", &ignoredMacros,
                "ignore-ns", "Ignore a C++ namespace", &ignoredNamespaces,
                "ignore-cursor", "Ignore a C++ cursor", &ignoredCursors,
                "ignore-path", "Ignore a file path, note it globs so you will want to use *", &ignoredPaths,
                "ignore-system-paths",
                    "Adds system paths to the ignore-paths list (you can add them back individually with --include-path)",
                    &ignoreSystemPaths,
                "prebuilt-header",
                    "Declare a #include can be safely replaced with import. You should also ignore-path to prevent retranslating the file",
                    &prebuiltHeaders,
                "detailed-untranslatables",
                    "Show details about untranslatable cursors",
                    &detailedUntranslatable,
                "scoped-enums", "Don't redeclare enums to mimic C", &alwaysScopedEnums,
                "c++-standard", "The C++ language standard (e.g. \"c++14\")", &cppStandard,
                "clang-option", "Pass option to libclang", &clangOptions,
                "no-sys-headers", "Don't include system headers by default", &noSystemHeaders,
                "cpp-path", "Path to the C preprocessor executable", &cppPath,
                "source-output-path", "Path to emit the resulting D files to", &srcOutputPath,
            );

        clangOptions = map!(e => e.split(" "))(clangOptions).join();
        ignoredMacros = map!(e => e.split(","))(ignoredMacros).join();

        if(helpInfo.helpWanted) {
            () @trusted {
                defaultGetoptPrinter(usage, helpInfo.options);
            }();
            earlyExit = true;
        }

        if(ignoreSystemPaths) {
            import clang: systemPaths;
            import std.algorithm: filter, canFind;
            foreach(sp; systemPaths.filter!(p => !includePaths.canFind(p)))
                ignoredPaths ~= sp ~ "*";
        }
    }

    void indent() @safe pure nothrow {
        indentation += 4;
    }

    Options dup() @safe pure nothrow const {
        Options ret;
        foreach(i, ref elt; ret.tupleof) {
            static if(__traits(compiles, this.tupleof[i].dup))
                elt = this.tupleof[i].dup;
            else static if(is(typeof(this.tupleof[i]) == const(K[V]), K, V))
            {
                try // surprised looping over the AA is not nothrow but meh
                foreach(k, v; this.tupleof[i])
                    elt[k] = v;
                catch(Exception) assert(0);
            }
            else
                elt = this.tupleof[i];
        }

        ret.includePaths = includePaths.dup;
        ret.defines = defines.dup;

        return ret;
    }

    void log(T...)(auto ref T args) @trusted const {
        version(unittest) import unit_threaded.io: writeln = writelnUt;
        else import std.stdio: writeln;

        version(unittest)
            enum shouldLog = true;
        else
            const shouldLog = debugOutput;

        if(shouldLog)
            writeln(indentationString, args);
    }

    private auto indentationString() @safe pure nothrow const {
        import std.array: appender;
        auto app = appender!(char[]);
        app.reserve(indentation);
        foreach(i; 0 .. indentation) app ~= " ";
        return app.data;
    }
}
