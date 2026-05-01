# 第 23 部分：局部变量

我刚刚已经按照上一部分里描述的设计思路，
把基于栈的局部变量实现出来了，
而且整体进展相当顺利。
下面我会概述实际做过的代码改动。

## 符号表的变更

先从符号表说起，
因为它正是“同时支持全局和局部两种变量作用域”的核心。
现在符号表项的结构如下（位于 `defs.h`）：

```c
// Storage classes
enum {
        C_GLOBAL = 1,           // Globally visible symbol
        C_LOCAL                 // Locally visible symbol
};

// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
  int type;                     // Primitive type for the symbol
  int stype;                    // Structural type for the symbol
  int class;                    // Storage class for the symbol
  int endlabel;                 // For functions, the end label
  int size;                     // Number of elements in the symbol
  int posn;                     // For locals,the negative offset 
                                // from the stack base pointer
};
```

这里新增了 `class` 和 `posn` 两个字段。
正如上一部分所说，
`posn` 为负值，
保存的是相对于栈基指针的偏移量，
也就是局部变量在栈上的存储位置。
这一部分里我只实现了局部变量，
还没有实现参数。
另外也请注意：
现在符号会被标记成 `C_GLOBAL` 或 `C_LOCAL`。

符号表本身的名字也改了，
连同用于索引它的变量一起改到了下面这样（位于 `data.h`）：

```c
extern_ struct symtable Symtable[NSYMBOLS];     // Global symbol table
extern_ int Globs;                              // Position of next free global symbol slot
extern_ int Locls;                              // Position of next free local symbol slot
```

从视觉上看，
全局符号存放在符号表左侧，
`Globs` 指向下一个空闲的全局符号槽位；
而 `Locls` 指向下一个空闲的局部符号槽位。

```
0xxxx......................................xxxxxxxxxxxxNSYMBOLS-1
     ^                                    ^
     |                                    |
   Globs                                Locls
```

在 `sym.c` 里，
除了原本已经有的 `findglob()` 和 `newglob()`
用于查找 / 分配全局符号之外，
现在还新增了 `findlocl()` 和 `newlocl()`。
它们会检测 `Globs` 与 `Locls` 是否发生碰撞：

```c
// Get the position of a new global symbol slot, or die
// if we've run out of positions.
static int newglob(void) {
  int p;

  if ((p = Globs++) >= Locls)
    fatal("Too many global symbols");
  return (p);
}

// Get the position of a new local symbol slot, or die
// if we've run out of positions.
static int newlocl(void) {
  int p;

  if ((p = Locls--) <= Globs)
    fatal("Too many local symbols");
  return (p);
}
```

现在还有了一个通用函数 `updatesym()`，
专门负责设置某个符号表项的所有字段。
我就不把代码展开了，
因为它本质上只是逐个字段赋值。

`updatesym()` 会被 `addglobl()` 和 `addlocl()` 调用。
这两个函数会先尝试查找已有符号；
如果找不到，
就分配一个新的；
然后再调用 `updatesym()` 填好字段。
最后还有一个新函数 `findsymbol()`，
会同时在符号表的局部区和全局区搜索一个符号：

```c
// Determine if the symbol s is in the symbol table.
// Return its slot position or -1 if not found.
int findsymbol(char *s) {
  int slot;

  slot = findlocl(s);
  if (slot == -1)
    slot = findglob(s);
  return (slot);
}
```

在编译器剩余代码里，
原本对 `findglob()` 的调用，
现在基本都替换成了 `findsymbol()`。

## 声明解析的变更

现在我们必须同时支持解析“全局变量声明”和“局部变量声明”。
目前来看，
它们的解析逻辑是一样的，
所以我给函数加了一个标志位来区分：

```c
void var_declaration(int type, int islocal) {
    ...
      // Add this as a known array
      if (islocal) {
        addlocl(Text, pointer_to(type), S_ARRAY, 0, Token.intvalue);
      } else {
        addglob(Text, pointer_to(type), S_ARRAY, 0, Token.intvalue);
      }
    ...
    // Add this as a known scalar
    if (islocal) {
      addlocl(Text, type, S_VARIABLE, 0, 1);
    } else {
      addglob(Text, type, S_VARIABLE, 0, 1);
    }
    ...
}
```

目前编译器里有两处会调用 `var_declaration()`。
第一处在 `decl.c` 的 `global_declarations()` 里，
用于解析全局变量声明：

```c
void global_declarations(void) {
      ...
      // Parse the global variable declaration
      var_declaration(type, 0);
      ...
}
```

另一处在 `stmt.c` 的 `single_statement()` 里，
用于解析局部变量声明：

```c
static struct ASTnode *single_statement(void) {
  int type;

  switch (Token.token) {
    case T_CHAR:
    case T_INT:
    case T_LONG:

      // The beginning of a variable declaration.
      // Parse the type and get the identifier.
      // Then parse the rest of the declaration.
      type = parse_type();
      ident();
      var_declaration(type, 1);
   ...
  }
  ...
}
```

## x86-64 代码生成器的变更

和往常一样，
`cg.c` 里那些平台相关的 `cgXX()` 函数，
通常都会通过 `gen.c` 中对应的 `genXX()` 函数暴露给编译器其他部分使用。
这里也不例外。
所以虽然我下面主要会提到 `cgXX()`，
但别忘了很多地方其实还有配套的 `genXX()` 包装层。

对于每个局部变量，
我们都需要给它分配一个位置，
并把这个位置记录到符号表的 `posn` 字段中。
做法如下。
在 `cg.c` 中，
我新增了一个静态变量和两个辅助函数：

```c
// Position of next local variable relative to stack base pointer.
// We store the offset as positive to make aligning the stack pointer easier
static int localOffset;
static int stackOffset;

// Reset the position of new local variables when parsing a new function
void cgresetlocals(void) {
  localOffset = 0;
}

// Get the position of the next local variable.
// Use the isparam flag to allocate a parameter (not yet XXX).
int cggetlocaloffset(int type, int isparam) {
  // Decrement the offset by a minimum of 4 bytes
  // and allocate on the stack
  localOffset += (cgprimsize(type) > 4) ? cgprimsize(type) : 4;
  return (-localOffset);
}
```

目前，
我们把所有局部变量都分配在栈上。
它们之间的对齐最少按 4 字节处理。
对于 64 位整数和指针，
那自然就会是每个变量 8 字节。

> 我过去一直以为，多字节数据项必须严格按边界对齐，
  否则 CPU 会直接异常。
  但至少在 x86-64 上，
  [数据项未必一定要对齐](https://lemire.me/blog/2012/05/31/data-alignment-for-speed-myth-or-reality/)。

> 不过，
  x86-64 上的栈指针在函数调用前*确实*必须按要求对齐。
  在 Agner Fog 的
  [Optimizing Subroutines in Assembly Language](https://www.agner.org/optimize/optimizing_assembly.pdf)
  第 30 页中，
  他提到：
  “The stack pointer must be aligned by 16 before any CALL instruction,
  so that the value of RSP is 8 modulo 16 at the entry of a function.”

> 这意味着，
  作为函数前导（function preamble）的一部分，
  我们必须把 `%rsp` 调整到正确对齐的位置。

`cgresetlocals()` 会在 `function_declaration()` 里被调用，
时机是在函数名已经加入符号表之后、
但还没开始解析局部变量声明之前。
它会把 `localOffset` 重置为 0。

前面说过，
当解析到新的局部标量或局部数组时，
会调用 `addlocl()`。
而 `addlocl()` 会把新变量的类型传给 `cggetlocaloffset()`。
后者会按合适的字节数减少“相对栈基指针的偏移”，
并把这个偏移存进该符号的 `posn` 字段。

既然现在我们已经知道某个符号相对栈基指针的偏移，
那代码生成器也必须跟着改：
当访问的是局部变量而不是全局变量时，
输出的不再是一个全局标签名，
而应该是相对于 `%rbp` 的偏移地址。

因此，
我们现在有了一个 `cgloadlocal()`，
它和 `cgloadglob()` 几乎完全相同，
只不过原先那些通过 `%s(%%rip)` 输出
`Symtable[id].name` 的格式字符串，
都改成了输出 `%d(%%rbp)`，
即 `Symtable[id].posn`。
实际上，
如果你在 `cg.c` 里搜一下 `Symtable[id].posn`，
就能把所有新增的局部变量访问逻辑都看出来。

### 更新栈指针

既然现在我们已经开始使用栈上的位置了，
那当然也得把栈指针往下挪，
挪到局部变量区域的下方。
因此我们必须修改函数前导和函数收尾（postamble）中的栈指针处理：

```c
// Print out a function preamble
void cgfuncpreamble(int id) {
  char *name = Symtable[id].name;
  cgtextseg();

  // Align the stack pointer to be a multiple of 16
  // less than its previous value
  stackOffset= (localOffset+15) & ~15;
  
  fprintf(Outfile,
          "\t.globl\t%s\n"
          "\t.type\t%s, @function\n"
          "%s:\n" "\tpushq\t%%rbp\n"
          "\tmovq\t%%rsp, %%rbp\n"
          "\taddq\t$%d,%%rsp\n", name, name, name, -stackOffset);
}

// Print out a function postamble
void cgfuncpostamble(int id) {
  cglabel(Symtable[id].endlabel);
  fprintf(Outfile, "\taddq\t$%d,%%rsp\n", stackOffset);
  fputs("\tpopq %rbp\n" "\tret\n", Outfile);
}
```

别忘了 `localOffset` 是负值。
所以在函数前导里，
我们加的是一个负值；
而在函数收尾里，
我们加回去的则是“负负得正”的值。

## 测试这些改动

我觉得这基本就是把局部变量加入编译器所需的大部分改动了。
测试程序 `tests/input25.c` 展示了
局部变量如何被存放到栈上：

```c
int a; int b; int c;

int main()
{
  char z; int y; int x;
  x= 10;  y= 20; z= 30;
  a= 5;   b= 15; c= 25;
}
```

下面是加了注释的汇编输出：

```
        .data
        .globl  a
a:      .long   0                       # Three global variables
        .globl  b
b:      .long   0
        .globl  c
c:      .long   0

        .text
        .globl  main
        .type   main, @function
main:
        pushq   %rbp
        movq    %rsp, %rbp
        addq    $-16,%rsp               # Lower stack pointer by 16
        movq    $10, %r8
        movl    %r8d, -12(%rbp)         # z is at offset -12
        movq    $20, %r8
        movl    %r8d, -8(%rbp)          # y is at offset -8
        movq    $30, %r8
        movb    %r8b, -4(%rbp)          # x is at offfset -4
        movq    $5, %r8
        movl    %r8d, a(%rip)           # a has a global label
        movq    $15, %r8
        movl    %r8d, b(%rip)           # b has a global label
        movq    $25, %r8
        movl    %r8d, c(%rip)           # c has a global label
        jmp     L1
L1:
        addq    $16,%rsp                # Raise stack pointer by 16
        popq    %rbp
        ret
```

最后，
执行一次 `$ make test` 可以看到编译器仍然通过了之前所有测试。

## 总结与下一步

我本来以为实现局部变量会很棘手，
但在提前把设计想清楚之后，
它比我预期中要顺利不少。
不知为何，
我总觉得真正难的部分会是在下一步。

在编译器编写之旅的下一部分中，
我会尝试把函数实参与形参也加进编译器里。
祝我好运吧。 [下一步](../24_Function_Params/Readme.md)
