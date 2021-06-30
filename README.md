d++ - #include C and C++ headers in D files
====================================================

[![CI](https://github.com/atilaneves/dpp/actions/workflows/d.yml/badge.svg)](https://github.com/atilaneves/dpp/actions/workflows/d.yml)
[![Coverage](https://codecov.io/gh/atilaneves/dpp/branch/master/graph/badge.svg)](https://codecov.io/gh/atilaneves/dpp)
[![Open on run.dlang.io](https://img.shields.io/badge/run.dlang.io-open-blue.svg)](https://run.dlang.io/is/JK0CAf)

Goal
----

To directly `#include` C and C++ headers in [D](https://dlang.org) files and have the same semantics and ease-of-use
as if the file had been `#included` from C or C++ themselves. Warts and all, meaning that C `enum` declarations
will pollute the global namespace, just as it does "back home".

This work was supported by [Symmetry Investments](http://symmetryinvestments.com/).

Example
-------

```c
// c.h
#ifndef C_H
#define C_H

#define FOO_ID(x) (x*3)

int twice(int i);

#endif
```

```c
// c.c
int twice(int i) { return i * 2; }
```

```d
// foo.dpp
#include "c.h"
void main() {
    import std.stdio;
    writeln(twice(FOO_ID(5)));  // yes, it's using a C macro here!
}
```

At the shell:

```
$ gcc -c c.c
$ d++ foo.dpp c.o
$ ./foo
$ 30
```

[![Open on run.dlang.io](https://img.shields.io/badge/run.dlang.io-open-blue.svg)](https://run.dlang.io/is/WwpvhT)

C++ support
-----------

C++ support is currently limited. Including any header from the C++
standard library is unlikely to work.  Simpler headers might, the
probability rising with how similar the C++ dialect used is to
C. Despite that, dpp currently does try to translate classes,
templates and operator overloading. It's unlikely to work on
production headers without judicious use of the `--ignore-cursor` and
`--ignore-namespace` command-line options.  When using these, the user
can then define their own versions of problematic declarations such as
`std::vector`.

Limitations
-----------

* Only known to work on Linux with libclang versions 6 and up. It might work in different conditions.
* When used on multiple files, there might be problems with duplicate definitions depending on imports.
  It is recommended to put all `#include`s in one `.dpp` file and import the resulting D module.
* Not currently able to translate Linux kernel headers.

Success stories
--------------

Known project headers whose translations produce D code that compiles:

* nanomsg/nn.h, nanomsg/pubsub.h
* curl/curl.h
* stdio.h, stdlib.h
* pthread.h
* julia.h
* xlsxwriter.h
* libvirt/libvirt.h, libvirt/virterror.h
* libzfs
* openssl/ssl.h
* imapfilter.h
* libetpan/libetpan.h
* Python.h

Compilation however doesn't guarantee they work as expected and YMMV. Please consult the examples.


Command-line arguments
----------------------

It is likely that the header or headers need `-I` flags to indicate paths to be searched,
both by this executable and by libclang itself. The `--include-path` option can be
used for that, once for each such path.

Use `-h` or `--help` to learn more.


Details
-------

`d++` is an executable that wraps a D compiler such as dmd (the default) so that D files with `#include`
directives can be compiled.

It takes a `.dpp` file and outputs a valid D file that can be compiled. The original can't since D
has no preprocessor, so the `.dpp` file is "quasi-D", or "D with #include directives".
The only supported C preprocessor directive is `#include`.

The input `.dpp` file may also use C preprocessor macros defined in the file(s) it `#include`s, just as a C/C++
program would (see the example above). It may not, however, define macros of its own.

`d++` goes through the input file line-by-line, and upon encountering an `#include` directive, parses
the file to be included with libclang, loops over the definitions of data structures and functions
therein and expands in-place the relevant D translations. e.g. if a header contains:

```c
uint16_t foo(uint32_t a);
```

The output file will contain:

```d
ushort foo(uint a);
```

d++ will also enclose each one of these original `#include` directives with either
`extern(C) {}` or `extern(C++) {}` depending on the header file name and/or command-line options.

As part of expanding the `#include`, and as well as translating declarations, d++ will also
insert text to define macros originally defined in the `#include`d translation unit so that these
macros can be used by the D program. The reason for this is that nearly every non-trivial
C API requires the preprocessor to use properly. It is possible to mimic this usage in D
with enums and CTFE, but the result is not guaranteed to be the same. The only way to use a
C or C++ API as it was intended is by leveraging the preprocessor.

Trivial literal macros however(e.g. `#define THE_ANSWER 42`) are translated as
D enums.

As a final pass before writing the output D file, d++ will run the C
preprocessor (currently the cpp binary installed on the system) on the
intermediary result of expanding all the `#include` directives so that
any used macros are expanded, and the result is a D file that can be compiled.

In this fashion a user can write code that's not-quite-D-but-nearly that can "natively"
call into a C/C++ API by `#include`ing the appropriate header(s).


Translation notes
----------------

### enum

For convenience, this declaration:

```c
enum Enum { foo, bar, baz }
```

Will generate this translation:

```d
enum Enum { foo, bar, baz }
enum foo = Enum.foo;
enum bar = Enum.bar;
enum baz = Enum.baz;
```

This is to mimic C semantics with regards to the global namespace whilst also allowing
one to, say, reflect on the enum type.


### Renaming enums

There is the ability to rename C enums. With the following C definition:

```c
enum FancyWidget { Widget_foo,  Widget_bar }
```

Then adding this to your .dpp file after the `#include` directive:

```d
mixin dpp.EnumD!("Widget",      // the name of the new D enum
                 FancyWidget,   // the name of the original C enum
                 "Widget_");    // the prefix to cut out
```

will yield this translation:

```d
enum Widget { foo, bar }
```



### Names of structs, enums and unions

C has a different namespace for the aforementioned user-defined types. As such, this is legal C:

```c
struct foo { int i; };
extern int foo;
```

The D translations just use the short name for these aggregates, and if there is a name collision
with a variable or function, the latter two get renamed and have a `pragma(mangle)` added to
avoid linker failures:


```d
struct foo { int i; }
pragma(mangle, "foo") extern __gshared int foo_;
```

### Functions or variables with a name that is a D keyword

Similary to name collisions with aggregates, they get an underscore
appended and a `pragma(mangle)` added so they link:

```c
void debug(const char* msg);
```

Becomes:


```d
pragma(mangle, "debug")
void debug_(const(char)*);
```


Build Instructions
------------------
```
dub install dpp
```

After the instructions for your OS (see below), you can use this commands to run dpp:

```
dub run dpp -- yoursourcefilenamehere.dpp
```

### Windows

Install [LLVM](https://github.com/llvm/llvm-project/releases/download/llvmorg-12.0.0/LLVM-12.0.0-win64.exe) into `C:\Program Files\LLVM\`, making sure to tick the "Add LLVM to the system PATH for all users" option.

If `libclang.lib` was not found, put the `lib` folder of the llvm directory on the PATH.

### Linux

If `libclang` is not installed, install `libclang-10-dev` with apt: `sudo apt-get install -y -qq libclang-10-dev`

If `libclang.so` was not found, link it using the following command (adjust the installation path and the llvm version):
```
sudo ln -s path_to_llvm/lib/libclang-12.so.1 /lib/x86_64-linux-gnu/libclang.so
```

### MacOS

If using an external LLVM installation, add these to your `~/.bash_profile`

```bash
LLVM_PATH="/usr/local/opt/llvm/" # or any other path
LLVM_VERSION="11.0.0"
export PATH="$LLVM_PATH:$PATH"
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export LD_LIBRARY_PATH="$LLVM_PATH/lib/:$LD_LIBRARY_PATH"
export DYLD_LIBRARY_PATH="$LLVM_PATH/lib/:$DYLD_LIBRARY_PATH"
export CPATH="$LLVM_PATH/lib/clang/$LLVM_VERSION/include/"
export LDFLAGS="-L$LLVM_PATH/lib"
export CPPFLAGS="-I$LLVM_PATH/include"
export CC="$LLVM_PATH/bin/clang"
export CXX="$LLVM_PATH/bin/clang++"
```

(adjust the clang version and the external llvm installation path.)

Then run `source ~/.bash_profile`

If `libclang.dylib` was not found, link it using the following command (adjust the installation path):
```
ln -s path_to_llvm/lib/libclang.dylib /usr/local/opt/llvm/lib/libclang.dylib
```
