# 第 24 部分：函数形参

我刚刚已经把函数形参从寄存器复制到函数栈上的逻辑实现出来了，
但还没有实现“带实参的函数调用”。

先简单回顾一下，
下面这张图来自 Eli Bendersky 关于
[x86-64 栈帧布局](https://eli.thegreenplace.net/2011/09/06/stack-frame-layout-on-x86-64/)
的文章。

![](../22_Design_Locals/Figs/x64_frame_nonleaf.png)

一个函数最多前六个“值传递（call by value）”参数
会通过寄存器 `%rdi` 到 `%r9` 传入。
超过六个时，
剩余参数会被压到栈上。

当函数被调用时，
它会先把旧的栈基指针压栈，
然后把栈基指针移动到当前栈指针所在的位置，
接着再把栈指针继续下移，
至少要移到最低那个局部变量的下面。

为什么说“至少”？
因为我们还必须把栈指针对齐到 16 的倍数，
这样在后面再次调用其他函数之前，
栈基指针的对齐状态才是正确的。

那些原本就被压在栈上的参数会继续留在那里，
它们相对于栈基指针的偏移是正值。
而那些通过寄存器传入的参数，
我们会复制到栈上；
同时也会在栈上为局部变量安排位置。
这些位置相对于栈基指针的偏移则是负值。

这就是目标状态，
不过在达到它之前，
我们还得先做几件事。

## 新 token 与扫描

首先，
ANSI C 里的函数声明由“逗号分隔的类型与变量名列表”组成，
例如：

```c
int function(int x, char y, long z) { ... }
```

因此我们需要一个新 token：`T_COMMA`，
以及对词法扫描器做一点修改来识别它。
这里我就不展开了，
你直接去看 `scan.c` 里 `scan()` 的改动即可。

## 一个新的存储类别

在编译器编写之旅的上一部分中，
我已经介绍过为了同时支持全局变量和局部变量，
符号表做了哪些修改。
我们把全局符号存放在表的一端，
局部符号放在另一端。
而现在，
我要把函数形参也引进来。

我在 `defs.h` 里新增了一个存储类别定义：

```c
// Storage classes
enum {
        C_GLOBAL = 1,           // Globally visible symbol
        C_LOCAL,                // Locally visible symbol
        C_PARAM                 // Locally visible function parameter
};
```

那它们会出现在符号表的什么位置？
其实，
同一个参数会同时出现在符号表的“全局端”和“局部端”。

在全局符号列表里，
我们会先放函数本身的符号，
它是一个 `C_GLOBAL`、`S_FUNCTION` 表项。
然后紧接着放下该函数所有形参，
这些连续表项都标记为 `C_PARAM`。
这就是函数的*原型（prototype）*。
这样一来，
等我们后面调用这个函数时，
就能把实参列表与形参列表做比较，
确保它们匹配。

与此同时，
同一组形参也会被存进局部符号列表里，
同样标记为 `C_PARAM`，而不是 `C_LOCAL`。
这样我们就能区分：
哪些变量是“别人传给我们的参数”，
哪些变量是“我们自己在函数里声明出来的局部变量”。

## 解析器的改动

这一部分里我只处理“函数声明”，
因此需要相应修改解析器。
当我们已经解析完函数的类型、名字以及开头的 `'('` 之后，
接下来就可以看看后面有没有参数。
每个参数本质上都遵循普通变量声明语法，
只不过参数之间不是用分号结束，
而是用逗号分隔。

`decl.c` 中旧的 `var_declaration()` 原本会在变量声明末尾扫描 `T_SEMI`。
现在这一步已经被挪回到它的调用者那里处理了。

我们新增了一个函数 `param_declaration()`，
专门负责读取紧跟在函数名后面括号里的参数列表
（零个或多个）：

```c
// param_declaration: <null>
//           | variable_declaration
//           | variable_declaration ',' param_declaration
//
// Parse the parameters in parentheses after the function name.
// Add them as symbols to the symbol table and return the number
// of parameters.
static int param_declaration(void) {
  int type;
  int paramcnt=0;

  // Loop until the final right parentheses
  while (Token.token != T_RPAREN) {
    // Get the type and identifier
    // and add it to the symbol table
    type = parse_type();
    ident();
    var_declaration(type, 1, 1);
    paramcnt++;

    // Must have a ',' or ')' at this point
    switch (Token.token) {
      case T_COMMA: scan(&Token); break;
      case T_RPAREN: break;
      default:
        fatald("Unexpected token in parameter list", Token.token);
    }
  }

  // Return the count of parameters
  return(paramcnt);
}
```

这里传给 `var_declaration()` 的两个 `1`
分别表示：
这是一个局部变量，
同时它还是一个参数声明。
而在 `var_declaration()` 里，
现在会这样处理：

```c
    // Add this as a known scalar
    // and generate its space in assembly
    if (islocal) {
      if (addlocl(Text, type, S_VARIABLE, isparam, 1)==-1)
       fatals("Duplicate local variable declaration", Text);
    } else {
      addglob(Text, type, S_VARIABLE, 0, 1);
    }
```

之前的代码是允许局部变量重复声明的；
但现在这么做只会让栈无意义地继续增长，
所以我把“重复的局部变量声明”改成了致命错误。

## 符号表的变更

前面我说，
参数会同时放进符号表的全局端和局部端；
但上面的代码里看起来只有一次 `addlocl()` 调用。
那到底发生了什么？

我修改了 `addlocal()`，
让它在处理参数时，
也额外把参数加到全局端：

```c
int addlocl(char *name, int type, int stype, int isparam, int size) {
  int localslot, globalslot;
  ...
  localslot = newlocl();
  if (isparam) {
    updatesym(localslot, name, type, stype, C_PARAM, 0, size, 0);
    globalslot = newglob();
    updatesym(globalslot, name, type, stype, C_PARAM, 0, size, 0);
  } else {
    updatesym(localslot, name, type, stype, C_LOCAL, 0, size, 0);
  }
```

这样一来，
一个参数不仅会在符号表里占据一个局部槽位，
还会额外占据一个全局槽位。
而且这两个表项都被标记为 `C_PARAM`，
而不是 `C_LOCAL`。

既然全局端里现在也可能含有并非 `C_GLOBAL` 的符号，
那我们就必须修改“查找全局符号”的代码：

```c
// Determine if the symbol s is in the global symbol table.
// Return its slot position or -1 if not found.
// Skip C_PARAM entries
int findglob(char *s) {
  int i;

  for (i = 0; i < Globs; i++) {
    if (Symtable[i].class == C_PARAM) continue;
    if (*s == *Symtable[i].name && !strcmp(s, Symtable[i].name))
      return (i);
  }
  return (-1);
}
```

## x86-64 代码生成器的变更

到这里为止，
我们已经能解析函数形参，
并把它们记录到符号表里了。
接下来，
还需要生成合适的函数前导（function preamble）：
它既要把“寄存器传入的参数”复制到栈上的对应位置，
也要完成新的栈基指针和栈指针初始化。

我后来意识到，
既然在 `cgfuncpreamble()` 里本来就会重置栈偏移，
那上一部分里加的 `cgresetlocals()` 其实没必要单独存在，
于是我把它删掉了。
另外，
“为新局部变量计算栈偏移”的代码也只需要在 `cg.c` 内可见，
所以我顺手给它改了个名字：

```c
// Position of next local variable relative to stack base pointer.
// We store the offset as positive to make aligning the stack pointer easier
static int localOffset;
static int stackOffset;

// Create the position of a new local variable.
static int newlocaloffset(int type) {
  // Decrement the offset by a minimum of 4 bytes
  // and allocate on the stack
  localOffset += (cgprimsize(type) > 4) ? cgprimsize(type) : 4;
  return (-localOffset);
}
```

我还把“先算负偏移再处理”改成了“先算正偏移再返回负值”，
这样在我脑子里做数学时更容易一些。
不过从返回值来看，
你仍然会看到它给出的还是负偏移。

现在我们将有六个新的寄存器用于承载参数值，
那最好先把它们起好名字。
于是我扩展了寄存器名列表：

```c
#define NUMFREEREGS 4
#define FIRSTPARAMREG 9         // Position of first parameter register
static int freereg[NUMFREEREGS];
static char *reglist[] =
  { "%r10", "%r11", "%r12", "%r13", "%r9", "%r8", "%rcx", "%rdx", "%rsi",
"%rdi" };
static char *breglist[] =
  { "%r10b", "%r11b", "%r12b", "%r13b", "%r9b", "%r8b", "%cl", "%dl", "%sil",
"%dil" };
static char *dreglist[] =
  { "%r10d", "%r11d", "%r12d", "%r13d", "%r9d", "%r8d", "%ecx", "%edx",
"%esi", "%edi" };
```

`FIRSTPARAMREG` 实际上就是每个列表里的最后一个位置。
我们会从这一端开始，向前倒着走。

接下来该轮到真正承担主要工作的 `cgfuncpreamble()` 了。
我们分几段来看它。

```c
// Print out a function preamble
void cgfuncpreamble(int id) {
  char *name = Symtable[id].name;
  int i;
  int paramOffset = 16;         // Any pushed params start at this stack offset
  int paramReg = FIRSTPARAMREG; // Index to the first param register in above reg lists

  // Output in the text segment, reset local offset
  cgtextseg();
  localOffset= 0;

  // Output the function start, save the %rsp and %rsp
  fprintf(Outfile,
          "\t.globl\t%s\n"
          "\t.type\t%s, @function\n"
          "%s:\n" "\tpushq\t%%rbp\n"
          "\tmovq\t%%rsp, %%rbp\n", name, name, name);
```

首先，
声明函数本身，
保存旧的基指针，
再把基指针下移到当前栈指针所在的位置。
同时我们也知道：
凡是已经被压到栈上的参数，
相对于新的基指针其起始偏移一定是 16；
另外，
我们也知道“第一个参数寄存器”在上面寄存器列表中的索引位置。

```c
  // Copy any in-register parameters to the stack
  // Stop after no more than six parameter registers
  for (i = NSYMBOLS - 1; i > Locls; i--) {
    if (Symtable[i].class != C_PARAM)
      break;
    if (i < NSYMBOLS - 6)
      break;
    Symtable[i].posn = newlocaloffset(Symtable[i].type);
    cgstorlocal(paramReg--, i);
  }
```

这个循环最多执行六次，
但只要碰到“不是 `C_PARAM` 的项”
也就是普通 `C_LOCAL`，
就会立刻退出。
随后调用 `newlocaloffset()`，
为该参数在栈上生成相对于基指针的偏移量，
再把对应寄存器里的参数值复制到这个位置上。

```c
  // For the remainder, if they are a parameter then they are
  // already on the stack. If only a local, make a stack position.
  for (; i > Locls; i--) {
    if (Symtable[i].class == C_PARAM) {
      Symtable[i].posn = paramOffset;
      paramOffset += 8;
    } else {
      Symtable[i].posn = newlocaloffset(Symtable[i].type);
    }
  }
```

对于剩余的局部变量：
如果某项是 `C_PARAM`，
那它说明这个参数本来就已经压在栈上了，
所以只需要把它当前所在的位置记录到符号表中即可；
如果它是 `C_LOCAL`，
那就为它在栈上新分配一个位置并记录下来。

到这里，
我们新的栈帧就已经建立好了，
其中包含了所需的所有局部变量位置。
剩下的最后一步，
就是把栈指针对齐到 16 的倍数：

```c
  // Align the stack pointer to be a multiple of 16
  // less than its previous value
  stackOffset = (localOffset + 15) & ~15;
  fprintf(Outfile, "\taddq\t$%d,%%rsp\n", -stackOffset);
}
```

`stackOffset` 是 `cg.c` 中一个全局可见的静态变量。
我们必须保留这个值，
因为到了函数收尾时，
还需要把栈指针按同样的数值加回去，
并恢复旧的栈基指针：

```c
// Print out a function postamble
void cgfuncpostamble(int id) {
  cglabel(Symtable[id].endlabel);
  fprintf(Outfile, "\taddq\t$%d,%%rsp\n", stackOffset);
  fputs("\tpopq %rbp\n" "\tret\n", Outfile);
}
```

## 测试这些改动

有了这些改动之后，
我们的编译器已经能声明“带很多参数”的函数，
同时也能继续声明所需的局部变量。
不过此时它还不能生成“通过寄存器传递实参”等调用代码。

所以为了测试这一阶段的改动，
我们先写一些带参数的函数，
并用我们的编译器去编译它们（`input27a.c`）：

```c
int param8(int a, int b, int c, int d, int e, int f, int g, int h) {
  printint(a); printint(b); printint(c); printint(d);
  printint(e); printint(f); printint(g); printint(h);
  return(0);
}

int param5(int a, int b, int c, int d, int e) {
  printint(a); printint(b); printint(c); printint(d); printint(e);
  return(0);
}

int param2(int a, int b) {
  int c; int d; int e;
  c= 3; d= 4; e= 5;
  printint(a); printint(b); printint(c); printint(d); printint(e);
  return(0);
}

int param0() {
  int a; int b; int c; int d; int e;
  a= 1; b= 2; c= 3; d= 4; e= 5;
  printint(a); printint(b); printint(c); printint(d); printint(e);
  return(0);
}
```

再单独写一个 `input27b.c`，
并用 `gcc` 来编译它：

```c
#include <stdio.h>
extern int param8(int a, int b, int c, int d, int e, int f, int g, int h);
extern int param5(int a, int b, int c, int d, int e);
extern int param2(int a, int b);
extern int param0();

int main() {
  param8(1,2,3,4,5,6,7,8); puts("--");
  param5(1,2,3,4,5); puts("--");
  param2(1,2); puts("--");
  param0();
  return(0);
}
```

然后把它们链接起来，
看看最终可执行文件能不能跑：

```
cc -o comp1 -g -Wall cg.c decl.c expr.c gen.c main.c misc.c
      scan.c stmt.c sym.c tree.c types.c
./comp1 input27a.c
cc -o out input27b.c out.s lib/printint.c 
./out
1
2
3
4
5
6
7
8
--
1
2
3
4
5
--
1
2
3
4
5
--
1
2
3
4
5
```

结果能跑通！
我特意加这个感叹号，
是因为每当这些东西真的工作起来时，
它有时还是会让我觉得像魔法一样。

我们来看看 `param8()` 的汇编输出：

```
param8:
        pushq   %rbp                    # Save %rbp, move %rsp
        movq    %rsp, %rbp
        movl    %edi, -4(%rbp)          # Copy six arguments into locals
        movl    %esi, -8(%rbp)          # on the stack
        movl    %edx, -12(%rbp)
        movl    %ecx, -16(%rbp)
        movl    %r8d, -20(%rbp)
        movl    %r9d, -24(%rbp)
        addq    $-32,%rsp               # Lower stack pointer by 32
        movslq  -4(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print -4(%rbp), i.e. a
        movq    %rax, %r11
        movslq  -8(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print -8(%rbp), i.e. b
        movq    %rax, %r11
        movslq  -12(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print -12(%rbp), i.e. c
        movq    %rax, %r11
        movslq  -16(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print -16(%rbp), i.e. d
        movq    %rax, %r11
        movslq  -20(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print -20(%rbp), i.e. e
        movq    %rax, %r11
        movslq  -24(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print -24(%rbp), i.e. f
        movq    %rax, %r11
        movslq  16(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print 16(%rbp), i.e. g
        movq    %rax, %r11
        movslq  24(%rbp), %r10
        movq    %r10, %rdi
        call    printint                # Print 24(%rbp), i.e. h
        movq    %rax, %r11
        movq    $0, %r10
        movl    %r10d, %eax
        jmp     L1
L1:
        addq    $32,%rsp                # Raise stack pointer by 32
        popq    %rbp                    # Restore %rbp and return
        ret
```

`input27a.c` 里的其他函数中，
有些同时包含参数变量和本地声明变量，
因此看起来生成出来的前导代码确实是对的
（好吧，至少已经足够正确，能够通过这些测试了！）。

## 总结与下一步

为了把这一部分做对，
我前后试了几次。
第一次我沿着局部符号列表遍历的方向搞反了，
结果参数顺序全错。
另外我还看错了 Eli Bendersky 图里的布局，
导致最初写出来的前导代码直接踩坏了旧的基指针。
不过从另一个角度看，
这反而也算是好事，
因为重写之后的代码比原先干净多了。

在编译器编写之旅的下一部分中，
我会修改编译器，
让它真正支持“带任意数量实参的函数调用”。
到那时，
我就可以把 `input27a.c` 和 `input27b.c`
一起移进 `tests/` 目录了。 [下一步](../25_Function_Arguments/Readme.md)
