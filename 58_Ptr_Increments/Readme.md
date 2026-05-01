# 第 58 部分：修复指针的自增/自减

在编译器编写之旅的上一部分里，
我提到过：
指针的自增和自减存在问题。
这一章我们就来看看，
问题到底是什么，
以及我是怎么把它修掉的。

我们之前已经看到，
对于 AST 操作 `A_ADD`、`A_SUBTRACT`、
`A_ASPLUS` 和 `A_ASMINUS`，
如果一边是指针、
另一边是整数类型，
那么就必须按“指针所指向类型的大小”
对这个整数值做缩放。
在 `types.c` 的 `modify_type()` 中：

```c
  // We can scale only on add and subtract operations
  if (op == A_ADD || op == A_SUBTRACT ||
      op == A_ASPLUS || op == A_ASMINUS) {

    // Left is int type, right is pointer type and the size
    // of the original type is >1: scale the left
    if (inttype(ltype) && ptrtype(rtype)) {
      rsize = genprimsize(value_at(rtype));
      if (rsize > 1)
        return (mkastunary(A_SCALE, rtype, rctype, tree, NULL, rsize));
      else
        return (tree);          // Size 1, no need to scale
    }
  }
```

但这种缩放并不会在 `++` 或 `--`
里自动发生，
无论它们是前缀自增/自减，
还是后缀自增/自减。
在这些情况下，
我们只是简单地在 AST 树上
挂一个 `A_PREINC`、`A_PREDEC`、
`A_POSTINC` 或 `A_POSTDEC` 节点，
然后把问题留给代码生成器去处理。

到目前为止，
这件事主要是在 `cg.c`
里调用 `cgloadglob()` 或 `cgloadlocal()`
去加载全局变量或局部变量的值时顺便解决的。
例如：

```c
int cgloadglob(struct symtable *sym, int op) {
  ...
  if (cgprimsize(sym->type) == 8) {
    if (op == A_PREINC)
      fprintf(Outfile, "\tincq\t%s(%%rip)\n", sym->name);
    ...
    fprintf(Outfile, "\tmovq\t%s(%%rip), %s\n", sym->name, reglist[r]);

    if (op == A_POSTINC)
      fprintf(Outfile, "\tincq\t%s(%%rip)\n", sym->name);
  }
  ...
}
```

但这里有个问题：
`incq`
一次只会加一。
如果被自增的变量本身是整数类型，
当然没问题；
可如果它是指针类型，
那这种做法就完全不对了。

此外，
`cgloadglob()` 和 `cgloadlocal()`
这两个函数本身也非常相似。
它们的区别只在于：
访问变量时到底该使用哪种指令，
变量是在一个固定命名位置上，
还是在相对于当前栈帧的位置上。

## 修复这个问题

有一阵子我还以为，
也许可以让解析器构造出
和 `modify_type()`
那边类似的一棵 AST 树，
但后来我放弃了。
谢天谢地，
还好没继续在那条路上越陷越深。
我最后决定：
既然 `++` 和 `--`
本来就是在 `cgloadglob()`
里处理的，
那就干脆在这一层把问题解决掉。

做到一半时，
我意识到还可以顺手把
`cgloadglob()` 和 `cgloadlocal()`
合并成一个函数。
下面按几个阶段来看这个方案。

```c
// Load a value from a variable into a register.
// Return the number of the register. If the
// operation is pre- or post-increment/decrement,
// also perform this action.
int cgloadvar(struct symtable *sym, int op) {
  int r, postreg, offset=1;

  // Get a new register
  r = alloc_register();

  // If the symbol is a pointer, use the size
  // of the type that it points to as any
  // increment or decrement. If not, it's one.
  if (ptrtype(sym->type))
    offset= typesize(value_at(sym->type), sym->ctype);
```

一开始，
我们默认自增的步长就是 `+1`。
但一旦发现这个符号是个指针，
就把这个偏移量改成
“它所指向类型的大小”。

```c
  // Negate the offset for decrements
  if (op==A_PREDEC || op==A_POSTDEC)
    offset= -offset;
```

这样一来，
如果当前做的是自减，
`offset`
就会变成负数。

```c
  // If we have a pre-operation
  if (op==A_PREINC || op==A_PREDEC) {
    // Load the symbol's address
    if (sym->class == C_LOCAL || sym->class == C_PARAM)
      fprintf(Outfile, "\tleaq\t%d(%%rbp), %s\n", sym->st_posn, reglist[r]);
    else
      fprintf(Outfile, "\tleaq\t%s(%%rip), %s\n", sym->name, reglist[r]);
```

这正是新算法和旧代码不同的地方。
旧代码直接使用 `incq` 指令，
但它把变量的变化量死死限制成了 1。
现在我们先把变量地址装进寄存器……

```c
    // and change the value at that address
    switch (sym->size) {
      case 1: fprintf(Outfile, "\taddb\t$%d,(%s)\n", offset, reglist[r]); break;
      case 4: fprintf(Outfile, "\taddl\t$%d,(%s)\n", offset, reglist[r]); break;
      case 8: fprintf(Outfile, "\taddq\t$%d,(%s)\n", offset, reglist[r]); break;
    }
  }
```

……然后就可以把 `offset`
直接加到这个变量本身上，
也就是把寄存器当成指向该变量的指针来用。
同时还必须根据变量大小
选用不同的指令。

前缀自增或前缀自减处理完之后，
就可以把变量的值加载进寄存器了：

```c
  // Now load the output register with the value
  if (sym->class == C_LOCAL || sym->class == C_PARAM) {
    switch (sym->size) {
      case 1: fprintf(Outfile, "\tmovzbq\t%d(%%rbp), %s\n", sym->st_posn, reglist[r]); break;
      case 4: fprintf(Outfile, "\tmovslq\t%d(%%rbp), %s\n", sym->st_posn, reglist[r]); break;
      case 8: fprintf(Outfile, "\tmovq\t%d(%%rbp), %s\n", sym->st_posn, reglist[r]);
    }
  } else {
    switch (sym->size) {
      case 1: fprintf(Outfile, "\tmovzbq\t%s(%%rip), %s\n", sym->name, reglist[r]); break;
      case 4: fprintf(Outfile, "\tmovslq\t%s(%%rip), %s\n", sym->name, reglist[r]); break;
      case 8: fprintf(Outfile, "\tmovq\t%s(%%rip), %s\n", sym->name, reglist[r]);
    }
  }
```

根据这个符号究竟是局部变量还是全局变量，
我们要么从一个具名位置加载，
要么从相对帧指针的位置加载。
同时还得根据符号的大小，
选择合适的指令来做零扩展或符号扩展。

现在值已经安全地装在寄存器 `r`
里面了。
但如果操作是后缀自增或后缀自减，
我们接下来还得把“修改变量本身”这一步补上。
这部分可以重用前缀操作的代码，
不过需要再申请一个新寄存器：

```c
  // If we have a post-operation, get a new register
  if (op==A_POSTINC || op==A_POSTDEC) {
    postreg = alloc_register();

    // Same code as before, but using postreg

    // and free the register
    free_register(postreg);
  }

  // Return the register with the value
  return(r);
}
```

所以整体来看，
`cgloadvar()`
的复杂度其实和旧代码差不多，
但它现在终于能正确处理
指针的自增问题了。
`tests/input145.c`
这个测试程序会验证新代码确实有效：

```c
int list[]= {3, 5, 7, 9, 11, 13, 15};
int *lptr;

int main() {
  lptr= list;
  printf("%d\n", *lptr);
  lptr= lptr + 1; printf("%d\n", *lptr);
  lptr += 1; printf("%d\n", *lptr);
  lptr += 1; printf("%d\n", *lptr);
  lptr -= 1; printf("%d\n", *lptr);
  lptr++   ; printf("%d\n", *lptr);
  lptr--   ; printf("%d\n", *lptr);
  ++lptr   ; printf("%d\n", *lptr);
  --lptr   ; printf("%d\n", *lptr);
}
```

## 我怎么会漏掉取模

把这个问题修好之后，
我又回头继续让编译器编译它自己的源码。
结果让我非常惊讶的是：
取模运算符 `%` 和 `%=`
居然根本还没实现。
我完全不知道自己之前为什么会把它们漏掉。

### 新的 token 和 AST 运算符

现在要给编译器新增一个运算符，
已经变成了一件不太轻松的事，
因为我们得在好几个地方同步修改。
先看有哪些地方。
在 `defs.h` 里，
我们得先补上这些 token：

```c
// Token types
enum {
  T_EOF,

  // Binary operators
  T_ASSIGN, T_ASPLUS, T_ASMINUS,
  T_ASSTAR, T_ASSLASH, T_ASMOD,
  T_QUESTION, T_LOGOR, T_LOGAND,
  T_OR, T_XOR, T_AMPER,
  T_EQ, T_NE,
  T_LT, T_GT, T_LE, T_GE,
  T_LSHIFT, T_RSHIFT,
  T_PLUS, T_MINUS, T_STAR, T_SLASH, T_MOD,
  ...
};
```

这里新增的是 `T_ASMOD`
和 `T_MOD`。
接着我们还得创建对应的 AST 操作符：

```c
 // AST node types. The first few line up
// with the related tokens
enum {
  A_ASSIGN = 1, A_ASPLUS, A_ASMINUS, A_ASSTAR,                  //  1
  A_ASSLASH, A_ASMOD, A_TERNARY, A_LOGOR,                       //  5
  A_LOGAND, A_OR, A_XOR, A_AND, A_EQ, A_NE, A_LT,               //  9
  A_GT, A_LE, A_GE, A_LSHIFT, A_RSHIFT,                         // 16
  A_ADD, A_SUBTRACT, A_MULTIPLY, A_DIVIDE, A_MOD,               // 21
  ...
};
```

然后还得在扫描器里加上对这些 token 的识别。
具体代码我就不贴了，
这里只展示 `scan.c`
里 token 字符串表的变化：

```c
// List of token strings, for debugging purposes
char *Tstring[] = {
  "EOF", "=", "+=", "-=", "*=", "/=", "%=",
  "?", "||", "&&", "|", "^", "&",
  "==", "!=", ",", ">", "<=", ">=", "<<", ">>",
  "+", "-", "*", "/", "%",
  ...
};
```

### 运算符优先级

接下来，
我们还得在 `expr.c`
里给这些运算符设定优先级。
以前优先级表里的最高项是 `T_SLASH`，
现在则扩展成了 `T_MOD`：

```c
// Convert a binary operator token into a binary AST operation.
// We rely on a 1:1 mapping from token to AST operation
static int binastop(int tokentype) {
  if (tokentype > T_EOF && tokentype <= T_MOD)
    return (tokentype);
  fatals("Syntax error, token", Tstring[tokentype]);
  return (0);                   // Keep -Wall happy
}

// Operator precedence for each token. Must
// match up with the order of tokens in defs.h
static int OpPrec[] = {
  0, 10, 10,                    // T_EOF, T_ASSIGN, T_ASPLUS,
  10, 10,                       // T_ASMINUS, T_ASSTAR,
  10, 10,                       // T_ASSLASH, T_ASMOD,
  15,                           // T_QUESTION,
  20, 30,                       // T_LOGOR, T_LOGAND
  40, 50, 60,                   // T_OR, T_XOR, T_AMPER 
  70, 70,                       // T_EQ, T_NE
  80, 80, 80, 80,               // T_LT, T_GT, T_LE, T_GE
  90, 90,                       // T_LSHIFT, T_RSHIFT
  100, 100,                     // T_PLUS, T_MINUS
  110, 110, 110                 // T_STAR, T_SLASH, T_MOD
};

// Check that we have a binary operator and
// return its precedence.
static int op_precedence(int tokentype) {
  int prec;
  if (tokentype > T_MOD)
    fatals("Token with no precedence in op_precedence:", Tstring[tokentype]);
  prec = OpPrec[tokentype];
  if (prec == 0)
    fatals("Syntax error, token", Tstring[tokentype]);
  return (prec);
}
```

### 代码生成

我们原本已经有一个 `cgdiv()` 函数，
用来为 x86-64 生成除法指令。
查一下 `idiv` 指令的手册说明：

> idivq S: signed divide `%rdx:%rax` by S. The quotient is
  stored in `%rax`. The remainder is stored in `%rdx`.

于是我们可以把 `cgdiv()`
扩展成既能处理除法，
也能处理取模。
`cg.c` 里的新函数如下：

```c
// Divide or modulo the first register by the second and
// return the number of the register with the result
int cgdivmod(int r1, int r2, int op) {
  fprintf(Outfile, "\tmovq\t%s,%%rax\n", reglist[r1]);
  fprintf(Outfile, "\tcqo\n");
  fprintf(Outfile, "\tidivq\t%s\n", reglist[r2]);
  if (op== A_DIVIDE)
    fprintf(Outfile, "\tmovq\t%%rax,%s\n", reglist[r1]);
  else
    fprintf(Outfile, "\tmovq\t%%rdx,%s\n", reglist[r1]);
  free_register(r2);
  return (r1);
}
```

`tests/input147.c`
会确认上述修改确实生效：

```c
#include <stdio.h>

int a;

int main() {
  printf("%d\n", 24 % 9);
  printf("%d\n", 31 % 11);
  a= 24; a %= 9; printf("%d\n",a);
  a= 31; a %= 11; printf("%d\n",a);
  return(0);
}
```

## 为什么链接不过

到这一步，
我们的编译器其实已经可以解析它自己所有的源码文件了。
但当我尝试把这些目标文件链接起来时，
却得到了关于缺失 `L0` 标签的警告。

稍微查了一下之后发现，
问题出在 `gen.c`
里的 `genIF()`：
我没有正确把循环和 `switch`
对应的结束标签传递下去。
修复点就在第 49 行：

```c
// Generate the code for an IF statement
// and an optional ELSE clause.
static int genIF(struct ASTnode *n, int looptoplabel, int loopendlabel) {
  ...
  // Optional ELSE clause: generate the
  // false compound statement and the
  // end label
  if (n->right) {
    genAST(n->right, NOLABEL, NOLABEL, loopendlabel, n->op);
    genfreeregs(NOREG);
    cglabel(Lend);
  }
  ...
}
```

现在 `loopendlabel`
已经能够正确传下去了，
于是我终于可以这样做了
（这是一段我命名为 `memake`
的 shell 脚本）：

```
#!/bin/sh
make install

rm *.s *.o

for i in cg.c decl.c expr.c gen.c main.c misc.c \
        opt.c scan.c stmt.c sym.c tree.c types.c
do echo "./cwj -c $i"; ./cwj -c $i ; ./cwj -S $i
done

cc -o cwj0 cg.o decl.o expr.o gen.o main.o misc.o \
        opt.o scan.o stmt.o sym.o tree.o types.o
```

这样一来，
我们最终就能得到一个新的二进制文件 `cwj0`，
也就是由编译器自己把自己编译出来的结果。

```
$ size cwj0
   text    data     bss     dec     hex filename
 106540    3008      48  109596   1ac1c cwj0

$ file cwj0
cwj0: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically
      linked, interpreter /lib64/l, for GNU/Linux 3.2.0, not stripped
```

## 总结与下一步

关于指针自增这个问题，
我确实绕着想了很久，
也试过好几种可能的替代方案。
中途我一度已经写到一半，
准备构造一棵包含 `A_SCALE`
的新 AST 树。
后来我把这些全扔了，
改成在 `cgloadvar()`
里解决。
现在回头看，
这条路明显更干净。

取模运算符在“理论上”很好加，
但在“实际操作上”却烦人得多，
因为我们必须让多个位置的改动始终保持同步。
这块后面大概还有些重构空间，
也许可以让同步工作简单很多。

然后，
在尝试把编译器自己生成出来的那些目标文件链接起来时，
我又发现：
我们此前并没有正确传递
循环/`switch`
的结束标签。

现在我们终于走到这样一个阶段：
编译器已经能够解析它自己全部的源码文件，
为它们生成汇编代码，
并且最终把它们链接起来。
接下来，
我们就要进入这趟旅程的最后一个阶段了，
而且它很可能是最痛苦的一段：
**WDIW**，
也就是 why doesn't it work?

在这个阶段里，
我们手上没有调试器，
只能去看大量汇编输出，
还得单步执行汇编，
观察寄存器里的值。

在编译器编写之旅的下一部分中，
我会正式开始进入
**WDIW** 阶段。
我们需要制定一些策略，
确保这项工作能高效推进。 [下一步](../59_WDIW_pt1/Readme.md)
