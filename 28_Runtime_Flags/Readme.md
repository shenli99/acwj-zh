# 第 28 部分：加入更多运行时参数

这一部分的编译器编写之旅，
其实和扫描、解析、语义分析或代码生成都没什么直接关系。
这一部分里，
我给编译器加上了 `-c`、`-S` 和 `-o` 这几个运行时参数，
让它表现得更像传统的 Unix C 编译器。

所以，
如果你对这类内容不感兴趣，
完全可以直接跳到下一部分。

## 编译阶段

到目前为止，
我们的编译器一直只输出汇编文件。
但把一个高级语言源文件变成可执行文件，
中间其实还要经过更多步骤：

 + 扫描并解析源代码，生成汇编输出
 + 把汇编代码组装成[目标文件（object file）](https://en.wikipedia.org/wiki/Object_file)
 + 将一个或多个目标文件进行[链接（link）](https://en.wikipedia.org/wiki/Linker_(computing))，生成可执行文件

前两步后面的“汇编”和“链接”，
我们一直是手工做，
或者交给 Makefile 处理。
而现在，
我准备修改编译器，
让它直接调用外部汇编器和链接器来完成后两步。

为此，
我会重新整理 `main.c` 中的一些代码，
并在 `main.c` 里再写几个函数来负责汇编与链接。
这部分大多数代码，
本质上都是很典型的 C 语言字符串处理和文件处理逻辑，
所以我会把代码走一遍；
不过如果你以前已经很熟这种代码，
它未必特别有趣。

## 解析命令行参数

我把编译器重命名成了 `cwj`，
对应这个项目的名字。
现在如果你不给它任何命令行参数，
它会打印出下面这段用法说明：

```
$ ./cwj 
Usage: ./cwj [-vcST] [-o outfile] file [file ...]
       -v give verbose output of the compilation stages
       -c generate object files but don't link them
       -S generate assembly files but don't link them
       -T dump the AST trees for each input file
       -o outfile, produce the outfile executable file
```

现在我们允许输入多个源文件。
同时有四个布尔开关：
`-v`、`-c`、`-S` 和 `-T`，
并且也可以指定最终输出的可执行文件名。

`main()` 里解析 `argv[]` 的代码
因此也得随之调整，
并且新增了若干选项变量来保存结果。

```c
  // Initialise our variables
  O_dumpAST = 0;        // If true, dump the AST trees
  O_keepasm = 0;        // If true, keep any assembly files
  O_assemble = 0;       // If true, assemble the assembly files
  O_dolink = 1;         // If true, link the object files
  O_verbose = 0;        // If true, print info on compilation stages

  // Scan for command-line options
  for (i = 1; i < argc; i++) {
    // No leading '-', stop scanning for options
    if (*argv[i] != '-')
      break;

    // For each option in this argument
    for (int j = 1; (*argv[i] == '-') && argv[i][j]; j++) {
      switch (argv[i][j]) {
      case 'o':
        outfilename = argv[++i]; break;         // Save & skip to next argument
      case 'T':
        O_dumpAST = 1; break;
      case 'c':
        O_assemble = 1; O_keepasm = 0; O_dolink = 0; break;
      case 'S':
        O_keepasm = 1; O_assemble = 0; O_dolink = 0; break;
      case 'v':
        O_verbose = 1; break;
      default:
        usage(argv[0]);
      }
    }
  }
```

注意，
其中有些选项是互斥的。
比如如果用了 `-S`，
我们只想要汇编输出，
那自然就不应该再去链接，
也不该再生成目标文件。

## 执行编译阶段

把命令行参数解析完后，
我们就可以开始执行编译各阶段了。
对每个输入文件来说，
编译和汇编都很直接；
但最后链接时，
可能会有若干个目标文件需要一起处理。
因此我们在 `main()` 里准备了一些局部变量来存这些目标文件名：

```c
#define MAXOBJ 100
  char *objlist[MAXOBJ];        // List of object file names
  int objcnt = 0;               // Position to insert next name
```

首先，
我们会依次处理所有输入源文件：

```c
  // Work on each input file in turn
  while (i < argc) {
    asmfile = do_compile(argv[i]);      // Compile the source file

    if (O_dolink || O_assemble) {
      objfile = do_assemble(asmfile);   // Assemble it to object format
      if (objcnt == (MAXOBJ - 2)) {
        fprintf(stderr, "Too many object files for the compiler to handle\n");
        exit(1);
      }
      objlist[objcnt++] = objfile;      // Add the object file's name
      objlist[objcnt] = NULL;           // to the list of object files
    }

    if (!O_keepasm)                     // Remove the assembly file if
      unlink(asmfile);                  // we don't need to keep it
    i++;
  } 
```

`do_compile()` 里装着的，
就是原先 `main()` 中那段
“打开文件、自己解析并生成汇编文件”的逻辑。
不过我们现在不能再像以前那样，
把输出文件名硬编码成 `out.s` 了；
而是得把 `filename.c` 转成 `filename.s`。

## 修改输入文件名

为此我们写了一个小的文件名辅助函数。

```c
// Given a string with a '.' and at least a 1-character suffix
// after the '.', change the suffix to be the given character.
// Return the new string or NULL if the original string could
// not be modified
char *alter_suffix(char *str, char suffix) {
  char *posn;
  char *newstr;

  // Clone the string
  if ((newstr = strdup(str)) == NULL) return (NULL);

  // Find the '.'
  if ((posn = strrchr(newstr, '.')) == NULL) return (NULL);

  // Ensure there is a suffix
  posn++;
  if (*posn == '\0') return (NULL);

  // Change the suffix and NUL-terminate the string
  *posn++ = suffix; *posn = '\0';
  return (newstr);
}
```

真正做事的核心其实只有 `strdup()`、`strrchr()`，
以及最后那两行；
其余大多只是错误检查。

## 执行编译

下面就是我们原先那段代码，
现在被重新包装成了一个新函数：

```c
// Given an input filename, compile that file
// down to assembly code. Return the new file's name
static char *do_compile(char *filename) {
  Outfilename = alter_suffix(filename, 's');
  if (Outfilename == NULL) {
    fprintf(stderr, "Error: %s has no suffix, try .c on the end\n", filename);
    exit(1);
  }
  // Open up the input file
  if ((Infile = fopen(filename, "r")) == NULL) {
    fprintf(stderr, "Unable to open %s: %s\n", filename, strerror(errno));
    exit(1);
  }
  // Create the output file
  if ((Outfile = fopen(Outfilename, "w")) == NULL) {
    fprintf(stderr, "Unable to create %s: %s\n", Outfilename,
            strerror(errno));
    exit(1);
  }

  Line = 1;                     // Reset the scanner
  Putback = '\n';
  clear_symtable();             // Clear the symbol table
  if (O_verbose)
    printf("compiling %s\n", filename);
  scan(&Token);                 // Get the first token from the input
  genpreamble();                // Output the preamble
  global_declarations();        // Parse the global declarations
  genpostamble();               // Output the postamble
  fclose(Outfile);              // Close the output file
  return (Outfilename);
}
```

这里几乎没有新增太多代码，
主要就是调用 `alter_suffix()` 来得到正确的输出文件名。

不过有一个重要变化：
汇编输出文件名现在放在一个全局变量 `Outfilename` 中。
这样一来，
`misc.c` 中的 `fatal()` 及其相关函数
就能在“汇编文件尚未完整生成”的情况下把残留文件删掉。
例如：

```c
// Print out fatal messages
void fatal(char *s) {
  fprintf(stderr, "%s on line %d\n", s, Line);
  fclose(Outfile);
  unlink(Outfilename);
  exit(1);
}
```

## 组装上面的输出

既然现在我们已经能生成汇编输出文件了，
下一步当然就可以调用外部汇编器。
在 `defs.h` 中，
这个命令被定义为 `ASCMD`。
下面是负责汇编的函数：

```c
#define ASCMD "as -o "
// Given an input filename, assemble that file
// down to object code. Return the object filename
char *do_assemble(char *filename) {
  char cmd[TEXTLEN];
  int err;

  char *outfilename = alter_suffix(filename, 'o');
  if (outfilename == NULL) {
    fprintf(stderr, "Error: %s has no suffix, try .s on the end\n", filename);
    exit(1);
  }
  // Build the assembly command and run it
  snprintf(cmd, TEXTLEN, "%s %s %s", ASCMD, outfilename, filename);
  if (O_verbose) printf("%s\n", cmd);
  err = system(cmd);
  if (err != 0) { fprintf(stderr, "Assembly of %s failed\n", filename); exit(1); }
  return (outfilename);
}
```

这里我用 `snprintf()` 来拼出要执行的汇编命令。
如果用户开启了 `-v` 命令行参数，
这个命令也会被打印出来。
随后再用 `system()` 去执行这条 Linux 命令。
例如：

```
$ ./cwj -v -c tests/input54.c 
compiling tests/input54.c
as -o  tests/input54.o tests/input54.s
```

## 链接目标文件

在 `main()` 里，
我们已经把 `do_assemble()` 返回的目标文件名都攒进了一个列表：

```c
      objlist[objcnt++] = objfile;      // Add the object file's name
      objlist[objcnt] = NULL;           // to the list of object files
```

因此等到真正要把它们全部链接起来时，
就需要把这个列表传给 `do_link()`。
它的代码和 `do_assemble()` 很像，
同样会用到 `snprintf()` 和 `system()`。
区别在于，
这里我们必须跟踪：
命令缓冲区当前写到了哪里，
以及还剩多少可用空间，
好继续追加更多 `snprintf()` 的内容。

```c
#define LDCMD "cc -o "
// Given a list of object files and an output filename,
// link all of the object filenames together.
void do_link(char *outfilename, char *objlist[]) {
  int cnt, size = TEXTLEN;
  char cmd[TEXTLEN], *cptr;
  int err;

  // Start with the linker command and the output file
  cptr = cmd;
  cnt = snprintf(cptr, size, "%s %s ", LDCMD, outfilename);
  cptr += cnt; size -= cnt;

  // Now append each object file
  while (*objlist != NULL) {
    cnt = snprintf(cptr, size, "%s ", *objlist);
    cptr += cnt; size -= cnt; objlist++;
  }

  if (O_verbose) printf("%s\n", cmd);
  err = system(cmd);
  if (err != 0) { fprintf(stderr, "Linking failed\n"); exit(1); }
}
```

这里有个烦人的地方：
我现在仍然是在调用外部 C 编译器 `cc` 来帮我们做链接。
理论上，
我们其实应该能摆脱对“另一个编译器”的这层依赖。

很久以前，
你是可以手工把几个目标文件直接链接起来的，
例如：

```
  $ ln -o out /lib/crt0.o file1.o file.o /usr/lib/libc.a
```

我猜在现在的 Linux 上，
应该也还是能找到类似做法；
但目前为止，
我的 Google-fu 还不够强，
还没完全搞清楚该怎么写。
如果你读到这里并且知道答案，
欢迎告诉我！

## 告别 `printint()` 和 `printchar()`

既然现在我们已经能在自己编译出来的程序里直接调用 `printf()`，
那手写的 `printint()` 和 `printchar()` 就不再需要了。
我已经删掉了 `lib/printint.c`，
并把 `tests/` 目录下的所有测试都改成使用 `printf()`。

我也顺手更新了 `tests/mktests` 与 `tests/runtests` 脚本，
以及顶层 `Makefile`，
让它们都配合新的编译器命令行参数工作。
因此现在执行 `make test`，
回归测试依然能够正常跑通。

## 总结与下一步

这一部分差不多就是这些内容。
现在我们的编译器，
已经更像我熟悉的那类传统 Unix 编译器了。

我之前确实说过，
这一部分还想加入对外部预处理器（external pre-processor）的支持；
但最后我决定先不做。
主要原因是：
如果要支持它，
我还得额外去解析预处理器嵌入在输出中的文件名和行号信息，
例如：

```c
# 1 "tests/input54.c"
# 1 "<built-in>"
# 1 "<command-line>"
# 31 "<command-line>"
# 1 "/usr/include/stdc-predef.h" 1 3 4
# 32 "<command-line>" 2
# 1 "tests/input54.c"
int printf(char *fmt);

int main()
{
  int i;
  for (i=0; i < 20; i++) {
    printf("Hello world, %d\n", i);
  }
  return(0);
}
```

在编译器编写之旅的下一部分中，
我们会开始考虑怎样把结构体（struct）支持加进编译器。
在真正改代码之前，
我想大概率还得再先做一次设计。 [下一步](../29_Refactoring/Readme.md)
