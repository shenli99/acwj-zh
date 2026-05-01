# 第 43 部分：Bug 修复与更多运算符

我已经开始把编译器自己的部分源码
拿来作为它自己的输入了，
因为这正是它最终走向“自举编译自己”的必经之路。
第一道大坎，
是让编译器先能正确解析并识别它自己的源码。
第二道大坎，
则是让编译器根据这份源码
生成出正确、可运行的代码。

这也是第一次，
我们的编译器被喂进了一些真正有分量的输入。
而这势必会暴露出一堆 bug、奇怪行为和缺失特性。

## Bug 修复

我先从 `cwj -S defs.h` 开始，
结果发现少了好几个头文件。
目前我先把这些头文件建出来了，
虽然内容还是空的。
在这些文件都补齐之后，
编译器又会因为段错误（segfault）崩掉。
排查后发现，
有几处指针本来就应该初始化为 `NULL`，
以及有些地方我压根没检查 `NULL` 指针。

## 缺失特性

接着，
我又在 `defs.h` 里撞上了
`enum { NOREG = -1 ...`
这样的代码，
这才意识到：
扫描器还不会处理“以减号开头的整数字面量”。
所以我在 `scan.c` 的 `scan()` 中加入了这段代码：

```c
    case '-':
      if ((c = next()) == '-') {
        t->token = T_DEC;
      } else if (c == '>') {
        t->token = T_ARROW;
      } else if (isdigit(c)) {          // Negative int literal
        t->intvalue = -scanint(c);
        t->token = T_INTLIT;
      } else {
        putback(c);
        t->token = T_MINUS;
      }
```

如果 `'-'` 后面紧跟的是数字，
那就直接把整个整数字面量扫出来，
再把它的值取负。
起初我还担心
表达式 `1 - 1`
会不会被错误拆成两个 token：
`'1'` 和 `'整数字面量 -1'`。
但后来我想起来，
`next()` 并不会跳过空格。
所以只要在 `'-'` 和 `'1'` 之间存在空格，
表达式 `1 - 1`
依旧会被正确解析成
`'1'`、`'-'`、`'1'`。

不过，
[Luke Gruber](https://github.com/luke-gru) 指出，
这也同时意味着：
输入 `1-1`
**确实会** 被当作 `1 -1`，
而不是 `1 - 1`。
也就是说，
当前扫描器贪婪过头了，
把 `-1`
一律强制看成 `T_INTLIT`，
但有些场景里它其实不该这样。
这个问题我现在先放着不管，
因为在编写源码时
我们可以先通过空格绕过去。
当然，
如果这是一门真正的生产级编译器，
那这个问题迟早必须修。

## 奇怪行为

在 AST 节点结构和符号表节点结构里，
我一直在用 `union`
来尽量压缩每个节点的体积。
我大概算是有点老派，
会本能地担心内存浪费。
例如 AST 节点结构里就有这样的设计：

```c
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  ...
  union {                       // the symbol in the symbol table
    int intvalue;               // For A_INTLIT, the integer value
    int size;                   // For A_SCALE, the size to scale by
  };
};
```

但问题是：
当前编译器还无法正确解析“struct 里的 union”，
更别说“struct 里匿名 union”了。
我当然可以继续把这项能力补进编译器，
但眼下更省事的办法，
是直接把那两个使用 union 的结构改掉。
于是我做了下面这些修改：

```c
// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
  ...
#define st_endlabel st_posn     // For functions, the end label
  int st_posn;                  // For locals, the negative offset
                                // from the stack base pointer
  ...
};

// Abstract Syntax Tree structure
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  ...
#define a_intvalue a_size       // For A_INTLIT, the integer value
  int a_size;                   // For A_SCALE, the size to scale by
};
```

这样一来，
我依然保留了“两种命名共用同一块字段”的效果，
但对编译器来说，
它在每个结构里只会真正看到一个字段名。
同时我也刻意给每个 `#define`
都加了不同前缀，
以减少对全局命名空间的污染。

这个改动的连锁反应就是：
我不得不在半打源文件里，
把 `endlabel`、`posn`、`intvalue` 和 `size`
这些字段名全都改一遍。
生活就是这样。

于是现在编译器在执行 `cwj -S misc.c` 时，
已经能跑到这里了：

```
Expected:] on line 16 of data.h, where the line is
extern char Text[TEXTLEN + 1];
```

这里会失败，
因为当前版本的编译器
还不会在“全局变量声明”里解析表达式。
看来我得重新思考一下这一块。

我目前的想法是：
用 `binexpr()` 先把这个表达式解析出来，
然后再加入一段优化代码，
对生成出的 AST 做
[常量折叠（constant folding）](https://en.wikipedia.org/wiki/Constant_folding)。
如果顺利，
最后就应该能得到一个单独的 `A_INTLIT` 节点，
那我就可以从中直接提取字面量值。
这样一来，
`binexpr()` 甚至还可以顺带处理 cast，
例如：

```c
 char x= (char)('a' + 1024);
```

总之，
这是后面的事。
我本来就打算在某个阶段加入常量折叠，
只是没想到它会这么早就被推上日程。

而在这一部分里，
我真正打算先做的是：
再补一些运算符。
具体来说，
是 `'+='`、`'-='`、`'*='` 和 `'/='`。
因为在编译器自己的源码里，
前两个运算符已经开始被用了。

## 新 token、扫描与解析

给编译器加新关键字其实很简单：
新增一个 token，
再改一下扫描器就行。
但加新运算符要麻烦得多，
因为我们还得同时处理：

  + token 与 AST 操作之间的对齐
  + 优先级与结合性

这次要加入四个运算符：
`'+='`、`'-='`、`'*='` 和 `'/='`。
对应的 token 分别是：
`T_ASPLUS`、`T_ASMINUS`、`T_ASSTAR`、`T_ASSLASH`。
对应的 AST 操作则是：
`A_ASPLUS`、`A_ASMINUS`、`A_ASSTAR`、`A_ASSLASH`。

这里 AST 操作的 enum 值
**必须** 和 token 的 enum 值完全一致，
原因是 `expr.c` 里有下面这个函数：

```c
// Convert a binary operator token into a binary AST operation.
// We rely on a 1:1 mapping from token to AST operation
static int binastop(int tokentype) {
  if (tokentype > T_EOF && tokentype <= T_SLASH)
    return (tokentype);
  fatald("Syntax error, token", tokentype);
  return (0);                   // Keep -Wall happy
}
```

我们还得为这些新运算符配置优先级。
根据
[这份 C 运算符列表](https://en.cppreference.com/w/c/language/operator_precedence)，
这些新运算符和现有赋值运算符拥有相同优先级。
所以 `expr.c` 里的 `OpPrec[]` 表
现在可以改成这样：

```c
// Operator precedence for each token. Must
// match up with the order of tokens in defs.h
static int OpPrec[] = {
  0, 10, 10,                    // T_EOF, T_ASSIGN, T_ASPLUS,
  10, 10, 10,                   // T_ASMINUS, T_ASSTAR, T_ASSLASH,
  20, 30,                       // T_LOGOR, T_LOGAND
  ...
};
```

不过那份 C 运算符列表同时还指出：
这些赋值运算符是
*右结合（right-associative）* 的。
这意味着，
例如：

```c
   a += b + c;          // needs to be parsed as
   a += (b + c);        // not
   (a += b) + c;
```

所以我们还得修改 `expr.c`
里的这个函数：

```c
// Return true if a token is right-associative,
// false otherwise.
static int rightassoc(int tokentype) {
  if (tokentype >= T_ASSIGN && tokentype <= T_ASSLASH)
    return (1);
  return (0);
}
```

好在，
对扫描器和表达式解析器来说，
到这里就够了：
Pratt parser 现在已经具备了处理这些新运算符的全部前置条件。

## 处理 AST 语法树

既然现在已经能解析这四个新运算符了，
接下来就得处理为它们生成出来的 AST。
首先有一件事必须做：
让 `dumpAST()` 能把这些节点正确打印出来。
所以我在 `tree.c` 的 `dumpAST()` 中加入了下面这段：

```c
    case A_ASPLUS:
      fprintf(stdout, "A_ASPLUS\n"); return;
    case A_ASMINUS:
      fprintf(stdout, "A_ASMINUS\n"); return;
    case A_ASSTAR:
      fprintf(stdout, "A_ASSTAR\n"); return;
    case A_ASSLASH:
      fprintf(stdout, "A_ASSLASH\n"); return;
```

现在如果我运行 `cwj -T input.c`，
里面带着表达式 `a += b + c`，
就会看到：

```
  A_IDENT rval a
    A_IDENT rval b
    A_IDENT rval c
  A_ADD
A_ASPLUS
```

把它重新画出来，
大概就是这样：

```
          A_ASPLUS
         /        \
     A_IDENT     A_ADD
     rval a     /     \
            A_IDENT  A_IDENT
             rval b  rval c
```

## 为这些运算符生成汇编

接下来在 `gen.c` 中，
我们原本就已经会遍历 AST，
并处理 `A_ADD` 和 `A_ASSIGN`。
那有没有办法复用现有代码，
让新增 `A_ASPLUS`
这件事更轻松一点？
有。

我们可以把上面的 AST
在逻辑上改写成这样：

```
                A_ASSIGN
               /       \
            A_ADD      lval a
         /        \
     A_IDENT     A_ADD
     rval a     /     \
            A_IDENT   A_IDENT
             rval b   rval c
```

当然，
我们并不一定真的要把树改写成这个结构，
只要在遍历时
*按这棵改写后的树去思考* 就够了。

所以在 `genAST()` 中，
我们本来就有下面这段现成逻辑：

```c
int genAST(...) {
  ...
  // Get the left and right sub-tree values. This code already here.
  if (n->left)
    leftreg = genAST(n->left, NOLABEL, NOLABEL, NOLABEL, n->op);
  if (n->right)
    rightreg = genAST(n->right, NOLABEL, NOLABEL, NOLABEL, n->op);
}
```

从 `A_ASPLUS` 的视角看，
这意味着：
左子树
（比如 `a` 的值）
已经算完了，
右子树
（比如 `b+c`）
也已经算完了，
而且它们都已经落在寄存器里。

如果当前节点本来只是个 `A_ADD`，
那现在就会去执行 `cgadd(leftreg, rightreg)`。
而实际上，
这里本质上也确实是：
先做一次 `A_ADD`，
再把结果赋值回 `a`。

于是 `genAST()` 里现在多了这段代码：

```c
  switch (n->op) {
    ... 
    case A_ASPLUS:
    case A_ASMINUS:
    case A_ASSTAR:
    case A_ASSLASH:
    case A_ASSIGN:

      // For the '+=' and friends operators, generate suitable code
      // and get the register with the result. Then take the left child,
      // make it the right child so that we can fall into the assignment code.
      switch (n->op) {
        case A_ASPLUS:
          leftreg= cgadd(leftreg, rightreg);
          n->right= n->left;
          break;
        case A_ASMINUS:
          leftreg= cgsub(leftreg, rightreg);
          n->right= n->left;
          break;
        case A_ASSTAR:
          leftreg= cgmul(leftreg, rightreg);
          n->right= n->left;
          break;
        case A_ASSLASH:
          leftreg= cgdiv(leftreg, rightreg);
          n->right= n->left;
          break;
      }

      // And the existing code to do A_ASSIGN is here
     ...
  }
```

换句话说，
对于每个新运算符，
我们先在两个子节点的值上执行正确的数学操作。
但在落入 `A_ASSIGN`
那段现成逻辑之前，
还得先把“左子节点指针”
挪过去充当右子节点。
为什么？
因为 `A_ASSIGN`
那段代码默认认为“赋值目标”是在右子节点里：

```c
      return (cgstorlocal(leftreg, n->right->sym));
```

就这样。
这次我们算是撞上了比较幸运的情况：
现有代码正好能被稍微改造一下，
就支持这四个新运算符。

当然，
还有一些赋值运算符我还没实现：
`'%='`、`'<<='`、`'>>='`、`'&='`、`'^='` 和 `'|='`。
不过照目前这个模式来看，
它们应该也会一样好加。

## 示例代码

测试程序是 `tests/input110.c`：

```c
#include <stdio.h>

int x;
int y;

int main() {
  x= 3; y= 15; y += x; printf("%d\n", y);
  x= 3; y= 15; y -= x; printf("%d\n", y);
  x= 3; y= 15; y *= x; printf("%d\n", y);
  x= 3; y= 15; y /= x; printf("%d\n", y);
  return(0);
}
```

它会输出：

```
18
12
45
5
```

## 总结与下一步

我们又补上了一批运算符。
而这里真正最难的部分，
其实是把 token、AST 操作、
优先级和右结合关系
全部对齐好。
一旦这些东西理顺之后，
我们就能复用 `genAST()`
里已有的一部分代码，
让实现轻松不少。

在编译器编写之旅的下一部分中，
看起来我就要把常量折叠
加入编译器了。 [下一步](../44_Fold_Optimisation/Readme.md)
