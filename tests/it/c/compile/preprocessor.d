module it.c.compile.preprocessor;


import it;


@("simple macro")
@safe unittest {
    shouldCompile(
        C(
            `
                #define FOO 5
            `
        ),
        D(
            q{
                int[FOO] foos;
                static assert(foos.length == 5, "Wrong length for foos");
            }
        )
    );
}

@("define macro, undefine, then define again")
@safe unittest {
    shouldCompile(
        C(
            `
                #define FOO foo
                #undef FOO
                #define FOO bar
                int FOO(int i);
            `
        ),
        D(
            q{
                int i = bar(2);
            }
        )
    );
}


@("include guards")
@safe unittest {
    with(immutable IncludeSandbox()) {
        writeFile("hdr.h",
                  `#ifndef HAHA
                   #    define HAHA
                   int inc(int);
                   #endif`);
        writeFile("foo.dpp",
                  `#include "hdr.h"
                   import bar;
                   int func(int i) { return inc(i) * 2; }`);
        writeFile("bar.dpp",
                  `#include "hdr.h";
                   int func(int i) { return inc(i) * 3; }`);

        runPreprocessOnly("foo.dpp");
        runPreprocessOnly("bar.dpp");
        shouldCompile("foo.d");
    }
}


@("octal.whitespace")
@safe unittest {
    shouldCompile(
        C(
            `
                #define FOO	   00
            `
        ),
        D(
            q{
            }
        )
    );

}


@("elaborate")
@safe unittest {
    shouldCompile(
        C(
            `
                struct Foo {};
                #define STRUCT_HEAD \
                    int count; \
                    struct Foo *foo;
            `
        ),
        D(
            q{
                static struct Derived {
                    STRUCT_HEAD
                }

                auto d = Derived();
                d.count = 42;
                d.foo = null;
            }
        )
    );
}


version(Posix)  // FIXME
@("multiline")
@safe unittest {
    shouldCompile(
        C(
            `
                // WARNING: don't attempt to tidy up the formatting here or the
                // test is actually changed
#define void_to_int_ptr(x) ( \
    (int *) x \
)
            `
        ),
        D(
            q{
                import std.stdio: writeln;
                int a = 7;
                void *p = &a;
                auto intPtr = void_to_int_ptr(p);
            }
        )
    );
}

@("macro function's parameter name is a type")
@safe unittest {
    shouldCompile(
        C(
            `
                struct Foo {};
                void actual_func(struct Foo*);
                #define func(Foo) actual_func(Foo)
            `
        ),
        D(
            q{
	        void actual_func(Foo *) {}
	        Foo *f;
		func(f);
            }
        )
    );
}
