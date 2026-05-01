# 第 35 部分：C 预处理器

在编译器编写之旅的这一部分里，
我加入了对“外部 C 预处理器”的支持，
同时也把 `extern` 关键字加进了语言里。

我们现在终于走到了这样一个阶段：
已经可以为程序写
[头文件（header file）](https://www.tutorialspoint.com/cprogramming/c_header_files.htm)，
也可以把注释放进这些头文件里了。
老实说，
这件事让我很高兴。

## C 预处理器

我不打算在这里详细介绍 C 预处理器本身，
虽然它确实是任何 C 环境里都非常重要的一部分。
我更愿意直接把这两篇资料留给你：

 + [C Preprocessor](https://en.wikipedia.org/wiki/C_preprocessor) at *Wikipedia*
 + [C Preprocessor and Macros](https://www.programiz.com/c-programming/c-preprocessor-macros) at *www.programiz.com*

## 接入 C 预处理器

在像 [SubC](http://www.t3x.org/subc/) 这样的编译器里，
预处理器是直接内建在语言中的。
而我这里决定采用系统外部的 C 预处理器，
通常也就是
[Gnu C pre-processor](https://gcc.gnu.org/onlinedocs/cpp/)。

在我展示自己怎么接入它之前，
我们得先看看：
预处理器在工作时会插入什么样的行。

考虑下面这个短程序（我顺手标了行号）：

```c
1 #include <stdio.h>
2 
3 int main() {
4   printf("Hello world\n");
5   return(0);
6 }
```

而在预处理之后，
我们这个编译器接收到的输入可能会长成这样：

```c
# 1 "z.c"
# 1 "<built-in>"
# 1 "<command-line>"
# 1 "z.c"
# 1 "include/stdio.h" 1
# 1 "include/stddef.h" 1

typedef long size_t;
# 5 "include/stdio.h" 2

typedef char * FILE;

FILE *fopen(char *pathname, char *mode);
...
# 2 "z.c" 2

int main() {
  printf("Hello world\n");
  return(0);
}
```

每一行预处理器指令都以 `#` 开头，
后面跟着“下一行的行号”，
再后面是“这行代码来自哪个文件”的文件名。
至于某些行尾那些额外的数字，
我其实也不完全清楚它们具体含义。
我猜，
当一个文件 include 另一个文件时，
这些数字大概和“发起 include 的文件行号”有关。

下面就是我准备把预处理器接进编译器的方法。
我会用 `popen()` 打开一条来自子进程的管道，
而这个子进程本身就是预处理器。
然后让预处理器去处理我们的输入文件。
接着再修改词法扫描器，
让它能识别这些预处理器插入的行，
并据此更新“当前行号”和“当前文件名”。

## 对 `main.c` 的修改

我们在 `data.h` 中新增了一个全局变量：`char *Infilename`。
在 `main.c` 的 `do_compile()` 中，
现在会这样做：

```c
// Given an input filename, compile that file
// down to assembly code. Return the new file's name
static char *do_compile(char *filename) {
  char cmd[TEXTLEN];
  ...
  // Generate the pre-processor command
  snprintf(cmd, TEXTLEN, "%s %s %s", CPPCMD, INCDIR, filename);

  // Open up the pre-processor pipe
  if ((Infile = popen(cmd, "r")) == NULL) {
    fprintf(stderr, "Unable to open %s: %s\n", filename, strerror(errno));
    exit(1);
  }
  Infilename = filename;
```

这段代码本身很直白，
唯一还没解释的是：
`CPPCMD` 和 `INCDIR` 到底从哪来。

`CPPCMD` 在 `defs.h` 中被定义成预处理器命令本身：

```c
#define CPPCMD "cpp -nostdinc -isystem "
```

它告诉 Gnu 预处理器：
不要去使用标准头文件目录 `/usr/include`；
相反，
`-isystem` 会要求预处理器改用命令行里的下一个参数，
也就是 `INCDIR`。

而 `INCDIR` 实际上定义在 `Makefile` 中，
因为这类“可配置路径”本来就很适合放在这里：

```make
# Define the location of the include directory
# and the location to install the compiler binary
INCDIR=/tmp/include
BINDIR=/tmp
```

编译器二进制现在会通过这条 `Makefile` 规则编译出来：

```make
cwj: $(SRCS) $(HSRCS)
        cc -o cwj -g -Wall -DINCDIR=\"$(INCDIR)\" $(SRCS)
```

这样就能把 `/tmp/include` 这个值作为 `INCDIR`
传进编译过程。
那接下来问题就是：
`/tmp/include` 什么时候会被创建？
里面又会放些什么？

## 我们的第一批头文件

在当前目录下的 `include/` 子目录里，
我已经开始准备一批
“足够简单，能被我们自己的编译器消化掉”的头文件。
我们当然不能直接拿系统自带的真实头文件来用，
因为里面会出现这种东西：

```c
extern int _IO_feof (_IO_FILE *__fp) __attribute__ ((__nothrow__ , __leaf__));
extern int _IO_ferror (_IO_FILE *__fp) __attribute__ ((__nothrow__ , __leaf__));
```

这会让我们的编译器当场崩溃。
所以 `Makefile` 里现在还有一条规则，
用来把我们自己写的头文件复制到 `INCDIR` 目录：

```make
install: cwj
        mkdir -p $(INCDIR)
        rsync -a include/. $(INCDIR)
        cp cwj $(BINDIR)
        chmod +x $(BINDIR)/cwj
```

## 扫描预处理器输出

所以现在我们的输入，
已经不再是直接读取原源文件，
而是读取“预处理器处理后的输出”。
接下来我们必须识别这些预处理器指令行，
并根据它们更新“下一行的行号”以及“当前行来自哪个文件”。

我把这部分逻辑放进了扫描器里，
因为扫描器本来就负责维护行号。
所以在 `scan.c` 中，
我对 `scan()` 做了下面这处修改：

```c
// Get the next character from the input file.
static int next(void) {
  int c, l;

  if (Putback) {                        // Use the character put
    c = Putback;                        // back if there is one
    Putback = 0;
    return (c);
  }

  c = fgetc(Infile);                    // Read from input file

  while (c == '#') {                    // We've hit a pre-processor statement
    scan(&Token);                       // Get the line number into l
    if (Token.token != T_INTLIT)
      fatals("Expecting pre-processor line number, got:", Text);
    l = Token.intvalue;

    scan(&Token);                       // Get the filename in Text
    if (Token.token != T_STRLIT)
      fatals("Expecting pre-processor file name, got:", Text);

    if (Text[0] != '<') {               // If this is a real filename
      if (strcmp(Text, Infilename))     // and not the one we have now
        Infilename = strdup(Text);      // save it. Then update the line num
      Line = l;
    }

    while ((c = fgetc(Infile)) != '\n'); // Skip to the end of the line
    c = fgetc(Infile);                  // and get the next character
  }

  if ('\n' == c)
    Line++;                             // Increment line count
  return (c);
}
```

这里之所以用 `while`，
是因为预处理器指令行可能连续出现多条。
比较幸运的是，
我们可以递归调用 `scan()`，
先把行号当成 `T_INTLIT` 扫进来，
再把文件名当成 `T_STRLIT` 扫进来。

这段代码会忽略那些被 `<...>` 包起来的“文件名”，
因为它们并不代表真实文件。
我们确实还得对文件名做一次 `strdup()`，
因为它当前仍然放在全局 `Text` 里，
后面肯定会被覆盖掉。
不过如果 `Text` 里的名字和当前 `Infilename` 已经相同，
那就没必要重复分配。

等拿到行号和文件名之后，
我们就把这一整行剩余内容跳掉，
并再往后读一个字符，
然后回到原本的字符扫描流程里。

结果证明：
把 C 预处理器接进编译器这件事，
比我原先担心的要简单得多。

## 防止不必要的函数 / 变量重复声明

很多头文件会 include 其他头文件，
因此非常容易出现：
同一个头文件被间接 include 多次。
这就会导致相同的函数和 / 或全局变量被重复声明。

为了避免这种情况，
我采用了头文件里最常见的那套机制：
第一次 include 时定义一个“头文件专属宏”，
之后如果再次 include 同一文件，
就能阻止文件内容被重复展开。

例如，
现在 `include/stdio.h` 大概长这样：

```c
#ifndef _STDIO_H_
# define _STDIO_H_

#include <stddef.h>

// This FILE definition will do for now
typedef char * FILE;

FILE *fopen(char *pathname, char *mode);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(void *ptr, size_t size, size_t nmemb, FILE *stream);
int fclose(FILE *stream);
int printf(char *format);
int fprintf(FILE *stream, char *format);

#endif  // _STDIO_H_
```

只要 `_STDIO_H_` 已经定义过一次，
这个文件的内容就不会被再次包含进来。

## `extern` 关键字

既然现在预处理器已经工作起来了，
我觉得也是时候把 `extern` 关键字加入语言了。
这样我们就可以声明一个全局变量，
但不为它生成存储空间；
默认假设是：
这个变量已经在另一个源文件里被定义成全局变量了。

`extern` 的加入实际上会影响到好几个文件。
影响不大，
但涉及面还挺广。
下面逐一来看。

### 一个新 token 与关键字

所以现在我们又新增了一个关键字 `extern`，
以及对应的 token `T_EXTERN`。
照例，
`scan.c` 里的具体代码你可以自己去翻。

### 一个新的 class

在 `defs.h` 中，
我们现在有了一个新的存储类别：

```c
// Storage classes
enum {
  C_GLOBAL = 1,                 // Globally visible symbol
  ...
  C_EXTERN,                     // External globally visible symbol
  ...
};
```

我之所以要加这个，
是因为 `sym.c` 中原本就有这样一段针对全局符号的逻辑：

```c
// Create a symbol node to be added to a symbol table list.
struct symtable *newsym(char *name, int type, struct symtable *ctype,
                        int stype, int class, int size, int posn) {
  // Get a new node
  struct symtable *node = (struct symtable *) malloc(sizeof(struct symtable));
  // Fill in the values
  ...
    // Generate any global space
  if (class == C_GLOBAL)
    genglobsym(node);
```

我们确实希望把 `extern` 符号加入全局链表，
但又不希望调用 `genglobsym()` 为它真正分配空间。
所以必须传给 `newsym()` 一个“不是 `C_GLOBAL`”的 class。

### 对 `sym.c` 的修改

为了做到这一点，
我修改了 `addglob()`，
让它接收一个 `class` 参数，
并把这个参数继续传给 `newsym()`：

```c
// Add a symbol to the global symbol list
struct symtable *addglob(char *name, int type, struct symtable *ctype,
                         int stype, int class, int size) {
  struct symtable *sym = newsym(name, type, ctype, stype, class, size, 0);
  appendsym(&Globhead, &Globtail, sym);
  return (sym);
}
```

这也就意味着：
编译器里凡是调用 `addglob()` 的地方，
现在都必须显式传入一个 `class` 值。
以前 `addglob()` 会自己固定把 `C_GLOBAL` 传给 `newsym()`；
现在则改成由调用方来决定。

### `extern` 关键字与我们的语法

从语法上说，
我这里会强行规定：
`extern` 必须出现在类型描述的最前面。
后面我还打算把 `static` 也一起纳入这套规则。
我们在之前看过的那份
[C 的 BNF 语法](https://www.lysator.liu.se/c/ANSI-C-grammar-y.html)
中，
相关产生式大概是这样：

```
storage_class_specifier
        : TYPEDEF
        | EXTERN
        | STATIC
        | AUTO
        | REGISTER
        ;

type_specifier
        : VOID
        | CHAR
        | SHORT
        | INT
        | LONG
        | FLOAT
        | DOUBLE
        | SIGNED
        | UNSIGNED
        | struct_or_union_specifier
        | enum_specifier
        | TYPE_NAME
        ;

declaration_specifiers
        : storage_class_specifier
        | storage_class_specifier declaration_specifiers
        | type_specifier
        | type_specifier declaration_specifiers
        | type_qualifier
        | type_qualifier declaration_specifiers
        ;

```

我觉得这套规则基本允许 `extern`
出现在类型说明中的任意位置。
不过没关系，
我们本来就在构建一个 C 语言子集。

### 解析 `extern` 关键字

和过去五六部分一样，
这次我又改了 `decl.c` 里的 `parse_type()`：

```c
int parse_type(struct symtable **ctype, int *class) {
  int type, exstatic=1;

  // See if the class has been changed to extern (later, static)
  while (exstatic) {
    switch (Token.token) {
      case T_EXTERN: *class= C_EXTERN; scan(&Token); break;
      default: exstatic= 0;
    }
  }
  ...
}
```

现在 `parse_type()` 多了第二个参数：`int *class`。
这允许调用者先传入一个初始存储类别
（通常可能是 `C_GLOBAL`、`C_LOCAL` 或 `C_PARAM`）。
如果 `parse_type()` 读到了 `extern`，
它就能把这个 class 改成 `C_EXTERN`。
另外顺便说一句，
我确实没想出比 `exstatic` 更顺手的布尔变量名了。

### `parse_type()` 与 `addglob()` 的调用方

既然我们已经改了 `parse_type()` 和 `addglob()` 的参数列表，
那就得把编译器里所有调用它们的地方都找出来，
确保传进去的 `class` 值合理。

在 `decl.c` 的 `var_declaration_list()` 中，
我们本来就已经能拿到这些变量的存储类别：

```c
static int var_declaration_list(struct symtable *funcsym, int class,
                                int separate_token, int end_token);
```

于是现在可以把这个 `class` 传给 `parse_type()`，
让它有机会修改；
然后再把实际 class 传给 `var_declaration()`：

```c
    ...
    // Get the type and identifier
    type = parse_type(&ctype, &class);
    ident();
    ...
    // Add a new parameter to the right symbol table list, based on the class
    var_declaration(type, ctype, class);
```

而在 `var_declaration()` 里：

```c
      switch (class) {
        case C_EXTERN:
        case C_GLOBAL:
          sym = addglob(Text, type, ctype, S_VARIABLE, class, 1);
        ...
      }
```

对局部变量来说，
我们还得看看 `stmt.c` 里的 `single_statement()`。
另外我也得顺便承认一下，
我之前还漏掉了 struct、union、enum 和 typedef
在这里的几个 case。

```c
// Parse a single statement and return its AST
static struct ASTnode *single_statement(void) {
  int type, class= C_LOCAL;
  struct symtable *ctype;

  switch (Token.token) {
    case T_IDENT:
      // We have to see if the identifier matches a typedef.
      // If not do the default code in this switch statement.
      // Otherwise, fall down to the parse_type() call.
      if (findtypedef(Text) == NULL)
        return (binexpr(0));
    case T_CHAR:
    case T_INT:
    case T_LONG:
    case T_STRUCT:
    case T_UNION:
    case T_ENUM:
    case T_TYPEDEF:
      // The beginning of a variable declaration.
      // Parse the type and get the identifier.
      // Then parse the rest of the declaration
      // and skip over the semicolon
      type = parse_type(&ctype, &class);
      ident();
      var_declaration(type, ctype, class);
      semi();
      return (NULL);            // No AST generated here
      ...
   }
   ...
}
```

注意我们一开始设的是 `class = C_LOCAL`，
但在把它传给 `var_declaration()` 之前，
`parse_type()` 完全可能把它改掉。
这样就允许我们写出这样的代码：

```c
int main() {
  extern int foo;
  ...
}
```

## 测试代码

我这里只有一个测试程序 `test/input70.c`，
它会使用我们新写的某个头文件，
用来确认预处理器是否工作正常：

```c
#include <stdio.h>

typedef int FOO;

int main() {
  FOO x;
  x= 56;
  printf("%d\n", x);
  return(0);
}
```

我本来还希望 `errno` 依旧只是一个普通整数，
那我就可以在 `include/errno.h` 里写 `extern int errno;`。
但看起来，
现在的 `errno` 已经变成了一个函数，
而不是全局整型变量。
我想这同时说明了两件事：
a) 我到底有多老；
b) 我到底有多久没认真写过 C 代码了。

## 总结与下一步

我觉得这又是一个里程碑。
我们现在已经有了外部变量和头文件。
这也意味着，
*终于*，
我们能在源码里写注释了。
这一点让我非常高兴。

现在这套编译器大概已经超过 4,100 行代码，
其中大约 2,800 行既不是注释也不是空白。
我完全不知道还需要多少行代码，
才能把它推进到“可以自举编译自己”的程度，
但我愿意随便猜一个区间：
也许最终会落在 7,000 到 9,000 行之间。走着看吧。

在编译器编写之旅的下一部分中，
我们会给循环结构加入 `break` 和 `continue` 关键字。 [下一步](../36_Break_Continue/Readme.md)
